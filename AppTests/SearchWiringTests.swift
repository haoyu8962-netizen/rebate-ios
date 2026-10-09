import ClientCore
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Privacy
import Router
import Search
import Session
import Update
import XCTest

/// APP-06a App 接线：Search / ProductDetail 路由登记；搜索页随路由真正出栈 leave（作废并取消在途请求，迟到响应不改界面），
/// 只是被详情页盖住不算；配置源转给 ConfigStore。
@MainActor
final class SearchWiringTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "SearchWiringTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        AppStubProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        AppStubProtocol.reset()
    }

    private struct Device: DeviceCredentials {
        var deviceId: String? = "device-fixture"
        var installSecret: String? = "test-only.install.device-a"
    }

    /// `update`：版本检查（默认同步返回 ok）；`shellReady`：外壳是否已出现（页面恢复要等外壳就绪）。
    private func makeSearch(
        update: AppUpdate = UpdateFixtures.makeUpdate(), shellReady: Bool = true
    ) -> (AppSearch, AppRouting) {
        let tokens = MemorySessionTokens()
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = "consented"
        privacyStore.consentedVersion = "1"
        let runner = WithdrawalCleanupRunner(store: privacyStore, registry: withdrawal)
        let network = AppNetwork(
            tokens: tokens, pendingBackend: MemoryPendingKeyBackend(), device: Device(),
            withdrawalRegistry: withdrawal, environmentRegistry: environmentSwitch,
            credentialsReadable: { runner.credentialsReadable }, configuration: AppStubProtocol.configuration()
        )
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: environmentSwitch)
        let privacy = PrivacyController(
            store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1", withdrawalRunner: runner
        )
        let routing = AppRouting(environment: environment, privacy: privacy, update: update)
        let config = AppConfig(
            client: network.client, file: ClientFile(name: suiteName + ".json"),
            environmentRegistry: EnvironmentSwitchCleanerRegistry(cleaners: [])
        )
        network.attach(environment: environment, privacy: privacy, update: update)
        if shellReady {
            routing.shellAppeared()
        }
        let search = AppSearch(
            network: network, config: config, privacy: privacy, routing: routing, restorationDefaults: defaults
        )
        return (search, routing)
    }

    func testRoutesRegistered() {
        XCTAssertNotNil(RouteViewRegistry.builders["Search"])
        XCTAssertNotNil(RouteViewRegistry.builders["ProductDetail"])
    }

    func testPopLeavesAndCancelsButCoveringDoesNot() async throws {
        AppStubProtocol.install { _ in .hold }
        let (search, routing) = makeSearch()
        let router = routing.router
        router.open(RouteRequest(route: "Search", from: .inApp))
        let destination = try XCTUnwrap(router.path.last)
        XCTAssertEqual(destination.route, "Search")
        let page = search.searchPage(destination)
        page.controller.open(query: "milk", platform: nil)
        XCTAssertEqual(page.controller.snapshot.phase, .loading)
        await AppStubProtocol.waitUntilHeld()
        // 被详情页盖住：不是出栈，执行器照常工作。
        page.onOpenProduct("taobao", "tb:milk", nil)
        XCTAssertEqual(router.path.map(\.route), ["Search", "ProductDetail"])
        XCTAssertEqual(page.controller.inFlightCount, 1)
        XCTAssertFalse(AppStubProtocol.wasCancelled)
        // 返回到首页（真正出栈）：作废并取消在途请求，之后不再发。
        router.path.removeAll()
        XCTAssertEqual(page.controller.inFlightCount, 0)
        for _ in 0..<200 where !AppStubProtocol.wasCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(AppStubProtocol.wasCancelled)
        XCTAssertFalse(page.controller.submit("paper"))
    }

    /// R2-01：详情页与搜索页都接上 AppConfig 的平台购买状态（包内 pdd=not_launched）。
    func testPagesReadPlatformPurchaseStatusFromConfig() throws {
        let (search, routing) = makeSearch()
        let router = routing.router
        router.open(RouteRequest(
            route: "ProductDetail", values: ["platform": .string("pdd"), "product_key": .string("pdd:x")],
            from: .inApp
        ))
        let detail = search.productPage(try XCTUnwrap(router.path.last))
        XCTAssertEqual(detail.controller.snapshot.purchase, .notLaunched)
        XCTAssertFalse(detail.controller.buyIntent())
        router.open(RouteRequest(route: "Search", from: .inApp))
        let page = search.searchPage(try XCTUnwrap(router.path.last))
        XCTAssertFalse(page.buyAllowed(platform: "pdd"))
        XCTAssertTrue(page.buyAllowed(platform: "taobao"))
    }

    /// 共性 23：本页面打开的每个路由名都在 routes.json（生成的路由表）里登记。
    func testEveryRouteOpenedBySearchPagesIsInRoutesJson() {
        for route in AppSearchRoutes.all {
            XCTAssertNotNil(Routes.all[route], "\(route) 不在 routes.json")
        }
        XCTAssertEqual(AppSearchRoutes.agentChat, "AgentChat")
    }

    /// R1-02：详情页【问问 AI】经 Router 打开 AgentChat（AI 助手的 Tab 根），不是未登记的路由（不进升级提示）。
    func testAskAIButtonOpensAgentChatThroughRouter() throws {
        let (search, routing) = makeSearch()
        let router = routing.router
        router.open(RouteRequest(
            route: "ProductDetail", values: ["platform": .string("taobao"), "product_key": .string("tb:milk")],
            from: .inApp
        ))
        let destination = try XCTUnwrap(router.path.last)
        XCTAssertEqual(destination.route, "ProductDetail")
        let page = search.productPage(destination)
        XCTAssertEqual(page.controller.snapshot.purchase, .on, "详情执行器接上配置源（包内 taobao=on）")
        page.onAskAI()
        XCTAssertEqual(router.lastDecision?.route, "AgentChat")
        XCTAssertNotEqual(router.lastDecision?.kind, .upgrade)
        XCTAssertEqual(router.tabRoot.route, "AgentChat", "AgentChat 是 Tab 根：切到 AI 助手 Tab")
    }

    private func openSearchThenDetail(_ router: Router) throws -> RouteDestination {
        router.open(RouteRequest(route: "Search", values: ["q": .string("milk")], from: .inApp))
        let search = try XCTUnwrap(router.path.last)
        router.open(RouteRequest(
            route: "ProductDetail", values: ["platform": .string("jd"), "product_key": .string("jd:milk")],
            from: .inApp
        ))
        return search
    }

    /// 共性 20：导航栈里的搜索、详情页连同按路由身份保存的页面状态一起编码；新进程（新 Router）外壳出现后经 Router 重开，
    /// 页面状态改挂到新目的地上；出栈的页面状态丢掉；栈不空时不恢复。
    func testRestorationReplaysSearchStackWithPageStateInNewProcess() async throws {
        let (search, routing) = makeSearch()
        let router = routing.router
        let searchDestination = try openSearchThenDetail(router)
        let pageData = try XCTUnwrap(SearchPageState(input: "draft").encoded())
        search.restoration.save(pageData, for: searchDestination.id)
        for _ in 0..<100 where search.restoration.encoded.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let saved = search.restoration.encoded
        XCTAssertFalse(saved.isEmpty)

        // 前台结束的进程（没进过后台）：下次启动不恢复（启动协调条件满足时随即判定）。
        let (searchForeground, routingForeground) = makeSearch()
        XCTAssertTrue(searchForeground.restoration.launchActionFinished)
        XCTAssertTrue(routingForeground.router.path.isEmpty, "上一个进程不是在后台结束的：不恢复")

        // 进后台后进程被结束 →「新进程」：全新的 Router 与 AppSearch，只拿到持久化的编码数据。
        router.path.removeAll()
        let reopened = try openSearchThenDetail(router)
        search.restoration.save(pageData, for: reopened.id)
        search.restoration.sceneEnteredBackground()
        XCTAssertEqual(defaults.data(forKey: SearchRouteRestoration.dataKey), search.restoration.encoded)
        let (search2, routing2) = makeSearch()
        let router2 = routing2.router
        XCTAssertEqual(router2.path.map(\.route), ["Search", "ProductDetail"], "检查已有结果、外壳就绪：恢复")
        XCTAssertEqual(router2.path.map(\.readonly), [false, false])
        XCTAssertEqual(router2.path[0].params["q"]?.stringValue, "milk")
        XCTAssertEqual(router2.path[1].params["product_key"]?.stringValue, "jd:milk")
        XCTAssertNotEqual(router2.path[0].id, reopened.id)
        XCTAssertEqual(search2.restoration.pageState(for: router2.path[0].id), pageData)
        // 恢复出来的搜索页配置拿到的就是这份状态。
        XCTAssertEqual(search2.searchPage(router2.path[0]).restored?.input, "draft")
        search2.restoration.launchSettled(update: .ok)
        routing2.launchConditionsChanged()
        XCTAssertEqual(router2.path.count, 2, "只恢复一次")

        // 出栈即结束：页面状态丢掉，保存内容随之更新。
        let poppedId = router2.path[0].id
        router2.path.removeAll()
        for _ in 0..<100 where search2.restoration.pageState(for: poppedId) != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(search2.restoration.pageState(for: poppedId))
        XCTAssertTrue(search2.restoration.encoded.isEmpty)
        XCTAssertNil(defaults.data(forKey: SearchRouteRestoration.dataKey), "栈里没有搜索页：删除保存内容")

        // 栈不空（例如外壳出现前已经打开了页面）时不恢复。
        seedSaved(saved)
        let (search3, routing3) = makeSearch(shellReady: false)
        XCTAssertFalse(search3.restoration.launchActionFinished, "外壳还没就绪：等")
        routing3.router.open(RouteRequest(route: "Search", from: .inApp))
        routing3.shellAppeared()
        XCTAssertTrue(search3.restoration.launchActionFinished)
        XCTAssertEqual(routing3.router.path.count, 1)
    }

    /// R3F-03：进后台时先调各页面登记的「立即保存最新状态」，再写入持久化（不等页面 0.2 秒的延迟保存）。
    func testBackgroundFlushesLatestPageStateBeforeStoring() throws {
        let (search, routing) = makeSearch()
        let router = routing.router
        router.open(RouteRequest(route: "Search", values: ["q": .string("milk")], from: .inApp))
        let destination = try XCTUnwrap(router.path.last)
        _ = search.searchPage(destination)
        let restoration = search.restoration
        XCTAssertTrue(restoration.hasFlush(for: destination.id), "搜索页登记了立即保存入口")
        let older = try XCTUnwrap(SearchPageState(input: "milk", scrollAnchor: 2, scrollOffset: -40).encoded())
        let latest = try XCTUnwrap(SearchPageState(input: "milk", scrollAnchor: 2, scrollOffset: -90).encoded())
        restoration.save(older, for: destination.id)
        // 页面内存里已是最新偏移、延迟保存还没执行：进后台时由登记的入口同步交出。
        restoration.registerFlush(for: destination.id) { [weak restoration] in
            restoration?.save(latest, for: destination.id)
        }
        restoration.sceneEnteredBackground()
        let stored = try XCTUnwrap(defaults.data(forKey: SearchRouteRestoration.dataKey))
        let saved = try JSONDecoder().decode(SearchRouteRestoration.Saved.self, from: stored)
        XCTAssertEqual(saved.entries.first?.page, latest, "写入的是最新状态")
    }

    func testConfigSourceForwardsToStore() {
        let client = ApiClient(
            identity: ClientIdentity(platform: "ios", appVersion: "1.0.0", build: "1", channel: "c"),
            context: {
                NetworkContext(
                    privacy: PrivacyRaw.full, environmentSettled: false, credentialsReadable: true,
                    update: UpdateRaw.supported, apiBaseURL: nil
                )
            },
            tokens: MemorySessionTokens(),
            pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 })
        )
        let config = AppConfig(
            client: client, file: ClientFile(name: suiteName + "-2.json"),
            environmentRegistry: EnvironmentSwitchCleanerRegistry(cleaners: [])
        )
        XCTAssertNotNil(config.searchStatusLayers()["bundled"])
        // R2-01：平台购买状态逐个平台回落到包内配置（包内 pdd=not_launched、taobao=on），没有的平台为 nil。
        XCTAssertEqual(config.purchaseStatus(platform: "pdd"), "not_launched")
        XCTAssertEqual(config.purchaseStatus(platform: "taobao"), "on")
        XCTAssertNil(config.purchaseStatus(platform: "vip"))
        XCTAssertEqual(config.issuedFetchId, 0)
        config.requestFresh()
        XCTAssertEqual(config.issuedFetchId, 0, "环境闸门通过（冷启动）之前不拉配置")
    }
}

