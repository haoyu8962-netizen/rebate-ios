@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// APP-12w-a 大字号 / 窄屏 / 大屏（brief §2.1、§4.6、§4.7；AX3 ≈ 200%）。不截断不缩小，宽度与位置都比；字号确实放大。
/// 半屏、确认框是页内覆盖层，`dynamicTypeSize` 环境进得去，这里直接断言放大（系统 `.sheet` 那个坑不涉及）。
@MainActor
final class SettingsVisualAdaptTests: SettingsVisualTestCase {
    private let ax3 = DynamicTypeSize.accessibility3
    private let widths: [CGFloat] = [390, 320]

    private func large(_ width: CGFloat, height: CGFloat = 3000, profile: String = "settings_long_nickname") -> Setup {
        Setup(profile: profile, canvas: .init(width: width, height: height, size: ax3))
    }

    private func assertLarge(_ id: String, _ message: String, file: StaticString = #filePath,
                             line: UInt = #line) throws {
        let item = try record(id, file: file, line: line)
        XCTAssertGreaterThan(item.fontSize, item.baseFontSize * 1.3, "\(message) 真放大", file: file, line: line)
    }

    /// 已登录：分组名、行标题、16 字昵称值、副标题、退出按钮完整；值过长时标题不被挤成一字一行。
    func testMember() async throws {
        for width in widths {
            try await open(large(width), waitFor: "settings.logout.label")
            let account = try rect("settings.group.account")
            try assertLarge("settings.row.nickname.title", "\(width) 行标题")
            try assertWhole("settings.group.account.title", inside: CGRect(x: 0, y: 0, width: width, height: 3000),
                            "\(width) 分组名")
            let title = try record("settings.row.nickname.title")
            XCTAssertGreaterThanOrEqual(title.rect.width + 0.5, title.naturalWidth, "\(width) 标题不被挤窄")
            try assertWhole("settings.row.nickname.value", inside: account, "\(width) 16 字昵称")
            XCTAssertEqual(try text("settings.row.nickname.value").count, 16, "\(width) 不省略")
            let general = try rect("settings.group.general")
            try assertWhole("settings.row.clipboard_auto.subtitle", inside: general, "\(width) 副标题")
            try assertDisjoint(rect("settings.row.clipboard_auto.subtitle"), rect("settings.row.clipboard_auto.switch"),
                               "\(width) 副标题 / 开关")
            try assertWhole("settings.logout.label", inside: rect("settings.logout.button"), "\(width) 退出")
        }
    }

    /// 长标题 + 长值（v2，补变异 V20 空白）：标题单行不被挤窄，值换到标题下一行、不省略。`testMember` 的「昵称」太短，HStack 也不挤它。
    func testLongTitleAndValueWrap() async throws {
        let title = "账号昵称"
        for width in widths {
            var setup = large(width)
            setup.overrides = ["settings.nickname": title]
            try await open(setup, waitFor: "settings.row.nickname.value")
            let row = try rect("settings.row.nickname")
            let name = try record("settings.row.nickname.title")
            let value = try record("settings.row.nickname.value")
            XCTAssertEqual(name.text, title, "\(width) 文案替换生效")
            XCTAssertGreaterThanOrEqual(name.rect.width + 0.5, name.naturalWidth, "\(width) 标题不被挤窄")
            XCTAssertLessThan(name.rect.height, name.fontSize * 2, "\(width) 标题单行")
            XCTAssertGreaterThanOrEqual(value.rect.minY, name.rect.maxY - 0.5, "\(width) 值换到标题下一行")
            XCTAssertEqual(value.text.count, 16, "\(width) 不省略")
            try assertWhole("settings.row.nickname.value", inside: row, "\(width) 长值")
        }
    }

    func testGuest() async throws {
        for width in widths {
            try await open(Setup(level: .guest, canvas: .init(width: width, height: 3000, size: ax3)),
                           waitFor: "settings.guest.link")
            let screen = CGRect(x: 0, y: 0, width: width, height: 3000)
            try assertWhole("settings.guest.text", inside: screen, "\(width) 说明")
            try assertWhole("settings.guest.link", inside: screen, "\(width) 链接")
            try assertLarge("settings.guest.link", "\(width) 链接")
            try assertHit("settings.guest.link.hit", covers: "settings.guest.link", "\(width) 去登录")
        }
    }

