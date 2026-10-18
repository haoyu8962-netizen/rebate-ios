import UIKit
import XCTest

/// 首页置灰的真实 App 验收（第 5 版 T-01，第 6 版 T-05、T-07；从 HomeRenderUITests 挪出）：整屏截图里首页区域（状态栏以下、
/// Tab 栏以上）按块统计。
/// - T-01：置灰作用在首页根——SDUI 之外的固定区（搜索入口、剪贴板卡）与 SDUI 内容区都无彩色；基本模式首页同样。
/// - T-05：置灰后首页内容仍然画着——固定区、SDUI 区各自的「内容占比」与亮度标准差不低于同一页彩色时的一半（且有绝对下限），
///   搜索入口、公告、金刚区的元素都在；首页被藏掉 / 变空白（只剩外壳底色）判红。截图失败、区域为空直接判失败。
/// - T-07：同一进程内（不重启）经生产的配置刷新路径（回前台重新拉配置）完成 未置灰 → 置灰 → 解除，画面跟着变；只消费启动配置、
///   不响应后续配置的首页判红。另保留跨启动的三步用例（每次启动的状态只来自那一次的配置）。
@MainActor
final class HomeGrayscaleUITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        // 前序剪贴板 / 深链用例会留下可识别链接：首次启动显示提示卡，下一次又因已读记录不显示，
        // 导致彩色 / 置灰的固定区内容不一致。先结束旧 App 再清系统剪贴板；本套用例不写入新内容。
        // HomeUILaunch 仍逐次清首页 LKG / 偏好；保留常驻粘贴卡和所有置灰、内容量断言。
        XCUIApplication().terminate()
        UIPasteboard.general.items = []
        XCTAssertEqual(UIPasteboard.general.numberOfItems, 0, "前提：置灰用例从空剪贴板开始")
    }

    /// 首页三块区域的同一张截图统计。
    private struct Look: CustomStringConvertible {
        let home: RegionStats
        let fixed: RegionStats
        let sdui: RegionStats

        var description: String {
            "首页区域 {\(home)}；固定区 {\(fixed)}；SDUI 区 {\(sdui)}"
        }
    }

    // MARK: - 跨启动

    /// 完整功能首页：未置灰有彩色 → 配置下发 ui.grayscale 后首页根无彩色且内容仍在 → 去掉开关后彩色恢复。
    func testGrayscaleCoversTheWholeHomeRootAndRecovers() {
        let app = HomeUILaunch.home(page: "main")
        XCTAssertTrue(notice(app).waitForExistence(timeout: 20), "前提：首页画出来了")
        guard let color = waitColored(app, "未置灰") else { return }
        app.terminate()

        let gray = HomeUILaunch.home(page: "main", extra: ["-CouliFakeFlags", "ui.grayscale=true"])
        XCTAssertTrue(notice(gray).waitForExistence(timeout: 20), "前提：置灰启动后首页加载了")
        assertGrayKeepsContent(gray, like: color, "配置下发置灰后")
        gray.terminate()

        let restored = HomeUILaunch.home(page: "main")
        XCTAssertTrue(notice(restored).waitForExistence(timeout: 20), "前提：首页画出来了")
        waitColored(restored, "去掉置灰开关后（重启）")
    }

    // MARK: - 同一进程（T-07）

    /// 同一个首页根视图存活（不重启）：未置灰 → 假服务改开关、App 回前台按生产路径重新拉配置 → 置灰且内容仍在 → 再改回 →
    /// 彩色恢复。全程启动清理信号只发过一次（没有换进程）。
    func testGrayscaleFollowsConfigRefreshInTheSameProcess() {
        let config = DarwinSignal(HomeUITestSignalNames.configServed)
        let reset = DarwinSignal(HomeUITestSignalNames.homeReset)
        let app = HomeUILaunch.home(page: "main")
        XCTAssertTrue(notice(app).waitForExistence(timeout: 20), "前提：首页画出来了")
        UIWait.until("前提：冷启动的配置已由本机假服务回答", ceiling: 20) { config.count >= 1 }
        guard let color = waitColored(app, "冷启动（未置灰）") else { return }

        HomeUITestSignalNames.post(HomeUITestSignalNames.fakeFlagPrefix + "ui.grayscale=true")
        refreshConfig(app, config, "打开置灰")
        assertGrayKeepsContent(app, like: color, "同一进程配置刷新置灰后")

        HomeUITestSignalNames.post(HomeUITestSignalNames.fakeFlagPrefix + "ui.grayscale=false")
        refreshConfig(app, config, "解除置灰")
        waitColored(app, "同一进程配置刷新解除置灰后")
        XCTAssertEqual(reset.count, 1, "前提：全程是同一个进程（启动清理信号只发过一次，没有重新启动）")
    }

    /// 回到桌面再回来：App 回前台按生产路径带 ETag 重新拉配置；等假服务回答这一次配置。
    private func refreshConfig(_ app: XCUIApplication, _ config: DarwinSignal, _ step: String) {
        let before = config.count
        XCUIDevice.shared.press(.home)
        UIWait.until("\(step)：App 进入后台", ceiling: 20) {
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }
        app.activate()
        UIWait.until("\(step)：App 回到前台", ceiling: 20) { app.state == .runningForeground }
        UIWait.until("\(step)：回前台后重新拉配置（假服务回答）", ceiling: 20) { config.count > before }
    }

    // MARK: - 基本模式

    /// 基本模式首页（BasicModeHomeView，顶栏不经 SDUI）：未置灰有彩色 → 置灰无彩色且内容仍在 → 去掉开关后恢复。
    func testGrayscaleCoversTheBasicModeHome() {
        let plain = HomeUILaunch.basic(gray: false)
        var color: RegionStats?
        poll(20) {
            color = HomeScreenShot().flatMap { $0.stats(HomeAreas.home(plain), "基本模式首页", report: false) }
            return (color?.most ?? 0) >= 30
        }
        guard let color, color.most >= 30 else {
            return XCTFail("前提：未置灰时基本模式首页有彩色：\(String(describing: color))")
        }
        plain.terminate()

        let app = HomeUILaunch.basic(gray: true)
        var gray: RegionStats?
        let done = poll(20) {
            gray = HomeScreenShot().flatMap { $0.stats(HomeAreas.home(app), "基本模式首页", report: false) }
            return gray.map { $0.gray && Self.keeps($0, like: color) } ?? false
        }
        if !done {
            keepScreenshot("basic-grayscale-on")
        }
        let final = HomeScreenShot().flatMap { $0.stats(HomeAreas.home(app), "基本模式首页") }
        print("HOME-GRAY-STATS 基本模式：彩色 {\(color)}；置灰 {\(final.map(\.description) ?? "截不到")}")
        XCTAssertTrue(final?.gray == true, "基本模式首页仍有彩色：\(String(describing: final))")
        XCTAssertTrue(
            final.map { Self.keeps($0, like: color) } == true,
            "基本模式首页置灰后没有内容了（变空白）：置灰 \(String(describing: final))；彩色时 \(color)"
        )
        XCTAssertTrue(app.descendants(matching: .any)["basic.search"].firstMatch.exists, "置灰后基本模式搜索框不在了")
        app.terminate()

        let restored = HomeUILaunch.basic(gray: false)
        UIWait.until("去掉置灰开关后基本模式首页彩色恢复", ceiling: 20) {
            (HomeScreenShot().flatMap { $0.stats(HomeAreas.home(restored), "基本模式首页", report: false) }?.most ?? 0) >= 30
        }
    }

    // MARK: - 判定

    private func notice(_ app: XCUIApplication) -> XCUIElement {
        HomeUILaunch.labeled(app, "确认收货后").firstMatch
    }

    private func look(_ app: XCUIApplication, report: Bool) -> Look? {
        guard let shot = HomeScreenShot(),
              let home = shot.stats(HomeAreas.home(app), "首页区域", report: report),
              let fixed = shot.stats(HomeAreas.fixed(app), "固定区（搜索入口、剪贴板卡）", report: report),
              let sdui = shot.stats(HomeAreas.sdui(app), "SDUI 内容区", report: report)
        else { return nil }
        return Look(home: home, fixed: fixed, sdui: sdui)
    }

    /// 等首页有彩色（固定区色差 ≥ 30、首页区 ≥ 80），返回这一刻三块区域的统计（作置灰时内容量的对照）。
    @discardableResult
    private func waitColored(_ app: XCUIApplication, _ step: String) -> Look? {
        var last: Look?
        let done = poll(20) {
            last = look(app, report: false)
            return last.map { $0.fixed.most >= 30 && $0.home.most >= 80 } ?? false
        }
        guard done, let last else {
            keepScreenshot("colored-\(step)")
            XCTFail("\(step)：首页应有彩色（固定区色差 ≥ 30、首页区 ≥ 80）：\(last.map(\.description) ?? "截不到")")
            return nil
        }
        print("HOME-GRAY-STATS \(step)：\(last)")
        return last
    }

    /// 置灰后：首页区域、固定区都无彩色；固定区、SDUI 区内容仍在（与彩色时相当）；关键元素都在。
    private func assertGrayKeepsContent(_ app: XCUIApplication, like color: Look, _ step: String) {
        var last: Look?
        let done = poll(20) {
            last = look(app, report: false)
            return last.map {
                $0.home.gray && $0.fixed.gray && Self.keeps($0.fixed, like: color.fixed) && Self.keeps(
                    $0.sdui,
                    like: color.sdui
                )
            } ?? false
        }
        if !done {
            keepScreenshot("grayscale-\(step)")
        }
        guard let final = look(app, report: true) else { return }
        print("HOME-GRAY-STATS \(step)：\(final)")
        XCTAssertTrue(final.fixed.gray, "\(step)：置灰没有覆盖 SDUI 之外的固定区（搜索入口、剪贴板卡）：\(final.fixed)")
        XCTAssertTrue(final.home.gray, "\(step)：首页区域仍有彩色：\(final.home)")
        XCTAssertTrue(
            Self.keeps(final.fixed, like: color.fixed),
            "\(step)：固定区（搜索入口、剪贴板卡）没有内容了（变空白）：置灰 \(final.fixed)；彩色时 \(color.fixed)"
        )
        XCTAssertTrue(
            Self.keeps(final.sdui, like: color.sdui),
            "\(step)：SDUI 内容区没有内容了（变空白）：置灰 \(final.sdui)；彩色时 \(color.sdui)"
        )
        XCTAssertTrue(app.descendants(matching: .any)["home.search"].firstMatch.exists, "\(step)：搜索入口不在了")
        XCTAssertTrue(notice(app).exists, "\(step)：首页公告不在了")
        XCTAssertTrue(HomeUILaunch.labeled(app, "新人指南").firstMatch.exists, "\(step)：金刚区不在了")
    }

    /// 置灰后内容仍在：内容占比、亮度标准差都不低于彩色时的 70%，且内容占比 ≥ 2%、标准差 ≥ 6（只剩底色时两者都接近 0）。
    /// 标定（第 6 版修好版实测，iPhone 模拟器）：置灰 / 彩色之比，内容占比 固定区 0.062 / 0.062、SDUI 区 0.538 / 0.539；
    /// 标准差 固定区 36.3 / 36.2、SDUI 区 34.9 / 36.3——置灰只去颜色、不动亮度结构，比值约 0.96～1.0；留 0.7 余量给轮播换帧。
    private static func keeps(_ gray: RegionStats, like color: RegionStats) -> Bool {
        gray.ink >= max(0.02, color.ink * 0.7) && gray.spread >= max(6, color.spread * 0.7)
    }

    /// 轮询（每 0.3 秒），上限内成立返回 true；不自行判失败。
    @discardableResult
    private func poll(_ ceiling: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(ceiling)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return true
    }

    /// 失败时留下整屏截图，便于看是哪一块没置灰或变空白。
    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
