@testable import Couli
import CouliNetwork
import Foundation
@testable import OrderCore
@testable import Orders
import Router
import Search
import Session
import SwiftUI
import Trade
import XCTest

/// FU-IOS-0713 必测 2（RW-05）：商品详情 / 搜索页的待跟单执行器参与统一身份确认。全部经生产接线：
/// - 页面由 `AppSearch.productPage / searchPage`（真实页面工厂，内部接 `AppTrade.makePurchase` 与 `AppOrders.pendingSlot`）建；
/// - 订单与搜索的连接走 `AppOrders.connect(search:)`（接口约定：CouliApp.makeOrders 的接线下沉，App 一行转发）；
/// - 外跳完成走购买控制器上由 pendingSlot 接好的 `onJumpedOut` / `jumpOrigin`（购买完成回调）；
/// - 进后台 / 回前台走 `AppScenePhases.apply`（接口约定：CouliApp 场景接线下沉，App 一行转发），测试不复制调用顺序；
/// - 会话核对走 `AppOrders.checkSession`（会话版本变化、页面打开的同一入口）。
/// 假服务按请求令牌回答不同的卡（A：L-A，B：L-B），断言显示的是对的那张；负向断言在 `PendingTrackService.whenIdle()` 之后取值。
@MainActor
final class FollowupIos0713PendingTrackTests: XCTestCase {
    private let suites = FreshSuites()
    private let base = "FollowupIos0713PendingTrackTests"
    static let routes = ["ProductDetail", "Search"]

    override func tearDown() {
        suites.removeAll()
        AppStubProtocol.reset()
        super.tearDown()
    }

    /// 一组真实接线：订单组合 + AppTrade + AppSearch（页面工厂）+ 连接。
    struct Wired {
        let fixture: OrdersAppFixture
        let search: AppSearch
        let trade: AppTrade

        var orders: AppOrders {
            fixture.orders
        }

        var targets: AppScenePhases.Targets {
            AppScenePhases.Targets(search: search, orders: fixture.orders)
        }
    }

    /// 一个发起购买的页面（真实页面工厂建出的购买控制器）。
    struct Page {
        let destination: RouteDestination
        let purchase: OpenPurchaseController
        let view: AnyView?
    }

    static func tracks(_ link: String) -> AppStubProtocol.Reply {
        let body = "{\"items\":[{\"link_id\":\"\(link)\",\"attempt_id\":\"a1\",\"platform\":\"taobao\","
            + "\"jumped_at\":\"2026-10-09T10:00:00+08:00\",\"show_claim_entry\":true,\"dismissed\":false}]}"
        return .json(status: 200, body: "{\"code\":0,\"msg\":\"\",\"data\":\(body),\"trace_id\":\"t\"}")
    }

    /// 本请求带的是 B 的令牌。
    static func isB(_ request: AppStubProtocol.Recorded) -> Bool {
        request.header("Authorization")?.hasSuffix("at-b") == true
    }

    var fetches: [AppStubProtocol.Recorded] {
        AppStubProtocol.requests.filter { $0.path == "/v1/orders/pending-tracks" }
    }

    /// 每轮一组全新的真实接线；待跟单按令牌回答，`onFetch` 在服务端收到待跟单请求时同步调用（故障布设点）。
    func wire(_ tag: String, onFetch: (@Sendable () -> Void)? = nil) -> Wired {
        AppStubProtocol.reset()
        let (name, defaults) = suites.make(base, tag)
        let fixture = OrdersAppFixture.make(suiteName: name, defaults: defaults)
        AppStubProtocol.install { request in
            guard request.path == "/v1/orders/pending-tracks" else { return .hold }
            onFetch?()
            return Self.tracks(Self.isB(request) ? "L-B" : "L-A")
        }
        let trade = AppTrade(
            network: fixture.network, config: fixture.config, privacy: fixture.privacy, routing: fixture.routing,
            login: fixture.login, credentialsReadable: { fixture.runner.credentialsReadable }, track: { _, _ in }
        )
        let search = AppSearch(
            network: fixture.network, config: fixture.config, privacy: fixture.privacy, routing: fixture.routing,
            trade: trade, restorationDefaults: defaults, credentialsReadable: { fixture.runner.credentialsReadable }
        )
        fixture.orders.connect(search: search)
        return Wired(fixture: fixture, search: search, trade: trade)
    }