    func testBasic() async throws {
        for width in widths {
            try await open(Setup(level: .basic, canvas: .init(width: width, height: 3000, size: ax3)),
                           waitFor: "settings.basic.notice.text")
            try assertWhole("settings.basic.notice.text", inside: rect("settings.basic.notice"), "\(width) 提示句")
            try assertWhole("settings.enableFull.label", inside: rect("settings.enableFull.button"), "\(width) 按钮")
            try assertLarge("settings.basic.notice.text", "\(width) 提示句")
        }
    }

    /// 协议半屏：标题、两行完整放大；面板在屏内。
    func testAgreementSheet() async throws {
        for width in widths {
            try await open(large(width, height: 1400, profile: "settings_member"))
            try tapRow("用户协议与隐私政策")
            _ = try await frame("settings.agreement.privacy.title")
            let panel = try rect("settings.sheet.panel")
            try assertWhole("settings.sheet.title", inside: panel, "\(width) 标题")
            try assertWhole("settings.agreement.agreement.title", inside: panel, "\(width) 用户协议")
            try assertLarge("settings.agreement.privacy.title", "\(width) 隐私政策")
        }
    }

    /// 退出确认：按钮放不下时整块换行（主在上），不重叠、不出面板。
    func testLogoutDialog() async throws {
        for width in widths {
            try await open(large(width, height: 1400, profile: "settings_member"))
            try actions.askLogout()
            _ = try await frame("settings.dialog.logout.primary")
            let panel = try rect("settings.dialog.logout.panel")
            let primary = try rect("settings.dialog.logout.primary")
            let secondary = try rect("settings.dialog.logout.secondary")
            assertInside(primary, panel, "\(width) 主按钮")
            assertInside(secondary, panel, "\(width) 次按钮")
            assertDisjoint(primary, secondary, "\(width) 两按钮")
            XCTAssertGreaterThanOrEqual(primary.height, 47.5, "\(width) 高")
        }
    }

    /// 昵称 30415：错误句、说明、保存完整；底部栏不压卡（卡可滚）。
    func testNicknameLimit() async throws {
        for width in widths {
            try await openNickname(large(width, height: 1600, profile: "settings_member"))
            try await save(SettingsVisualData.nicknameInput("limit"), reply: SettingsVisualData.limit)
            _ = try await frame("nickname.error")
            let card = try rect("nickname.card")
            try assertWhole("nickname.error", inside: card, "\(width) 错误句")
            try assertWhole("nickname.hint", inside: card, "\(width) 说明")
            try assertLarge("nickname.error", "\(width) 错误句")
            try assertWhole("nickname.save.label", inside: rect("nickname.save.button"), "\(width) 保存")
            try assertHit("nickname.clear.hit", covers: "nickname.clear.icon", "\(width) 清除")
        }
    }

    /// 通知已拒绝：提示句整句、去设置完整，命中不撑高条。
    func testNotifyDenied() async throws {
        for width in widths {
            try await openNotify(
                large(width, height: 1600, profile: "settings_member"),
                waitFor: "notify.goSettings.link"
            )
            let bar = try rect("notify.bar")
            try assertWhole("notify.bar.text", inside: bar, "\(width) 提示句")
            try assertWhole("notify.goSettings.link", inside: bar, "\(width) 去设置")
            try assertLarge("notify.bar.text", "\(width) 提示句")
            try assertWhole("notify.desc", inside: rect("notify.card"), "\(width) 说明")
        }
    }

    /// 840：内容限宽 600 居中（现状已符合、加守卫）；昵称底部栏按钮同样限宽。
    func testW840() async throws {
        try await open(Setup(canvas: .init(width: 840, height: 1100)), waitFor: "settings.group.general")
        for id in ["settings.group.account", "settings.group.general", "settings.logout.button"] {
            let box = try rect(id)
            XCTAssertLessThanOrEqual(box.width, 600.5, "\(id) 限宽")
            assertNear(box.midX, 420, 1, "\(id) 居中")
        }
        try await openNickname(Setup(canvas: .init(width: 840, height: 1100)))
        for id in ["nickname.card", "nickname.save.button"] {
            let box = try rect(id)
            XCTAssertLessThanOrEqual(box.width, 600.5, "\(id) 限宽")
            assertNear(box.midX, 420, 1, "\(id) 居中")
        }
    }
}
