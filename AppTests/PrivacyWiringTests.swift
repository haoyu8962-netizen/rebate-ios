@testable import Couli
import DesignSystem
import Privacy
import Router
import SwiftUI
import XCTest

/// App 侧隐私闸门接线（APP-02b）：结论映射到 Router、弹窗流程、外壳文字来源、系统启动屏底色。
@MainActor
final class PrivacyWiringTests: XCTestCase {
    func testControllerFlowAndRouterMapping() {
        let store = MemoryPrivacyStore()
        let controller = PrivacyController(store: store, clock: { 1000 }, bundledPolicyVersion: "1")
        var changes = 0
        controller.onChange = { changes += 1 }

        XCTAssertEqual(controller.routerPrivacy, .notDecided)
        XCTAssertEqual(controller.state.promptStage, .first)

        controller.disagree()
        XCTAssertEqual(controller.state.promptStage, .second)
        controller.stillDisagree()
        XCTAssertEqual(controller.routerPrivacy, .basicMode)
        XCTAssertFalse(controller.isPrompting)

        controller.requestFullFunction()
        XCTAssertEqual(controller.routerPrivacy, .basicMode, "弹窗期间仍在基本模式里浏览")
        XCTAssertTrue(controller.isPrompting)
        controller.agree()
        XCTAssertEqual(controller.routerPrivacy, .consented)
        XCTAssertEqual(store.consentedVersion, "1")
        XCTAssertEqual(store.consentedAtMillis, 1000)
        XCTAssertEqual(changes, 4)

        controller.withdraw()
        XCTAssertEqual(controller.routerPrivacy, .basicMode)
        XCTAssertNil(store.consentedVersion)
    }

    func testUpgradeRepromptMapsToUndecidedForRouter() {
        let store = MemoryPrivacyStore()
        store.decisionRaw = "consented"
        store.consentedVersion = "1"
        let controller = PrivacyController(store: store, clock: { 0 }, bundledPolicyVersion: "2")
        XCTAssertEqual(controller.routerPrivacy, .notDecided, "旧版本同意不作数，冷启动先过首启闸门")
        XCTAssertTrue(controller.isPrompting)
    }

    func testTabsUseShellDraftTextsAndRegistryRoutes() {
        XCTAssertEqual(ShellTab.allCases.map(\.item.title), ["首页", "AI 助手", "订单", "我的"])
        XCTAssertEqual(ShellTab.allCases.map(\.route), ["Home", "AgentChat", "OrderList", "Me"])
        XCTAssertEqual(ShellTab.allCases.filter(\.reachableInBasicMode), [.home])
        for tab in ShellTab.allCases {
            XCTAssertNotNil(AppRouting.routeTable[tab.route], tab.route)
        }
    }

    func testAgreementLinksMatchRouteEnum() {
        XCTAssertEqual(AgreementLink.allCases.compactMap(\.agreementType), ["privacy", "agreement", "sdk_list"])
    }

    func testLaunchScreenColorMatchesCanvasToken() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary?["UILaunchScreen"] as? [String: Any])
        XCTAssertEqual(info["UIColorName"] as? String, "LaunchBackground")
        let launch = try XCTUnwrap(UIColor(named: "LaunchBackground", in: .main, compatibleWith: nil))
        let canvas = UIColor(CouliColor.backgroundCanvas)
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
        var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
        launch.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
        canvas.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
        XCTAssertEqual(lr, cr, accuracy: 0.01)
        XCTAssertEqual(lg, cg, accuracy: 0.01)
        XCTAssertEqual(lb, cb, accuracy: 0.01)
    }
}