    /// 经 Router 打开页面并由真实页面工厂建页（商品详情 / 搜索页）。
    func open(_ wired: Wired, _ route: String) throws -> Page {
        try build(wired, navigate(wired, route))
    }

    /// 只经 Router 打开（还没建页）。
    func navigate(_ wired: Wired, _ route: String) throws -> RouteDestination {
        let router = wired.fixture.routing.router
        let values: [String: JSONValue] = route == "ProductDetail"
            ? ["platform": .string("taobao"), "product_key": .string("tb:milk")] : [:]
        router.open(RouteRequest(route: route, values: values, from: .inApp))
        return try XCTUnwrap(router.path.last, "\(route) 没有打开")
    }

    /// 真实页面工厂建页。
    func build(_ wired: Wired, _ destination: RouteDestination) throws -> Page {
        if destination.route == "ProductDetail" {
            let page = wired.search.productPage(destination)
            return Page(destination: destination, purchase: try XCTUnwrap(page.purchase), view: page.pendingTrack)
        }
        let page = wired.search.searchPage(destination)
        return Page(destination: destination, purchase: try XCTUnwrap(page.purchaseController), view: page.pendingTrack)
    }

    /// 进后台后外跳完成（购买控制器上由生产接好的完成回调，带发起时固定的来源）。
    func jumpOut(_ wired: Wired, _ page: Page) {
        AppScenePhases.apply(.background, wired.targets)
        page.purchase.onJumpedOut?("taobao", page.purchase.jumpOrigin?())
    }

    func service(_ wired: Wired, _ page: Page) throws -> PendingTrackService {
        try XCTUnwrap(wired.orders.pendingService(page.destination.id), "发起页没有接待跟单卡")
    }

    func waitCards(_ wired: Wired, _ page: Page, _ expected: [String], _ tag: String) async throws {
        await waitUntil("\(tag)：没有出卡 \(expected)") {
            wired.orders.pendingService(page.destination.id)?.state.cards.map(\.linkId) == expected
        }
        let current = try service(wired, page)
        await current.whenIdle()
        XCTAssertEqual(current.state.cards.map(\.linkId), expected, "\(tag)：显示的卡")
    }

    // MARK: - 构造时身份未知

    /// 真实页面工厂建商品详情 / 搜索页时身份读取暂时失败（按读取位置遍历）：之后外跳、回前台 → 执行器换上已确认身份并拉取，显示 A 的卡。
    func testSlotBuiltWhileIdentityUnknownFetchesAfterJumpAndForeground() async throws {
        for route in Self.routes {
            try await forEachReadPosition("\(route) 构造") { fault, nth in
                let tag = "\(route) 构造/\(fault.rawValue)#\(nth)"
                let wired = wire(tag)
                let window = FaultWindow(wired.fixture.store)
                window.begin(fault, nth)
                let page = try open(wired, route)
                let used = window.end()
                XCTAssertNotNil(page.view, "\(tag)：页面接上了待跟单卡")
                jumpOut(wired, page)
                AppScenePhases.apply(.active, wired.targets)
                try await waitCards(wired, page, ["L-A"], tag)
                return used
            }
        }
    }

    // MARK: - 换代重绑

