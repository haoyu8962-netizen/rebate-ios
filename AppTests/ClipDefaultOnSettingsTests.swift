import Clipboard
@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import Privacy
import Router
import XCTest

/// FU-X-CLIP-DEFAULT-ON-ios 设置页开关（BR-ID-16 2026-10-30「设置项三端都显示……游客也显示并可关闭，登录、退出与切换账号不改它；
/// 基本模式不读、不显示」，BR-ID-02 细则设置页剪贴板行；design/specs/app-settings.md「剪贴板开关」行；brief §1 C2、C3、C5、C8）。
/// 经真实 Router 打开 Settings、页面渲染时取出的回调（`SettingsActions`）出发；开关的值经 AppMe 接上的 AppClipboard（`me.clipboard`）
/// 的 `autoSwitch` 读写，与首页自动识别是同一个实例。
///
/// 接线约定（交回 §5）：`SettingsController.clipboardAutoOn: Bool`（渲染用的当前值）；`SettingsActions.clipboardAuto: (Bool) -> Void`
/// （开关行的回调，捕获渲染时的执行器与版本）。打开 / 关闭都直接生效：不出半屏、不出确认框、不发任何请求（不写 clipboard_auto_import）。
@MainActor
final class ClipDefaultOnSettingsTests: MeTestCase {
    private var retained: [AnyObject] = []

    override func tearDown() {
        retained = []
        super.tearDown()
    }

    /// 给 AppMe 接上一个 AppClipboard（AppMe 对它是 weak，这里持有）。
    @discardableResult
    private func attach(_ fixture: MeAppFixture, _ autoSwitch: ClipboardAutoSwitch,
                        system: FakeSystemClipboard = FakeSystemClipboard()) -> AppClipboard {
        let clipboard = AppClipboard(
            system: system, store: MemoryClipboardHashStore(), api: FakeParseApi(), router: fixture.router,
            deps: AppClipboard.Deps(
                privacy: { .consented }, privacyPrompting: { false }, forceUpdate: { false },
                configJson: { "{}" }, guest: { !fixture.login.loggedIn },
                sessionGeneration: { fixture.client.sessionGeneration }, networkEpoch: { 1 }
            ),
            autoSwitch: autoSwitch
        )
        fixture.me.clipboard = clipboard
        retained += [clipboard, system]
        return clipboard
    }

    private func settings(_ fixture: MeAppFixture) throws -> SettingsController {
        let entry = try XCTUnwrap(fixture.open("Settings"))
        entry.appeared()
        return try XCTUnwrap(entry.controller() as? SettingsController)
    }

    private func clipboardRows(_ controller: SettingsController) -> [SettingsRow] {
        controller.model().groups.flatMap(\.rows).filter { $0.id == SettingsItems.idClipboard }
    }

    private func toggle(_ controller: SettingsController, _ on: Bool) {
        SettingsActions.make(controller, controller.state).clipboardAuto(on)
    }

    private func assertNoSheetDialogOrConsent(_ controller: SettingsController, _ step: String) {
        XCTAssertNil(controller.state.sheet, "\(step)：不出用途说明半屏（C2）")
        XCTAssertNil(controller.state.dialog, "\(step)：不出确认框")
        XCTAssertTrue(requests("POST", "/v1/consents").isEmpty, "\(step)：不写 clipboard_auto_import（C3）")
    }

    func testGuestSeesSwitchDefaultOnAndTogglesDirectlyC8() throws {
        let fixture = make(account: nil)
        let autoSwitch = ClipboardAutoSwitch(store: MemoryClipboardHashStore())
        attach(fixture, autoSwitch)
        let controller = try settings(fixture)
        XCTAssertEqual(clipboardRows(controller).count, 1, "已同意隐私政策的游客也有开关行")
        XCTAssertTrue(controller.clipboardAutoOn, "默认开启")
        toggle(controller, false)
        XCTAssertFalse(autoSwitch.isOn, "关闭直接生效")
        XCTAssertFalse(controller.clipboardAutoOn)
        assertNoSheetDialogOrConsent(controller, "关闭")
        toggle(controller, true)
        XCTAssertTrue(autoSwitch.isOn, "打开直接生效、不出弹层")
        XCTAssertTrue(controller.clipboardAutoOn)
        assertNoSheetDialogOrConsent(controller, "打开")
    }

    func testMemberSeesSwitchAndAccountSwitchDoesNotChangeItC8() async throws {
        let fixture = make()
        let autoSwitch = ClipboardAutoSwitch(store: MemoryClipboardHashStore())
        attach(fixture, autoSwitch)
        let controller = try settings(fixture)
        await waitUntil("Me 没到") { fixture.me.deps.repo.state.me != nil }
        let general = controller.model().groups.first { $0.name == SettingsItems.groupGeneral }
        XCTAssertEqual(general?.rows.filter { $0.id == SettingsItems.idClipboard }.count, 1, "已登录：在「通用」组")
        XCTAssertTrue(controller.clipboardAutoOn)
        toggle(controller, false)
        XCTAssertFalse(autoSwitch.isOn)
        assertNoSheetDialogOrConsent(controller, "已登录关闭")
        // 切换账号：开关是设备级，不随账号走
        try fixture.switchAccount(to: "user-b")
        await settle()
        fixture.router.path = []
        let again = try settings(fixture)
        XCTAssertFalse(autoSwitch.isOn, "换账号后仍关闭")
        XCTAssertFalse(again.clipboardAutoOn, "新身份的设置页显示关闭")
        XCTAssertEqual(clipboardRows(again).count, 1)
    }

    func testBasicModeHasNoSwitchRowAndKeepsUserValueC7C8() throws {
        let fixture = make(account: nil, decision: "basic_mode")
        let store = MemoryClipboardHashStore()
        XCTAssertTrue(ClipboardAutoSwitch(store: store).set(false))
        attach(fixture, ClipboardAutoSwitch(store: store))
        let controller = try settings(fixture)
        XCTAssertTrue(clipboardRows(controller).isEmpty, "基本模式不显示这一行")
        XCTAssertFalse(ClipboardAutoSwitch(store: store).isOn, "基本模式不清用户的关闭态")
    }

    /// 设置页关 → 回首页回前台不探测；再开 → 下一次回前台照常探测并出提示条（同一个开关实例贯穿设置页与首页自动识别）。
    func testSettingsToggleDrivesHomeAutoDetectionC5() throws {
        let fixture = make(account: nil)
        let autoSwitch = ClipboardAutoSwitch(store: MemoryClipboardHashStore())
        let system = FakeSystemClipboard()
        system.detectHit = true
        system.changeCount = 1
        let clipboard = attach(fixture, autoSwitch, system: system)
        clipboard.sceneActive()
        XCTAssertEqual(system.detectCalls, 1, "默认开启：冷启动探测")
        toggle(try settings(fixture), false)
        fixture.router.path = []
        clipboard.sceneBackground()
        system.changeCount += 1
        clipboard.sceneActive()
        XCTAssertEqual(system.detectCalls, 1, "设置页关闭后回首页回前台：不探测")
        XCTAssertNil(clipboard.prompt)
        toggle(try settings(fixture), true)
        fixture.router.path = []
        clipboard.sceneBackground()
        system.changeCount += 1
        clipboard.sceneActive()
        XCTAssertEqual(system.detectCalls, 2, "重新打开：下一次回前台照常探测")
        XCTAssertNotNil(clipboard.prompt)
    }
}
