@testable import Couli
import DesignSystem
import Foundation
import MeCore
import UIKit
import XCTest

/// APP-12w-a 修改昵称（brief §2 第 10 条，G-S09、G-S10）：白卡内标签 + 输入 + 说明，【保存】在底部固定栏。iOS 走「TextField + 组件库外框」（brief §7），
/// 不是 Android 的 CouliTextField：计数在框内（画板位置）。错误用错误色（现状警告色）。
@MainActor
final class SettingsVisualNicknameTests: SettingsVisualTestCase {
    private var limitInput: String {
        get throws {
            try SettingsVisualData.nicknameInput("limit")
        }
    }

    /// 卡：左右 16、导航栏下 8、内边距 16、纵向 8：标签 17 → 输入框 → 说明 12（说明移进卡内）。
    func testCardStructure() async throws {
        try await openNickname()
        let card = try rect("nickname.card")
        let label = try record("nickname.label")
        let field = try rect("nickname.field")
        let hint = try rect("nickname.hint")
        assertNear(card.minX, 16, 1, "左边距")
        assertNear(card.width, 358, 1, "通栏")
        try assertNear(card.minY - navBottom(), 8, 2, "内容上 8（现状 16）")
        XCTAssertEqual(label.text, "昵称", "卡内可见标签")
        try assertBase("nickname.label", 17, "标签")
        assertNear(label.rect.minY - card.minY, 16, 2, "内边距 16")
        assertNear(field.minY - label.rect.maxY, 8, 2, "标签到框 8")
        XCTAssertGreaterThanOrEqual(field.height, 43.5, "框高 ≥ 44")
        assertNear(field.minX - card.minX, 16, 1, "框左齐内边距")
        assertNear(card.maxX - field.maxX, 16, 1, "框右齐内边距")
        assertNear(hint.minY - field.maxY, 8, 2, "框到说明 8")
        try assertBase("nickname.hint", 12, "说明")
        assertInside(hint, card, "说明在卡内")
        assertNear(card.maxY - hint.maxY, 16, 2, "内边距 16")
    }

    /// 框内：输入 → 计数 12 → 清除（视觉 16、命中 44，贴框右）；计数在清除之前（现状相反）；不撑高框。
    func testFieldContents() async throws {
        try await openNickname()
        let field = try rect("nickname.field")
        let counter = try record("nickname.counter")
        XCTAssertEqual(counter.text, "4/16")
        try assertBase("nickname.counter", 12, "计数")
        assertInside(counter.rect, field, "计数在框内")
        try assertHitCentered("nickname.clear.hit", covers: "nickname.clear.icon", visual: 16, "清除")
        let hit = try rect("nickname.clear.hit")
        XCTAssertLessThanOrEqual(counter.rect.maxX, hit.minX + 0.5, "计数在清除之前")
        assertNear(field.maxX, hit.maxX, 1.5, "清除贴框右")
        assertNear(field.height, 44, 1.5, "命中区不撑高框")
    }

    /// 空输入：没有清除按钮、0/16、【保存】置灰（现状判定）。
    func testEmptyInput() async throws {
        try await openNickname()
        try nicknameActions.clear()
        _ = try await frame { host in host.probes["nickname.counter"]?.text == "0/16" }
        XCTAssertFalse(has("nickname.clear.hit"), "空时没有清除")
        XCTAssertFalse(try nickname.state.check.saveEnabled)
    }

    /// 底部固定栏：白底、贴页底（含安全区 34）、上内边距 12、左右 16、按钮通栏 ≥ 48；不随内容滚动。
    func testBottomBar() async throws {
        let image = try await openNickname()
        let bar = try rect("nickname.bar")
        let button = try rect("nickname.save.button")
        assertNear(bar.minX, 0, 1, "通栏")
        assertNear(bar.width, 390, 1, "通栏")
        XCTAssertGreaterThanOrEqual(bar.maxY, 1065, "贴页底")
        assertNear(button.minY - bar.minY, 12, 2, "上内边距 12")
        assertNear(1100 - button.maxY, 34, 2, "下内边距 = 安全区 34（G-S09「12/16 + 底部安全区」）")
        assertNear(button.minX, 16, 1, "左右 16")
        assertNear(button.width, 358, 1, "通栏按钮")
        XCTAssertGreaterThanOrEqual(button.height, 47.5, "高 48")
        XCTAssertLessThan(try rect("nickname.card").maxY, bar.minY, "卡在栏上方")
        let white = pixel(CouliColor.backgroundSurface, dark: false)
        let edge = CGRect(x: 4, y: bar.minY + 6, width: 8, height: 12)
        XCTAssertGreaterThan(share(image, in: edge, near: white, tolerance: 3), 0.9, "白底（现状无底栏）")
        let foot = CGRect(x: 100, y: 1088, width: 190, height: 8)
        XCTAssertGreaterThan(share(image, in: foot, near: white, tolerance: 3), 0.9, "白底铺到屏底")
    }

    /// 普通态外框 `border.control`（现状 border.subtle，浅色近乎看不见）。
    func testFieldBorderControl() async throws {
        let image = try await openNickname()
        let field = try rect("nickname.field")
        let line = CGRect(x: field.minX - 0.5, y: field.midY - 6, width: 2, height: 12)
        XCTAssertGreaterThan(
            count(image, in: line, near: pixel(CouliColor.borderControl, dark: false), tolerance: 20),
            10
        )
    }

