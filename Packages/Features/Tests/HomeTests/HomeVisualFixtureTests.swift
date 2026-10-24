import DesignSystem
import Foundation
@testable import Home
import HomeCore
import XCTest

@MainActor
final class HomeVisualFixtureTests: XCTestCase {
    func testSharedFixtureMembershipAndMoneyAreUnchanged() throws {
        let pages = try SnapshotKit.goldenPages()
        let main = try XCTUnwrap(pages["main_v3"] as? [String: Any])
        let guest = try XCTUnwrap(pages["guest_v3"] as? [String: Any])
        let mainItems = try XCTUnwrap(main["sectionItems"] as? [String: Any])
        let guestItems = try XCTUnwrap(guest["sectionItems"] as? [String: Any])
        XCTAssertEqual(try canonical(mainItems), try canonical(guestItems))
        let all = try ["scroll", "grid", "feed"].flatMap { id -> [[String: Any]] in
            try XCTUnwrap((mainItems[id] as? [String: Any])?["items"] as? [[String: Any]])
        }
        XCTAssertEqual(all.compactMap { $0["final_price_fen"] as? Int64 },
                       [1990, 2680, 880, 1560, 3200, 1234, 4560, 990, 8800])
        XCTAssertEqual(all.compactMap { $0["rebate_min_fen"] as? Int64 }, [110, 90, 42, 78, 160, 56, 234, 30, 321])
        XCTAssertEqual(all.filter { $0["is_presale"] as? Bool == true }.count, 1)
        XCTAssertEqual(all.count, 9)
        XCTAssertTrue(all
            .allSatisfy { ($0["image"] as? String)?.hasPrefix("https://img.example.test/home-v3/") == true })
        for (page, count) in [(main, 2), (guest, 1)] {
            let sections = try XCTUnwrap(page["sections"] as? [[String: Any]])
            XCTAssertEqual(
                sections.compactMap { $0["id"] as? String },
                ["icons", "scroll", "activities", "grid", "feed"]
            )
            let icons = try XCTUnwrap(sections.first?["data_source"] as? [String: Any])
            XCTAssertEqual((icons["items"] as? [Any])?.count, 10)
            let activity = try XCTUnwrap(sections.first { $0["id"] as? String == "activities" })
            XCTAssertEqual(((activity["data_source"] as? [String: Any])?["items"] as? [Any])?.count, count)
        }
    }

    func testBothVisualPagesUseRealDecoderAndSectionResponses() async throws {
        for name in ["main_v3", "guest_v3"] {
            let fixture = try HomeVisualFixture(page: name)
            await fixture.start()
            XCTAssertEqual(fixture.controller.state.source, .network)
            XCTAssertEqual(
                fixture.controller.state.sections.map(\.id),
                ["icons", "scroll", "activities", "grid", "feed"]
            )
            XCTAssertEqual(fixture.controller.state.section("scroll")?.items.count, 3)
            XCTAssertEqual(fixture.controller.state.section("grid")?.items.count, 2)
            XCTAssertEqual(fixture.controller.state.section("feed")?.items.count, 4)
            let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.port.page) as? [String: Any])
            XCTAssertNil(wire["sectionItems"], "测试辅助字段不得进 getPage 协议")
            await fixture.close()
        }
    }

    func testVisualRulesAreConnectedToRequiredStates() {
        // 新 API，签名见 handback §2；UI 测试另外核验生产 RootView 真正调用这些规则。
        XCTAssertTrue(HomeVisualRules.showsGuestValue(level: .guest))
        XCTAssertTrue(HomeVisualRules.showsGuestValue(level: .basic))
        XCTAssertFalse(HomeVisualRules.showsGuestValue(level: .member))
        XCTAssertEqual(HomeVisualRules.popupAccessibilityName, "首页弹窗")
        XCTAssertEqual(HomeVisualRules.pasteControlKind, "UIPasteControl")
        XCTAssertEqual(HomeVisualRules.gridColumns(availableWidth: 288, requiredItemWidth: 160, spacing: 12), 1)
        XCTAssertEqual(HomeVisualRules.gridColumns(availableWidth: 358, requiredItemWidth: 160, spacing: 12), 2)
        XCTAssertEqual(HomeVisualRules.gridColumns(availableWidth: 600, requiredItemWidth: 160, spacing: 12), 2)
    }

    func testScrollSpokenNameKeepsHiddenTitlePlatformAndMoney() throws {
        let page = try XCTUnwrap(try SnapshotKit.goldenPages()["main_v3"] as? [String: Any])
        let section = try XCTUnwrap((page["sectionItems"] as? [String: Any])?["scroll"] as? [String: Any])
        let card = try XCTUnwrap((section["items"] as? [[String: Any]])?.first)
        let data = ProductCardMapper.map(card, texts: { key in
            key == "platform.taobao" ? "淘宝" : SnapshotTexts.values[key] ?? key
        }).data
        let spoken = HomeVisualRules.scrollAccessibilityLabel(data)
        let parts = [data.platformName, data.title, data.price.mainAccessibilityText, data.rebate.accessibilityText]
        var end = spoken.startIndex
        for part in parts {
            let range = try XCTUnwrap(spoken.range(of: part, range: end..<spoken.endIndex), "读屏缺少或顺序不对：\(part)")
            end = range.upperBound
        }
    }

    func testPlatformGridChoiceUsesOfficialImageThenTextFallback() {
        for code in ["taobao", "jd", "pdd"] {
            XCTAssertTrue(PlatformIcon.hasBuiltinImage(code), "F-X-05a 前置素材必须已入包")
            XCTAssertEqual(
                HomeVisualRules.platformIconSource(code: code, hasRemoteImage: false, remoteFailed: false),
                "builtin"
            )
            XCTAssertEqual(
                HomeVisualRules.platformIconSource(code: code, hasRemoteImage: true, remoteFailed: true),
                "builtin"
            )
            XCTAssertEqual(
                HomeVisualRules.platformIconSource(code: code, hasRemoteImage: true, remoteFailed: false),
                "remote"
            )
        }
        XCTAssertEqual(
            HomeVisualRules.platformIconSource(code: "tmall", hasRemoteImage: false, remoteFailed: false),
            "text"
        )
        XCTAssertEqual(
            HomeVisualRules.platformIconSource(code: "unknown", hasRemoteImage: true, remoteFailed: true),
            "text"
        )
    }

    private func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
