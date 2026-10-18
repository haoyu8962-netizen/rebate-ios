import CryptoKit
import Foundation
@testable import HomeCore
import XCTest

/// 包内默认（G17）、解码白名单（G05、G12，红线 1）与门槛比较语义（AC-HOME-06，红线 3）。
@MainActor
final class HomeContentRulesTests: XCTestCase {
    /// 包内 default_home.json 与向量 goldenPages.default_home 一致，且三端逐字一致（Android / 鸿蒙同一份字节的 SHA-256）。
    func testBundledDefaultHomeIsTheVectorPageByteForByte() throws {
        let data = try XCTUnwrap(HomeBundled.data(), "包内没有 default_home.json")
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "cd7f5a7b1998e278355f24a9770e3fa0e3e11a4c100d2c73e5a074530bb96466")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        XCTAssertEqual(object, try HomeVectors.golden("default_home") as NSDictionary)
        XCTAssertFalse((String(bytes: data, encoding: .utf8) ?? "").contains("http"), "包内默认不引用网络图片")
        let decoded = HomeJson.decode(
            pageJson: try HomeVectors.golden("default_home"),
            platform: "ios",
            appVersion: "1.0.0"
        )
        XCTAssertEqual((decoded["kept"] as? [[String: Any]])?.count, 2)
    }

    /// 图片只收 https；`builtin:` 只认包内默认的固定名字；其余协议只丢这一条。
    func testImagesOnlyHttpsOrKnownBuiltinAndBadItemsAreDropped() {
        let page = HomeKit.page(version: 3, [[
            "id": "cells", "type": "icon_grid", "version": 1, "props": ["columns": 4],
            "data_source": ["kind": "static", "items": [
                ["icon": "https://img.example.com/ok.png", "title": "测试好格", "action": ["route": "Help"]],
                ["icon": "builtin:platform.jd", "title": "京东", "action": ["route": "Help"]],
                ["icon": "http://img.example.com/x.png", "title": "测试明文", "action": ["route": "Help"]],
                ["icon": "javascript:alert(1)", "title": "测试脚本", "action": ["route": "Help"]],
                ["icon": "data:image/png;base64,AAAA", "title": "测试内联", "action": ["route": "Help"]],
                ["icon": "builtin:anything.else", "title": "测试未知内置", "action": ["route": "Help"]],
                [
                    "icon": "https://img.example.com/js.png",
                    "title": "测试脚本动作",
                    "action": ["js": "x", "url": "https://x"],
                ],
            ]],
        ] as [String: Any]])
        let decoded = HomeJson.decode(pageJson: page, platform: "ios", appVersion: "1.10.0")
        let kept = (decoded["kept"] as? [[String: Any]]) ?? []
        XCTAssertEqual(kept.first?["itemCount"] as? Int, 2)
        XCTAssertTrue((decoded["dropped"] as? [Any])?.isEmpty ?? false, "坏条目不记 dropped（G08）")
    }

    /// 门槛只做「当前版本 ≥ 门槛」（AC-HOME-06，红线 3）：低于 / 等于 / 高于，以及段数不同、带前导零的写法都按数值比较。
    /// 不限定比较方向与分支写法（第 2 版按评审 T-01 删掉源码正则检查，改为行为用例；合法变体 L5 / L6 自测）。
    func testMinAppVersionIsNotLowerThanAcrossSegmentCounts() {
        let cases: [(String, Bool)] = [
            ("1.9", true), ("1.9.9.9", true), ("0.99.99", true), ("1.2.0", true),
            ("1.10", true), ("1.10.0", true), ("1.10.0.0", true), ("01.010.000", true),
            ("1.10.0.1", false), ("1.10.1", false), ("1.11", false), ("2", false), ("10.0.0", false),
        ]
        for (minimum, keep) in cases {
            let actual = HomeSectionFilter.keep(
                minAppVersionJsonOrNull: ["ios": minimum], absent: false, platform: "ios", appVersion: "1.10.0"
            )
            XCTAssertEqual(actual, keep, "门槛 \(minimum)，当前 1.10.0")
        }
        // 当前版本段数少于门槛
        XCTAssertTrue(HomeSectionFilter.keep(
            minAppVersionJsonOrNull: ["ios": "1.10.0.0"], absent: false, platform: "ios", appVersion: "1.10"
        ))
        XCTAssertFalse(HomeSectionFilter.keep(
            minAppVersionJsonOrNull: ["ios": "1.10.0.1"], absent: false, platform: "ios", appVersion: "1.10"
        ))
        // 经整页解码：同一页三张卡分别低于 / 等于 / 高于（不同段数）
        let page = HomeKit.page(version: 9, [("lower", "1.9.9.9"), ("equal", "1.10"), ("higher", "1.10.0.1")].map {
            var section = HomeKit.banner($0.0)
            section["min_app_version"] = ["ios": $0.1]
            return section
        })
        let decoded = HomeJson.decode(pageJson: page, platform: "ios", appVersion: "1.10.0")
        XCTAssertEqual((decoded["kept"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["lower", "equal"])
        XCTAssertEqual((decoded["skipped"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["higher"])
    }
}