    /// 底层会话换成 B 后的会话核对期间身份读取暂时失败（按读取位置遍历，含换代通知里执行器重绑）；之后外跳、回前台 → 按 B 拉取、显示
    /// B 的卡，不带 A 的令牌拉取。
    func testRebindAfterSessionChangeSurvivesUnknownReadAndFetchesForNewSession() async throws {
        for route in Self.routes {
            try await forEachReadPosition("\(route) 换代") { fault, nth in
                let tag = "\(route) 换代/\(fault.rawValue)#\(nth)"
                let wired = wire(tag)
                let page = try open(wired, route)
                wired.fixture.network.client.signOut()
                try wired.fixture.tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
                let window = FaultWindow(wired.fixture.store)
                window.begin(fault, nth)
                wired.orders.checkSession()
                let used = window.end()
                jumpOut(wired, page)
                AppScenePhases.apply(.active, wired.targets)
                try await waitCards(wired, page, ["L-B"], tag)
                XCTAssertTrue(fetches.allSatisfy(Self.isB), "\(tag)：换代后只带 B 的令牌拉取")
                return used
            }
        }
    }

    /// 调用方快照定向验证（RW-05「换代重绑用调用方已有快照」）：底层会话换成 B，会话核对的第一次读取就是调用方快照（`checkSession`
    /// 开头取快照）；之后的读取（换代通知里执行器的独立读取等）读失败或读到另一会话 C → 执行器仍按调用方的 B 快照重绑（已确认、账号 B）。
    func testRebindUsesCallerSnapshot() throws {
        for route in Self.routes {
            for other in ["失败", "另一会话"] {
                let tag = "\(route) 调用方快照/\(other)"
                let wired = wire(tag)
                let page = try open(wired, route)
                let store = wired.fixture.store
                wired.fixture.network.client.signOut()
                try wired.fixture.tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
                let sessionC = MemorySessionTokens(access: "at-c", refresh: "rt-c", scope: "full", account: "user-c")
                if other == "失败" {
                    store.failReads(fromNth: 2)
                } else {
                    store.redirect(fromNth: 2, to: sessionC)
                }
                wired.orders.checkSession()
                store.disarm()
                let rebound = try service(wired, page).owner
                XCTAssertEqual(rebound.account, "user-b", "\(tag)：换代重绑用调用方快照（B），不另读")
                XCTAssertTrue(rebound.identityKnown, "\(tag)：重绑的身份已确认")
            }
        }
    }

    /// 构造用调用方快照（T-06 第 3 版）：页面已经过 Router 打开、已登录 A；页面工厂建页时，第 1 次读取（调用方取得的 A 快照）照常，
    /// 第 n 次起（n ≥ 2，遍历到工厂实际发生的读取数为止）读取失败或改读 B → 在任何身份恢复、回前台之前（故障仍在），执行器固定身份
    /// 是已确认的 A，网络归属也是 A。只读一次的实现自然满足。
    func testBuildUsesCallerSnapshot() throws {
        for route in Self.routes {
            for other in ["失败", "另一会话"] {
                var nth = 2
                while true {
                    let tag = "\(route) 构造快照/\(other)#\(nth)"
                    let wired = wire(tag)
                    let destination = try navigate(wired, route)
                    let store = wired.fixture.store
                    let base = store.reads
                    let sessionB = MemorySessionTokens(
                        access: "at-b",
                        refresh: "rt-b",
                        scope: "full",
                        account: "user-b"
                    )
                    if other == "失败" {
                        store.failReads(fromNth: nth)
                    } else {
                        store.redirect(fromNth: nth, to: sessionB)
                    }
                    let page = try build(wired, destination)
                    let used = store.reads - base
                    let owner = try service(wired, page).owner
                    store.disarm()
                    XCTAssertGreaterThan(used, 0, "\(tag)：前提：建页读取了身份")
                    XCTAssertEqual(owner.account, "user-a", "\(tag)：固定身份来自调用方的 A 快照")
                    XCTAssertTrue(owner.identityKnown, "\(tag)：固定身份已确认")
                    XCTAssertEqual(owner.request?.account, "user-a", "\(tag)：请求归属来自 A 快照")
                    if used < nth || nth >= 40 {
                        break
                    }
                    nth += 1
                }
            }
        }
    }

