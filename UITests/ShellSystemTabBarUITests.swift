import XCTest

/// FU-IOS-NATIVE-TABBAR 真机点击（进程内覆盖不到的部分）：系统标签栏的真实点击过守卫、iOS 26 悬浮样式与滚动收起、
/// iOS 16–25 经典样式截图。首页用 Debug 场景（HomeVisualUITestCase，游客 + goldenPages，本机替身），内容足够滚动好几屏。
/// 截图存进 xcresult（keepAlways）；设了 COULI_SHOT_DIR 时另写 PNG，交回时导出进证据（D10-826 ②、D10-831 ⑥）。
final class ShellSystemTabBarUITests: HomeVisualUITestCase {
    /// 方案 T3 的真机一半：游客点「订单」→ 登录页；关掉登录页回来，仍选中首页、「订单」未选中，首页根可见可点。
    func testGuestTapOnOrdersIsGuardedAndSelectionStaysHome() throws {
        try launch()
        XCTAssertTrue(ShellTabBar.button(app, "首页").isSelected, "前提：选中首页")
        ShellTabBar.tap(app, "订单")
        XCTAssertTrue(element("login.page").waitForExistence(timeout: 10), "游客点订单应进登录页（守卫拦截）")
        element("login.close").tap()
        XCTAssertTrue(element("login.page").waitForNonExistence(timeout: 10), "登录页已关闭")
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 10))
        XCTAssertTrue(ShellTabBar.button(app, "首页").isSelected, "被拦后仍选中首页（绑定回原值）")
        XCTAssertFalse(ShellTabBar.button(app, "订单").isSelected, "被拦后「订单」不被选中")
        XCTAssertTrue(element("home.root").isHittable, "首页根可见可点")
    }

    /// iOS 26：上滑后标签栏收起（.tabBarMinimizeBehavior(.onScrollDown)）；回滑后展开，或仍收起时点胶囊展开（v4，见用例内注释）；
    /// 展开后 4 个 Tab 都能点。两种状态各存一张截图进证据。
    /// v2：XCUI 里 `app.tabBars` 的 frame 是整条容器（实测 (0,761,390,83)），玻璃胶囊画在容器里面，「离屏边留空隙」与「宽度变小」
    /// 都不成立，已删。悬浮 / 不垫实色条改由这些判据承担：Info.plist 与各配置无 UIDesignRequiresCompatibility、源码不覆盖标签栏材质与
    /// 背景、外壳不垫底部色条（ShellSystemTabBarSourceTests）；首页滚动容器铺到窗口底、内容末端在标签栏之上
    /// （ShellSystemTabBarRootTests）。悬浮样式本身是 iOS 26 SDK 在上述条件下的系统行为，截图作证据。收起判据改看按钮：收起后
    /// 只剩选中项的小胶囊，其余 Tab 按钮不再可点。
    func testIOS26MinimizeOnScrollDownAndExpandBack() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("标签栏滚动收起只在 iOS 26 起")
        }
        try launch()
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 10))
        XCTAssertFalse(ShellTabBar.isMinimized(app), "冷启动时标签栏是展开的")
        save("ios26-liquid-glass")

        for _ in 0..<3 where !ShellTabBar.isMinimized(app) {
            app.swipeUp()
        }
        XCTAssertTrue(UIWait.until("上滑后标签栏收起", ceiling: 5) { ShellTabBar.isMinimized(app) })
        save("ios26-minimized")

        for _ in 0..<6 where ShellTabBar.isMinimized(app) {
            app.swipeDown()
        }
        // v4（编排定，照 D10-827 口径接受系统行为）：iOS 26.5 上滚动容器带 .refreshable 时，回滑后系统时展开时不展开
        // （实现 r2-2 最小示例：不带下拉刷新 5 个变体次次展开，带下拉刷新 3 个变体 2/4、3/4、0/3），首页必须保留下拉刷新。
        // 只放宽这一点：回滑后可以仍是收起；仍收起时点胶囊（不拖页面）必须能展开，展开后 4 个 Tab 都能点。其余判据不动。
        if ShellTabBar.isMinimized(app) {
            save("ios26-minimized-after-scroll-back")
            ShellTabBar.expand(app)
        }
        XCTAssertTrue(UIWait.until("回滑或点胶囊后标签栏展开", ceiling: 5) { !ShellTabBar.isMinimized(app) })
        for title in ["首页", "AI 助手", "订单", "我的"] {
            XCTAssertTrue(ShellTabBar.button(app, title).isHittable, "展开后 Tab「\(title)」可点")
        }
    }

    /// iOS 16–25 经典样式：标签栏贴底、通栏（D10-831 ⑥：本机 iOS 18.1 运行时补一张截图进证据）。iOS 26 起跳过。
    func testClassicStyleBelowIOS26() throws {
        if #available(iOS 26.0, *) {
            throw XCTSkip("经典样式截图只在 iOS 16–25 运行时出（用本机 iOS 18.1 模拟器单跑本用例）")
        }
        try launch()
        let bar = ShellTabBar.bar(app)
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        XCTAssertEqual(bar.frame.minX, window.minX, accuracy: 1, "经典样式通栏")
        XCTAssertEqual(bar.frame.maxX, window.maxX, accuracy: 1, "经典样式通栏")
        XCTAssertEqual(bar.frame.maxY, window.maxY, accuracy: 1, "经典样式贴底")
        XCTAssertTrue(ShellTabBar.button(app, "首页").isSelected)
        save("ios18-classic")
    }

    private func save(_ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["COULI_SHOT_DIR"], !dir.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }
}
