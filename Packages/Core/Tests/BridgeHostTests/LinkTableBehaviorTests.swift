@testable import BridgeHost
import Foundation
import XCTest

/// 第三方页导航判定的 URL 规范化与规则表（APP-04 三端共性第 17、18 条），向量之外的补充。
final class LinkTableBehaviorTests: XCTestCase {
    // MARK: - URL 与规则表（三端共性第 17、18 条）

    func testNormalizationRemovesDotSegmentsAndBackslashes() {
        XCTAssertEqual(NormalizedURL.parse("https://a.test/x/../item")?.path, "/item")
        XCTAssertEqual(NormalizedURL.parse("https://a.test/x/%2e%2E/item")?.path, "/item")
        XCTAssertEqual(NormalizedURL.parse("https://a.test/./item")?.path, "/item")
        XCTAssertEqual(NormalizedURL.parse(#"https://a.test/x\..\item"#)?.path, "/item")
        XCTAssertEqual(NormalizedURL.parse("https://a.test/%69tem")?.path, "/item")
        XCTAssertEqual(NormalizedURL.parse("https://a.test")?.path, "/")
        let policy = ExternalNavPolicy(bundledLinkPatterns: [:])
        let table: [String: Any] = ["version": "v", "rules": [
            ["platform": "taobao", "category": "product", "hosts": ["item.example.test"], "path_patterns": ["^/item$"]],
        ]]
        let decision = policy.decide(
            url: "https://item.example.test/a/%2e%2e/item", isMainFrame: true, isNewWindow: false, linkPatterns: table
        )
        XCTAssertEqual(decision.actionRaw, ExternalNavAction.toNativeProduct)
    }

    /// 三端共性第 18 条：union_host 按规则主机整域（含子域）阻断，不因 path_patterns 而放行。
    func testUnionHostBlocksWholeDomainRegardlessOfPaths() {
        let table: [String: Any] = ["version": "v", "rules": [
            [
                "platform": "taobao",
                "category": "union_host",
                "hosts": ["taobao.example.test"],
                "path_patterns": ["^/x$"],
            ],
        ]]
        let policy = ExternalNavPolicy(bundledLinkPatterns: [:])
        for url in [
            "https://taobao.example.test/cart",
            "https://m.taobao.example.test/",
            "https://TAOBAO.example.test./y",
        ] {
            XCTAssertEqual(
                policy.decide(url: url, isMainFrame: true, isNewWindow: false, linkPatterns: table).actionRaw,
                ExternalNavAction.block,
                url
            )
        }
        XCTAssertEqual(
            policy.decide(
                url: "https://nottaobao.example.test/",
                isMainFrame: true,
                isNewWindow: false,
                linkPatterns: table
            )
            .actionRaw,
            ExternalNavAction.load
        )
    }

    func testBadTableFallsBackAsAWhole() {
        let bundled: [String: Any] = ["version": "b", "rules": [
            ["platform": "jd", "category": "union_host", "hosts": ["jd.example.test"], "path_patterns": []],
        ]]
        let bad: [String: Any] = ["version": "c", "rules": [
            ["platform": "taobao", "category": "union_host", "hosts": ["taobao.example.test"], "path_patterns": []],
            ["platform": "taobao", "category": "product", "hosts": ["item.example.test"], "path_patterns": ["(["]],
        ]]
        XCTAssertNil(LinkPatterns.parse(bad))
        let policy = ExternalNavPolicy(bundledLinkPatterns: bundled)
        // 坏表整表不用：落到包内表（jd 拦、taobao 不在包内表里）。
        XCTAssertEqual(
            policy.decide(url: "https://jd.example.test/", isMainFrame: true, isNewWindow: false, linkPatterns: bad)
                .actionRaw,
            "block"
        )
        XCTAssertEqual(
            policy.decide(url: "https://taobao.example.test/", isMainFrame: true, isNewWindow: false, linkPatterns: bad)
                .actionRaw,
            "load"
        )
    }

    // MARK: - 共性第 35、39 条

    /// 授权页判定用统一规范化后的结果（路径百分号解码一次、点段含 %2e、主机大小写与末尾点），编码绕不过去。
    func testAuthPageDetectionUsesNormalizedDecodedPath() {
        XCTAssertTrue(AuthPages.isAuthPage("https://x.example.test/%6Fauth2/start"))
        XCTAssertTrue(AuthPages.isAuthPage("https://x.example.test/%6f%61uth/x"))
        XCTAssertTrue(AuthPages.isAuthPage("https://x.example.test/a/%2e%2e/OAuth/x"))
        XCTAssertTrue(AuthPages.isAuthPage(#"https://x.example.test/a\authorize"#))
        XCTAssertTrue(AuthPages.isAuthPage("https://APPLEID.Apple.com./x"))
        XCTAssertFalse(AuthPages.isAuthPage("https://x.example.test/oauthx/start"))
        XCTAssertFalse(AuthPages.isAuthPage("https://x.example.test/%256fauth/start"), "只解码一次")
    }

    /// nav_host_sample_bp：没有下发按缺省 1000；显式 0 关闭采样；越界夹到 0–10000。
    func testNavHostSampleBpDefaultsTo1000() {
        XCTAssertEqual(WebConfigReader.navHostSampleBp(configJson: "{}"), 1000)
        XCTAssertEqual(WebConfigReader.navHostSampleBp(configJson: #"{"external_page":{}}"#), 1000)
        XCTAssertEqual(WebConfigReader.navHostSampleBp(configJson: #"{"external_page":{"nav_host_sample_bp":0}}"#), 0)
        XCTAssertEqual(
            WebConfigReader.navHostSampleBp(configJson: #"{"external_page":{"nav_host_sample_bp":250}}"#),
            250
        )
        XCTAssertEqual(
            WebConfigReader.navHostSampleBp(configJson: #"{"external_page":{"nav_host_sample_bp":20000}}"#), 10000
        )
    }

    /// 第 2 轮评审 R2-01（三端共性第 40 条）：类别不在契约枚举里、主机带协议或路径 → 整张表算坏表，回落到包内表。
    func testInvalidCategoryOrHostMakesTheWholeTableBad() {
        let bundled: [String: Any] = ["version": "b", "rules": [
            ["platform": "taobao", "category": "union_host", "hosts": ["taobao.example.test"], "path_patterns": []],
        ]]
        let policy = ExternalNavPolicy(bundledLinkPatterns: bundled)
        let variants: [(String, String)] = [
            ("union_hots", "taobao.example.test"),
            ("union_host", "https://taobao.example.test"),
            ("union_host", "taobao.example.test/path"),
            ("union_host", "taobao.example.test:8443"),
        ]
        for (category, host) in variants {
            let bad: [String: Any] = ["version": "c", "rules": [
                ["platform": "jd", "category": "union_host", "hosts": ["jd.example.test"], "path_patterns": []],
                ["platform": "taobao", "category": category, "hosts": [host], "path_patterns": []],
            ]]
            XCTAssertNil(LinkPatterns.parse(bad), "\(category) \(host)")
            for frame in [(true, false), (false, false), (false, true)] {
                XCTAssertEqual(
                    policy.decide(
                        url: "https://shop.taobao.example.test/", isMainFrame: frame.0, isNewWindow: frame.1,
                        linkPatterns: bad
                    ).actionRaw,
                    ExternalNavAction.block,
                    "坏表整表回落到包内表，平台页照样拦下：\(category) \(host) \(frame)"
                )
            }
        }
    }
}