    // MARK: - 回前台时身份未知

    /// 已外跳、等回前台拉卡；回前台期间身份读取暂时失败（按读取位置遍历）：待拉取任务保留，下一次会话核对时补取，显示 A 的卡。
    func testForegroundWhileIdentityUnknownKeepsPendingFetchUntilConfirmation() async throws {
        for route in Self.routes {
            try await forEachReadPosition("\(route) 回前台") { fault, nth in
                let tag = "\(route) 回前台/\(fault.rawValue)#\(nth)"
                let wired = wire(tag)
                let page = try open(wired, route)
                jumpOut(wired, page)
                let window = FaultWindow(wired.fixture.store)
                window.begin(fault, nth)
                AppScenePhases.apply(.active, wired.targets)
                let used = window.end()
                wired.orders.checkSession()
                try await waitCards(wired, page, ["L-A"], tag)
                return used
            }
        }
    }

    // MARK: - 拉取响应核对时身份未知（同账号）

    /// 回前台后的第一次待跟单拉取：服务端收到请求时布设故障（响应核对期间单次 / 持续失败，按读取位置遍历），等执行器结算后撤掉；
    /// 之后只经会话核对 → 自动采用或补取，显示 A 的卡。
    func testFetchResponseWhileIdentityUnknownIsAdoptedOrRefetchedOnConfirmation() async throws {
        for route in Self.routes {
            try await forEachReadPosition("\(route) 拉取响应") { fault, nth in
                let tag = "\(route) 拉取响应/\(fault.rawValue)#\(nth)"
                let arm = ArmOnce()
                let box = StoreBox()
                let wired = wire(tag) { arm.fire { box.store.map { fault.arm($0, nth) }; return box.store?.reads ?? 0 }
                }
                box.store = wired.fixture.store
                let page = try open(wired, route)
                jumpOut(wired, page)
                AppScenePhases.apply(.active, wired.targets)
                await waitUntil("\(tag)：拉取没有到达服务端") { arm.fired }
                try await service(wired, page).whenIdle()
                let used = wired.fixture.store.reads - arm.base
                wired.fixture.store.disarm()
                wired.orders.checkSession()
                try await waitCards(wired, page, ["L-A"], tag)
                return used
            }
        }
    }

    /// 对照（确认换代才丢弃）：A 外跳后回前台时身份持续未知；随后确认换成 B → A 的待拉取丢弃：执行器空闲后没有带 A 令牌的拉取、不显示
    /// A 的卡。
    func testPendingFetchOfOldSessionDroppedOnConfirmedChange() async throws {
        for route in Self.routes {
            let tag = "\(route) 换代对照"
            let wired = wire(tag)
            let page = try open(wired, route)
            jumpOut(wired, page)
            wired.fixture.store.failReads(fromNth: 1)
            AppScenePhases.apply(.active, wired.targets)
            wired.fixture.store.disarm()
            wired.fixture.network.client.signOut()
            try wired.fixture.tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
            wired.orders.checkSession()
            let current = try service(wired, page)
            await current.whenIdle()
            XCTAssertTrue(fetches.allSatisfy(Self.isB), "\(tag)：不带 A 的令牌拉取")
            XCTAssertFalse(current.state.cards.contains { $0.linkId == "L-A" }, "\(tag)：不显示 A 的卡")
        }
    }
}

/// 只布设一次的故障（服务端线程调用）：记下布设时的读取计数。
final class ArmOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var at = 0

    var fired: Bool {
        lock.withLock { done }
    }

    var base: Int {
        lock.withLock { at }
    }

    /// `body` 布设故障并返回布设前的读取计数；只执行第一次。
    func fire(_ body: () -> Int) {
        lock.withLock {
            guard !done else { return }
            done = true
            at = body()
        }
    }
}

/// 服务端线程可见的令牌存储引用。
final class StoreBox: @unchecked Sendable {
    var store: CountingSessionTokens?
}