    /// 字段错误写法同一套：框 2 错误色、框下 14 错误色带图标、错误在框与说明之间。
    private func assertFieldError(_ text: String, image: UIImage, file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let error = try record("nickname.error", file: file, line: line)
        XCTAssertEqual(error.text, text, file: file, line: line)
        try assertBase("nickname.error", 14, "错误句", file: file, line: line)
        let field = try rect("nickname.field", file: file, line: line)
        let hint = try rect("nickname.hint", file: file, line: line)
        XCTAssertGreaterThanOrEqual(error.rect.minY, field.maxY - 0.5, "错误在框下", file: file, line: line)
        XCTAssertLessThanOrEqual(error.rect.maxY, hint.minY + 0.5, "错误在说明之上", file: file, line: line)
        let icon = try rect("nickname.error.icon", file: file, line: line)
        XCTAssertLessThanOrEqual(icon.width, 21, "图标", file: file, line: line)
        assertNear(error.rect.minX - icon.maxX, 4, 1.5, "图标到文字 4", file: file, line: line)
        let red = pixel(CouliColor.statusErrorText, dark: false)
        XCTAssertGreaterThan(count(image, in: error.rect, near: red), 20, "错误色文字（现状警告色）", file: file, line: line)
        let border = CGRect(x: field.minX, y: field.midY - 6, width: 2, height: 12)
        XCTAssertGreaterThan(share(image, in: border, near: red, tolerance: 20), 0.7, "框 2 错误色", file: file, line: line)
    }

    /// 30415：保留输入、错误写法；G-S10 不置灰（再点再发一次）。
    func testLimitErrorKeepsSaveEnabled() async throws {
        try await openNickname()
        try await save(limitInput, reply: SettingsVisualData.limit)
        let image = try await frame("nickname.error")
        try assertFieldError("本月昵称修改次数已用完，下月可再修改", image: image)
        XCTAssertEqual(try nickname.state.input, try limitInput, "保留输入")
        XCTAssertTrue(try nickname.state.check.saveEnabled, "G-S10 不置灰")
        let button = try rect("nickname.save.button")
        let fill = CGRect(x: button.minX + 10, y: button.midY - 4, width: 10, height: 8)
        XCTAssertGreaterThan(
            share(image, in: fill, near: pixel(CouliColor.brandPrimary, dark: false), tolerance: 6),
            0.9,
            "【保存】仍是可点的主色"
        )
        try await save(limitInput, reply: SettingsVisualData.limit)
        XCTAssertEqual(page?.fixture.nickname.calls.count, 2, "再点再发一次")
    }

    /// 20001 nickname_sensitive：同一错误写法，【保存】可点。
    func testSensitiveError() async throws {
        try await openNickname()
        let input = try SettingsVisualData.nicknameInput("sensitive")
        try await save(input, reply: SettingsVisualData.sensitive)
        let image = try await frame("nickname.error")
        try assertFieldError(settings.deps.texts.text("error.20001.nickname_sensitive"), image: image)
        XCTAssertTrue(try nickname.state.check.saveEnabled)
    }

    /// 超长 17 字：17/16、错误句、【保存】置灰；计数超长色走错误色。
    func testTooLong() async throws {
        try await openNickname()
        try nicknameActions.input(SettingsVisualData.nickname("tooLong"))
        let image = try await frame("nickname.error")
        XCTAssertEqual(try text("nickname.counter"), "17/16")
        try assertFieldError("昵称最多 16 个字", image: image)
        XCTAssertFalse(try nickname.state.check.saveEnabled)
    }

    /// 保存中：按钮 loading 且不可再发（现状已符合，换栏后守卫）；放行后关子页、提示一次。
    func testSavingState() async throws {
        let held = HeldNicknameBackend()
        try await openNickname(Setup(held: held), waitFor: "nickname.save.button")
        try nicknameActions.input("小狸省钱王")
        try nicknameActions.save()
        await waitUntil("没有挂住") { held.held }
        XCTAssertTrue(try nickname.state.saving)
        try nicknameActions.save()
        await settle()
        held.release(.success(data: Data("{}".utf8), traceId: nil, idempotencyKey: nil))
        await waitUntil("没有关子页") { (try? self.settings.nickname) == nil }
        XCTAssertEqual(try settings.state.sub, .none)
    }

    /// 错误 assertive 一次、布局后移焦一次（共性第 25、37 条）；同一错误持续不重复播。
    func testErrorAnnouncedOnceAndFocused() async throws {
        try await openNickname(waitFor: nil)
        try await save(limitInput, reply: SettingsVisualData.limit)
        await waitUntil("焦点没有移到错误") { self.focused == ["nickname.error"] }
        XCTAssertEqual(announcements.filter(\.assertive).count, 1, "assertive 一次")
        await quietWindow(0.5)
        XCTAssertEqual(focused.count, 1)
        XCTAssertEqual(announcements.count, 1)
    }

    /// 离开清草稿（G29）、返回关子页不跳出设置页（换栏后守卫）。
    func testLeaveClearsDraft() async throws {
        try await openNickname(waitFor: nil)
        let controller = try nickname
        try nicknameActions.input("草稿")
        try actions.closeSub()
        XCTAssertEqual(controller.state.input, "", "草稿清空")
        XCTAssertEqual(try settings.state.sub, .none)
        XCTAssertNil(try settings.nickname)
    }
}
