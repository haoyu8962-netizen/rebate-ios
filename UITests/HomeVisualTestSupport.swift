import CryptoKit
import Foundation
import UIKit
import XCTest

struct HomeVisualCase: Codable {
    var name: String
    var page: String
    var scene: String
    var level: String
    var dark: Bool
    var width: Int
    var height: Int
    var category: String

    static func standard(scene: String = "normal", level: String = "guest", width: Int = 390,
                         category: String = "large") -> HomeVisualCase {
        HomeVisualCase(name: scene, page: level == "member" ? "main_v3" : "guest_v3", scene: scene,
                       level: level, dark: false, width: width, height: 844, category: category)
    }
}

enum HomeVisualFiles {
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    static func cases() throws -> [HomeVisualCase] {
        struct Manifest: Decodable { let fixtureSHA256: String; let cases: [HomeVisualCase] }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent(
            "specs/home-visual-cases.json"
        )))
        let data = try Data(contentsOf: root.appendingPathComponent("specs/home-sdui-vectors.json"))
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), manifest.fixtureSHA256)
        XCTAssertEqual(manifest.cases.count, 27)
        XCTAssertEqual(Set(manifest.cases.map(\.name)).count, 27)
        return manifest.cases
    }

    static func request(_ item: HomeVisualCase, overrides: HomeVisualRequestOverrides = .init()) throws -> String {
        let data = try Data(contentsOf: root.appendingPathComponent("specs/home-sdui-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pages = try XCTUnwrap(root["goldenPages"] as? [String: Any])
        var page = try XCTUnwrap(pages[item.page] as? [String: Any])
        if item.scene == "rank" {
            var sections = try XCTUnwrap(page["sections"] as? [[String: Any]])
            var source = try XCTUnwrap(sections[0]["data_source"] as? [String: Any])
            var icons = try XCTUnwrap(source["items"] as? [[String: Any]])
            icons[8] = ["title": "热销榜", "icon": "https://img.example.test/rank.png", "action": ["route": "HotRankList"]]
            source["items"] = icons
            sections[0]["data_source"] = source
            page["sections"] = sections
        }
        if item.scene.hasPrefix("stress_") || item.scene.hasPrefix("no_rebate_") {
            let kind = String(item.scene.split(separator: "_").last ?? "")
            var sections = try XCTUnwrap(page["sectionItems"] as? [String: Any])
            var response = try XCTUnwrap(sections[kind] as? [String: Any])
            var cards = try XCTUnwrap(response["items"] as? [[String: Any]])
            for index in cards.indices {
                if item.scene.hasPrefix("stress_") {
                    cards[index]["price_fen"] = 10999999
                    cards[index]["coupon_fen"] = 1000000
                    cards[index]["final_price_fen"] = 9999999
                    cards[index]["rebate_min_fen"] = 8888888
                    cards[index]["rebate_max_fen"] = 9999999
                    cards[index]["est_net_price_fen"] = 1111111
                } else {
                    cards[index]["coupon_fen"] = 0
                    cards[index]["final_price_fen"] = cards[index]["price_fen"]
                    cards[index]["rebate_basis"] = "no_rebate"
                    cards[index]["rebate_min_fen"] = NSNull()
                    cards[index]["rebate_max_fen"] = NSNull()
                    cards[index]["est_net_price_fen"] = NSNull()
                    cards[index]["disclaimer_keys"] = ["price_basis.general"]
                    cards[index]["benefit_tags"] = [] as [String]
                }
            }
            response["items"] = cards; sections[kind] = response; page["sectionItems"] = sections
        }
        page = try overrides.page(page)
        let settings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item))
        let envelope: [String: Any] = ["version": 1, "settings": settings, "fixture": page,
                                       "banner": pages["banner"] ?? [:],
                                       "notice": try overrides.notice(pages["notice_static"])]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).base64EncodedString()
    }
}

/// 生产 App 的 Debug 启动适配器接口见 handback §2。未接入时明确失败，不跳过、不回退旧 main。
@MainActor
class HomeVisualUITestCase: XCTestCase {
    var app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        await MainActor.run { app.terminate() }
    }

    func launch(_ item: HomeVisualCase = .standard(), overrides: HomeVisualRequestOverrides = .init()) throws {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-CouliPrivacyPreset", item.level == "basic" ? "basic" : "consented",
                               "-CouliFakeLoginServer", "-CouliHomeTestReset", "1", "-CouliHideDebugInfo", "1",
                               "-CouliUpdateReset", "1", "-CouliHomeVisual", "1"]
        app.launchEnvironment["COULI_HOME_VISUAL_REQUEST"] = try HomeVisualFiles.request(item, overrides: overrides)
        app.launch()
        XCTAssertTrue(element("home.visual.ready").waitForExistence(timeout: 20), "缺 Debug 场景接线，不能用旧 main 冒充")
        XCTAssertEqual(element("home.visual.ready").value as? String, item.name)
        XCTAssertTrue(element("shell.tabBar").exists)
        let state = try diagnostics()
        XCTAssertEqual(state.level, item.level)
        XCTAssertEqual(state.scene, item.scene)
        if !["loading", "invalid", "bundled"].contains(item.scene) {
            XCTAssertEqual(state.pageVersion, 31)
        }
        XCTAssertEqual(state.unexpectedRequests, 0, "所有图片和 API 必须使用本机替身")
        if ["normal", "rank"].contains(item.scene) {
            XCTAssertEqual(state.sectionCounts, ["icons": 10, "scroll": 3, "activities": item.level == "member" ? 2 : 1,
                                                 "grid": 2, "feed": 4])
        }
    }

    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func reveal(_ id: String) throws -> XCUIElement {
        let target = element(id)
        for _ in 0..<24 {
            if target.exists, target.isHittable {
                return target
            }
            element("home.list").swipeUp(velocity: .slow)
        }
        XCTFail("滚到底仍不可达：\(id)")
        return target
    }

    struct Diagnostics: Decodable {
        let level: String
        let scene: String
        let pageVersion: Int
        let source: String?
        let sectionCounts: [String: Int]
        let pageRequests: Int
        let sectionRequests: Int
        let parseRequests: Int
        let clipboardReads: Int
        let consentRequests: Int
        let promptIdentity: String?
        let unexpectedRequests: Int
        let pasteControlClass: String
        let nativeRevision: Int
        let settled: Bool
    }

    func diagnostics() throws -> Diagnostics {
        try decode("home.visual.diagnostics", as: Diagnostics.self)
    }

    func decode<Value: Decodable>(_ id: String, as type: Value.Type) throws -> Value {
        let json = try XCTUnwrap(element(id).value as? String, "缺少诊断值：\(id)")
        return try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func assertHit(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(target.exists, file: file, line: line)
        XCTAssertTrue(target.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(target.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(target.frame.height, 44, file: file, line: line)
    }

    func keepTree(_ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