/// R2-03：页面恢复接在启动协调上（同文件扩展，共用 makeSearch 与 defaults）。
extension SearchWiringTests {
    /// 上一个进程在后台结束时留下的保存内容（搜索 milk + 京东详情）。
    private func savedStack() throws -> (data: Data, page: Data) {
        let page = try XCTUnwrap(SearchPageState(input: "draft", scrollAnchor: 3).encoded())
        let saved = SearchRouteRestoration.Saved(entries: [
            .init(route: "Search", params: ["q": "milk"], page: page),
            .init(route: "ProductDetail", params: ["platform": "jd", "product_key": "jd:milk"], page: nil),
        ])
        return (try JSONEncoder().encode(saved), page)
    }

    private func seedSaved(_ data: Data) {
        defaults.set(data, forKey: SearchRouteRestoration.dataKey)
        defaults.set(true, forKey: SearchRouteRestoration.backgroundKey)
    }

    /// 本轮版本检查还在进行：不恢复（不按 App 内操作跳过等待），并安排 5 秒超时协调；等待期间进后台不丢保存内容；
    /// 检查返回 ok 后才恢复，页面状态交给新目的地。
    func testRestorationWaitsForSlowUpdateCheckThenRestores() throws {
        let (data, page) = try savedStack()
        seedSaved(data)
        let checker = StubUpdateChecker(nil)
        let update = UpdateFixtures.makeUpdate(checker: checker)
        let (search, routing) = makeSearch(update: update)
        XCTAssertEqual(checker.calls, 1)
        XCTAssertTrue(routing.router.path.isEmpty, "检查中：自动恢复等待")
        XCTAssertTrue(routing.hasWaitingLaunchAutoAction)
        let started = try XCTUnwrap(update.checkStartedAt)
        XCTAssertEqual(
            routing.scheduledLaunchRetryAt,
            max(started, routing.router.launchGatesOpenedAt ?? started) + LaunchQueue.updateWaitMillis,
            "最长等 5 秒"
        )
        // 等待期间保留页面状态：进后台（可能再被结束）时保存内容与标记都在。
        search.restoration.sceneEnteredBackground()
        XCTAssertEqual(defaults.data(forKey: SearchRouteRestoration.dataKey), data)
        XCTAssertTrue(defaults.bool(forKey: SearchRouteRestoration.backgroundKey))

        checker.deliver(.success(UpdateFixtures.ok))
        XCTAssertEqual(routing.router.path.map(\.route), ["Search", "ProductDetail"], "检查有结果后恢复")
        XCTAssertEqual(routing.router.lastDecision?.kind, .open)
        XCTAssertEqual(search.restoration.pageState(for: routing.router.path[0].id), page)
        XCTAssertFalse(routing.hasWaitingLaunchAutoAction)
        XCTAssertNil(routing.scheduledLaunchRetryAt)
    }

