import UIKit
import XCTest

/// FU-X-CLIP-DEFAULT-ON-ios 真点 UI 测试（BR-ID-16 2026-10-30；brief §1 C1、C2、C5、C6、C8；变更记录 §6 验收）：Debug 包 + 本机假服务
/// （`-CouliFakeLoginServer`）+ 剪贴板计数（`-CouliClipboardDiagnostics`：detect / parse / writes，不含内容）。测试进程往系统剪贴板写
/// 演示链接，模拟别的 App 复制。
///
/// 新 Debug 输入（实现者接，交回 §5）：`-CouliClipboardSwitchReset 1`：在 AppClipboard 组装之前清掉本机开关存储（回到「从未选择」），
/// 只在 Debug / Staging 编译。开关行标识 `settings.row.clipboard_auto`（MeSwitchRow：读屏值「开关，已打开 / 已关闭」）。
/// 旧键 `couli.clipboard.autoDetect` 经启动参数放进 UserDefaults 参数域，验证它不影响新开关（C6）。
@MainActor
final class ClipDefaultOnUITests: XCTestCase {
    private let link = "【淘宝】全脂纯牛奶 https://e.tb.cn/h.Demo01?tk=Sample 「全脂纯牛奶 250ml」 复制这段话打开"
    /// 用例里关过开关时，结束后把本机开关恢复为「从未选择」，不影响后面的剪贴板 UI 测试。
    private var leftOff = false

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        if leftOff {
            let app = XCUIApplication()
            app.terminate()
            UIPasteboard.general.string = "今天下午三点见"
            app.launchArguments = [
                "-CouliPrivacyPreset",
                "consented",
                "-CouliFakeLoginServer",
                "-CouliUpdateReset",
                "1",
                "-CouliClipboardSwitchReset",
                "1",
            ]
            app.launch()
            _ = ShellTabBar.bar(app).waitForExistence(timeout: 30)
            app.terminate()
        }
        try await super.tearDown()
    }

    private func launch(reset: Bool, clip: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        UIPasteboard.general.string = clip
        app.launchArguments = [
            "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1", "-CouliClipboardDiagnostics",
        ] + (reset ? ["-CouliClipboardSwitchReset", "1"] : []) + extra
        app.launch()
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func detectCount(_ app: XCUIApplication) -> Int {
        let label = element(app, "clipboard.debug")
        XCTAssertTrue(label.waitForExistence(timeout: 5), "没有剪贴板计数")
        let text = label.label
        guard let range = text.range(of: #"detect=\d+"#, options: .regularExpression) else {
            XCTFail("计数格式不对：\(text)")
            return -1
        }
        return Int(text[range].dropFirst("detect=".count)) ?? -1
    }

    private func parseCount(_ app: XCUIApplication) -> String {
        element(app, "clipboard.debug").label
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let target = element(app, id)
        var found = target.waitForExistence(timeout: 15)
        for _ in 0..<5 where !found || !target.isHittable {
            app.swipeUp()
            found = target.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(found, "没有 \(id)")
        target.tap()
    }

    /// 「我的」→ 设置 → 剪贴板开关行。
    private func switchRow(_ app: XCUIApplication) -> XCUIElement {
        ShellTabBar.tap(app, "我的")
        tap(app, "me.settings")
        XCTAssertTrue(element(app, "settings.page").waitForExistence(timeout: 10), "没有进设置页")
        let row = element(app, "settings.row.clipboard_auto")
        var found = row.waitForExistence(timeout: 5)
        for _ in 0..<4 where !found || !row.isHittable {
            app.swipeUp()
            found = row.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(found, "设置页没有「打开 App 自动识别剪贴板」开关行（C8）")
        return row
    }

    private func value(_ row: XCUIElement) -> String {
        row.value as? String ?? ""
    }

    /// 点开关（行右侧的系统开关），等读屏值变成期望值；全程不出用途说明弹层（C2）。
    private func toggle(_ app: XCUIApplication, _ row: XCUIElement, to on: Bool) {
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let expected = on ? "已打开" : "已关闭"
        UIWait.until("开关没有变成「\(expected)」（现在：\(value(row))）", ceiling: 5) { value(row).contains(expected) }
        XCTAssertFalse(element(app, "clipboard.consent.sheet").exists, "打开 / 关闭不出用途说明弹层")
        XCTAssertEqual(app.alerts.count, 0, "打开 / 关闭不出确认框")
    }

    private func backHome(_ app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
        ShellTabBar.tap(app, "首页")
        XCTAssertTrue(element(app, "clipboard.homeCard.paste").waitForExistence(timeout: 10), "没有回到首页")
    }

    private func backgroundAndReturn(_ app: XCUIApplication, clip: String) {
        XCUIDevice.shared.press(.home)
        UIPasteboard.general.string = clip
        sleep(1)
        app.activate()
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 10))
    }

    /// 默认开启（旧键 false 也不影响）→ 设置页点关 → 回首页复制商品链接回前台不读取 → 杀进程重启仍关、冷启动不读 → 再开 → 回前台照常读取。
    func testSettingsSwitchDefaultOnOffStopsReadingSurvivesRelaunchOnReadsAgain() {
        var app = launch(reset: true, clip: link + " 冷启动", extra: ["-couli.clipboard.autoDetect", "NO"])
        let prompt = element(app, "clipboard.prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "全新安装默认开启：冷启动命中链接直接出提示条（C1、C6 旧键不影响）")
        XCTAssertFalse(element(app, "clipboard.consent.sheet").exists, "没有用途说明弹层（C2）")
        element(app, "clipboard.prompt.close").tap()

        var row = switchRow(app)
        XCTAssertTrue(value(row).contains("已打开"), "开关默认开启（C8）：\(value(row))")
        toggle(app, row, to: false)
        leftOff = true
        backHome(app)
        let before = detectCount(app)
        backgroundAndReturn(app, clip: link + " 关闭后")
        sleep(2)
        XCTAssertFalse(prompt.exists, "关闭后复制商品链接回前台：不出提示条（C5）")
        XCTAssertEqual(detectCount(app), before, "关闭后回前台不探测（detectPatterns 也不做）")
        XCTAssertTrue(parseCount(app).contains("parse=0"), "零上传：\(parseCount(app))")

        // 杀进程重启（不清开关）：仍关闭，冷启动也不读
        app = launch(reset: false, clip: link + " 重启后")
        sleep(2)
        XCTAssertFalse(element(app, "clipboard.prompt").exists, "重启后仍关闭：冷启动不出提示条")
        XCTAssertEqual(detectCount(app), 0, "重启后冷启动不探测")
        row = switchRow(app)
        XCTAssertTrue(value(row).contains("已关闭"), "重启后设置页仍显示关闭：\(value(row))")

        toggle(app, row, to: true)
        leftOff = false
        backHome(app)
        let reopened = detectCount(app)
        backgroundAndReturn(app, clip: link + " 再打开")
        XCTAssertTrue(element(app, "clipboard.prompt").waitForExistence(timeout: 10), "重新打开后回前台照常识别")
        XCTAssertEqual(detectCount(app), reopened + 1)
    }

    /// 关闭态下手动粘贴照常（C5「手动粘贴照常」）：首页常驻卡的系统粘贴控件仍能识别并打开详情。
    func testManualPasteStillWorksWhileSwitchOff() {
        let app = launch(reset: true, clip: "今天下午三点见")
        let row = switchRow(app)
        toggle(app, row, to: false)
        leftOff = true
        backHome(app)
        UIPasteboard.general.string = link + " 手动"
        element(app, "clipboard.homeCard.paste").tap()
        XCTAssertTrue(element(app, "product.buy").waitForExistence(timeout: 15), "关闭后手动粘贴仍识别并打开详情")
        XCTAssertTrue(parseCount(app).contains("parse=1"), "手动粘贴恰好 1 次请求：\(parseCount(app))")
    }
}