/// AppRouting 的隐私接线（APP-02b 评审，三端统一）：Tab 过守卫、同意 = 前置完成、拒绝丢弃待办、
/// 进入基本模式清空导航栈、运行中停在首启弹窗时丢弃深链。
@MainActor
final class AppRoutingPrivacyTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "AppRoutingPrivacyTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        UserDefaultsPendingBackend().delete()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        UserDefaultsPendingBackend().delete()
    }

    private func makeRouting(_ store: MemoryPrivacyStore) -> AppRouting {
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: .init(cleaners: []))
        let privacy = PrivacyController(store: store, clock: { 1 }, bundledPolicyVersion: "1")
        return AppRouting(environment: environment, privacy: privacy)
    }

    private func basicStore() -> MemoryPrivacyStore {
        let store = MemoryPrivacyStore()
        store.decisionRaw = "basic_mode"
        store.basicMode = true
        return store
    }

    func testBasicModeRestrictedTabPromptsAndRefusalDropsPending() {
        let routing = makeRouting(basicStore())
        XCTAssertNil(routing.selectTab(.me), "基本模式点「我的」不切换")
        XCTAssertTrue(routing.privacy.isPrompting, "守卫要求补同意 → 弹首启弹窗")
        XCTAssertNotNil(UserDefaultsPendingBackend().read())

        routing.privacy.disagree()
        XCTAssertNil(UserDefaultsPendingBackend().read(), "再次不同意：丢弃本次登记的待办")
        routing.privacy.stillDisagree()
        routing.privacy.requestFullFunction()
        routing.privacy.agree()
        XCTAssertTrue(routing.router.path.isEmpty, "之后同意不自动打开被拒的目标")
    }

    func testBasicModeHomeTabIsReadonly() {
        let routing = makeRouting(basicStore())
        XCTAssertEqual(routing.selectTab(.home), true)
    }

    /// 外壳重建（场景恢复、外壳视图重新出现、启动条件重新协调）不重新判定 Tab，不覆盖已保存的只读标记：
    /// Tab 状态只存在 Router.tabRoot（App 的 @StateObject），外壳视图无自有 Tab 状态；只有用户重新点击 Tab 才重新判定。
    func testShellRebuildKeepsSavedTabReadonly() {
        let routing = makeRouting(basicStore())
        XCTAssertEqual(routing.selectTab(.home), true)
        let saved = routing.router.tabRoot
        XCTAssertTrue(saved.readonly)

        routing.shellAppeared()
        routing.shellAppeared()
        routing.launchConditionsChanged()
        routing.sceneEnteredBackground()
        routing.shellAppeared()
        routing.launchConditionsChanged()
        XCTAssertEqual(routing.router.tabRoot, saved, "重建 / 恢复不改写 Tab 根与只读标记")
        XCTAssertEqual(ShellTab(rootRoute: routing.router.tabRoot.route), .home)
    }

    func testAgreeContinuesPendingPrerequisite() {
        let routing = makeRouting(basicStore())
        XCTAssertNil(routing.selectTab(.orders))
        routing.privacy.agree()
        XCTAssertEqual(routing.router.path.map(\.route), ["Login"], "同意 = 完成前置，游客继续去登录")
    }

    func testWithdrawClearsNavigationStack() {
        let store = MemoryPrivacyStore()
        store.decisionRaw = "consented"
        store.consentedVersion = "1"
        let routing = makeRouting(store)
        routing.router.open(RouteRequest(route: "Search", from: .inApp))
        XCTAssertFalse(routing.router.path.isEmpty)
        routing.privacy.withdraw()
        XCTAssertTrue(routing.router.path.isEmpty)
    }

    func testDeepLinkWhileRunningOnFirstLaunchDialogIsDropped() throws {
        let routing = makeRouting(MemoryPrivacyStore())
        routing.sceneEnteredBackground()
        let url = try XCTUnwrap(URL(string: "couli-debug://r/Search?q=a"))
        routing.handle(url: url)
        XCTAssertFalse(routing.router.hasPendingLaunchIntent, "运行中停在首启弹窗：丢弃新深链")
    }

    /// R1-01：外壳已显示（shellReady）时基本模式点受限 Tab → 弹窗期间的启动协调不删待办 → 同意后继续去登录。
    func testRestrictedTabAfterShellAppearedKeepsPendingThroughDialog() {
        let routing = makeRouting(basicStore())
        routing.shellAppeared()
        XCTAssertNil(routing.selectTab(.orders))
        XCTAssertTrue(routing.privacy.isPrompting)
        XCTAssertNotNil(UserDefaultsPendingBackend().read(), "弹窗打开触发的启动协调不得删除待办")
        routing.launchConditionsChanged()
        XCTAssertNotNil(UserDefaultsPendingBackend().read())

        routing.privacy.agree()
        XCTAssertEqual(routing.router.path.map(\.route), ["Login"], "同意 = 完成前置，游客继续去登录")
        XCTAssertNotNil(UserDefaultsPendingBackend().read(), "登录前保留待办")
    }

    func testRestrictedTabAfterShellAppearedRefusalDropsPending() {
        let routing = makeRouting(basicStore())
        routing.shellAppeared()
        XCTAssertNil(routing.selectTab(.me))
        XCTAssertNotNil(UserDefaultsPendingBackend().read())
        routing.privacy.disagree()
        XCTAssertNil(UserDefaultsPendingBackend().read(), "拒绝：丢弃本次待办")
    }

    /// 进程重启：内存标记不在，基本模式下的待办按 reject 删除。
    func testRestartInBasicModeDropsPending() {
        let first = makeRouting(basicStore())
        first.shellAppeared()
        _ = first.selectTab(.orders)
        XCTAssertNotNil(UserDefaultsPendingBackend().read())
        let second = makeRouting(basicStore())
        second.shellAppeared()
        XCTAssertNil(UserDefaultsPendingBackend().read())
    }

    /// R1-03：冷启动深链 A 排队 → 进后台 → 深链 B 在弹窗期间到达被丢弃 → A 仍在，同意后打开 A。
    func testNewDeepLinkDuringDialogKeepsColdStartIntent() throws {
        let routing = makeRouting(MemoryPrivacyStore())
        routing.handle(url: try XCTUnwrap(URL(string: "couli-debug://r/Search?q=a")))
        XCTAssertTrue(routing.router.hasPendingLaunchIntent, "冷启动带来的意图排队等闸门")
        routing.sceneEnteredBackground()
        routing.handle(url: try XCTUnwrap(URL(string: "couli-debug://r/ProductDetail?product_id=p1")))
        XCTAssertTrue(routing.router.hasPendingLaunchIntent, "丢弃的只是新深链")

        routing.privacy.agree()
        routing.shellAppeared()
        XCTAssertEqual(routing.router.path.map(\.route), ["Search"])
        XCTAssertEqual(routing.router.path.first?.params["q"], .string("a"))
    }

    /// R1-04：首启弹窗期间的热推送丢弃，不入队；冷启动推送照常排队。
    func testHotPushDuringDialogIsDroppedColdPushQueued() {
        let routing = makeRouting(MemoryPrivacyStore())
        let landing = PushLanding { _ in .found(route: "Search", params: [:]) }
        XCTAssertNil(routing.handlePush(messageId: "m1", coldStart: false, using: landing))
        XCTAssertFalse(routing.router.hasPendingLaunchIntent, "热推送不入队")

        routing.handlePush(messageId: "m2", coldStart: true, using: landing)
        XCTAssertTrue(routing.router.hasPendingLaunchIntent, "冷启动推送等隐私结论")
    }

    /// R1-05：Router 打开 Tab 根路由时外壳的 Tab 选择跟随 Router。
    func testTabSelectionFollowsRouter() {
        let store = MemoryPrivacyStore()
        store.decisionRaw = "consented"
        store.consentedVersion = "1"
        let routing = makeRouting(store)
        XCTAssertEqual(routing.selectTab(.agent), false)
        XCTAssertEqual(ShellTab(rootRoute: routing.router.tabRoot.route), .agent)
        routing.router.open(RouteRequest(route: "Home", from: .deeplink))
        XCTAssertEqual(ShellTab(rootRoute: routing.router.tabRoot.route), .home)
        routing.privacy.withdraw()
        XCTAssertEqual(routing.router.tabRoot.route, "Home")
    }
}