    /// 慢速检查最终返回 below_min：进强更页，不恢复任何业务页面。
    func testRestorationSlowCheckEndingBelowMinDoesNotRestore() throws {
        seedSaved(try savedStack().data)
        let checker = StubUpdateChecker(nil)
        let (search, routing) = makeSearch(update: UpdateFixtures.makeUpdate(checker: checker))
        XCTAssertTrue(routing.router.path.isEmpty)
        checker.deliver(.success(UpdateFixtures.force))
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate], "只有强更页")
        XCTAssertTrue(search.restoration.launchActionFinished)
        XCTAssertFalse(routing.hasWaitingLaunchAutoAction)
        // 之后检查解除（例如回前台复查）也不补恢复。
        routing.launchConditionsChanged()
        XCTAssertFalse(routing.router.path.contains { $0.route == "Search" || $0.route == "ProductDetail" })
    }

    /// 本机记着 below_min（上次检查）：冷启动直接按 below_min，不恢复。
    func testRestorationWithKnownBelowMinDoesNotRestore() throws {
        seedSaved(try savedStack().data)
        let store = MemoryUpdateStore(record: UpdateRecord(lastResult: UpdateFixtures.force, lastSuccessAt: 1))
        let (_, routing) = makeSearch(update: UpdateFixtures.makeUpdate(checker: StubUpdateChecker(nil), store: store))
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate])
    }

    /// 检查一直没有结果：等满 5 秒按 unknown，只读恢复（搜索、详情都在只读清单里）。
    func testRestorationTimesOutAfterFiveSecondsAsUnknownReadonly() async throws {
        seedSaved(try savedStack().data)
        let checker = StubUpdateChecker(nil)
        let (_, routing) = makeSearch(update: UpdateFixtures.makeUpdate(checker: checker))
        try await Task.sleep(for: .milliseconds(2000))
        XCTAssertTrue(routing.router.path.isEmpty, "不到 5 秒仍在等")
        for _ in 0..<80 where routing.router.path.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(checker.calls, 1, "检查一直没有回调")
        XCTAssertEqual(routing.router.path.map(\.route), ["Search", "ProductDetail"], "第 5 秒按 unknown 恢复")
        XCTAssertEqual(routing.router.path.map(\.readonly), [true, true], "unknown：只读打开")
    }
}
