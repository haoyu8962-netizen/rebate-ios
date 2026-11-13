import Foundation
import Generated
import XCTest
@testable import Router

/// FU-IOS-FORCEUPDATE-DELETE-ENTRY（编排裁定 D10-1562）：强更页【注销账号】→ DeleteAccount。
/// DeleteAccount 的 since.ios 仍为 null（未发布，N-14 / rule-gaps G02）：从强更页次要入口请求时，守卫给升级提示
/// （kind .upgrade、route nil、reason unknown_route），Router 在强更页上面推入内置升级提示页，强更页留在栈底；
/// 不再返回 forceUpdate 让已登录用户点了静默无效。
///
/// 过渡口径（D10-1562）：N-14 上线（iOS DeleteAccount 发布、since.ios 有值）后，本文件里 DeleteAccount 的用例要改成
/// 放行进 DeleteAccount（受限会话 / 已登录 open、reason force_update_exception；游客 requireLogin），升级提示过渡去掉。
@MainActor
final class RouterForceUpdateDeleteEntryTests: XCTestCase {
    private var guardState = GuardState(
        privacyState: .consented,
        updateState: .belowMin,
        sessionState: .loggedIn,
        environmentSettled: true,
        appVersion: "1.0.0",
        isDebugBuild: false
    )
    private var now: Int64 = 1_000_000

    private func makeRouter(backend: MemoryPendingBackend = MemoryPendingBackend()) -> (Router, PendingActionStore) {
        let store = PendingActionStore(backend: backend, clock: { [unowned self] in now })
        let router = Router(pendingStore: store, state: { [unowned self] in guardState })
        return (router, store)
    }

    private func decide(
        _ route: String,
        fromForceUpdatePage: Bool,
        session: SessionState = .loggedIn
    ) -> GuardDecision {
        var state = guardState
        state.session = session
        state.fromForceUpdatePage = fromForceUpdatePage
        return EntryGuard.decide(request: RouteRequest(route: route, from: .inApp), state: state, routes: Routes.all)
    }

    /// 前提护栏：DeleteAccount 仍是未发布的次要入口。N-14 上线后这条会红，提醒把本文件的 DeleteAccount 用例改成放行（D10-1562）。
    func testPreconditionDeleteAccountStillUnreleasedSecondaryEntry() throws {
        let spec = try XCTUnwrap(Routes.all["DeleteAccount"])
        XCTAssertNil(spec.sinceIOS, "N-14 上线后：DeleteAccount 用例改为放行进 DeleteAccount、去掉升级提示过渡（D10-1562）")
        XCTAssertTrue(RoutePolicy.forceUpdateSecondaryRoutes.contains("DeleteAccount"))
    }

    // MARK: - Router：强更页上推入升级提示页

    /// 已登录 + below_min：强更页【注销账号】→ 升级提示页压在强更页上，强更页留在栈底，不登记 pending_action。
    /// N-14 后改为：path == [ForceUpdate, DeleteAccount(fromForceUpdatePage)]、reason force_update_exception（D10-1562）。
    func testLoggedInDeleteAccountFromForceUpdatePushesUpgradePromptOverForceUpdate() {
        guardState.session = .loggedIn
        let backend = MemoryPendingBackend()
        let (router, store) = makeRouter(backend: backend)
        router.enterForceUpdate()

        let decision = router.openFromForceUpdatePage(RouteRequest(route: "DeleteAccount", from: .inApp))
        XCTAssertEqual(decision.kind, .upgrade)
        XCTAssertNil(decision.route)
        XCTAssertEqual(router.lastDecision?.kind, .upgrade)
        XCTAssertEqual(router.lastDecision?.reason, GuardReason.unknownRoute)
        XCTAssertEqual(router.path.count, 2, "恰为 [强更页, 升级提示页]")
        XCTAssertEqual(router.path.first?.route, RoutePolicy.forceUpdate, "强更页留在栈底")
        XCTAssertNil(router.path.last?.route)
        XCTAssertEqual(router.path.last?.isUpgradePrompt, true)
        XCTAssertTrue(router.isOnForceUpdate)
        XCTAssertNil(store.load(now: now), "强更状态下不登记 pending_action")
        XCTAssertNil(backend.read())
    }

    /// 返回（弹出升级提示页）后回到强更页；再次进入强更判定不清掉栈。
    /// N-14 后改为：弹出的是 DeleteAccount（D10-1562）。
    func testPoppingUpgradePromptReturnsToForceUpdate() {
        let (router, _) = makeRouter()
        router.enterForceUpdate()
        router.openFromForceUpdatePage(RouteRequest(route: "DeleteAccount", from: .inApp))
        router.enterForceUpdate()
        XCTAssertEqual(router.path.count, 2, "已在强更页（含其上的提示页）时 enterForceUpdate 不动")
        router.path.removeLast()
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate])
    }

    /// 受限会话（BR-ID-01「受限会话」）同样给升级提示。N-14 后改为放行进 DeleteAccount（D10-1562）。
    func testRestrictedSessionDeleteAccountFromForceUpdateShowsUpgradePrompt() {
        guardState.session = .restricted
        let (router, store) = makeRouter()
        router.enterForceUpdate()

        router.openFromForceUpdatePage(RouteRequest(route: "DeleteAccount", from: .inApp))
        XCTAssertEqual(router.lastDecision?.kind, .upgrade)
        XCTAssertEqual(router.lastDecision?.reason, GuardReason.unknownRoute)
        XCTAssertEqual(router.path.count, 2)
        XCTAssertEqual(router.path.first?.route, RoutePolicy.forceUpdate)
        XCTAssertEqual(router.path.last?.isUpgradePrompt, true)
        XCTAssertNil(store.load(now: now))
    }

    /// 基本模式下从强更页点【注销账号】：先补同意（强更页留着，不登记 pending_action）；同意后按强更来源重走，
    /// 得到升级提示页。N-14 后改为：同意后进 DeleteAccount（D10-1562）。
    func testConsentThenDeleteAccountFromForceUpdateShowsUpgradePrompt() {
        guardState.privacy = .basicMode
        let backend = MemoryPendingBackend()
        let (router, _) = makeRouter(backend: backend)
        router.enterForceUpdate()

        let first = router.openFromForceUpdatePage(RouteRequest(route: "DeleteAccount", from: .inApp))
        XCTAssertEqual(first.kind, .requireConsent, "隐私闸门先于强更例外")
        XCTAssertTrue(router.consentRequested)
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate])
        XCTAssertNil(backend.read())

        guardState.privacy = .consented
        router.consentResolved(granted: true)
        XCTAssertEqual(router.lastDecision?.kind, .upgrade)
        XCTAssertEqual(router.lastDecision?.reason, GuardReason.unknownRoute)
        XCTAssertEqual(router.path.count, 2)
        XCTAssertEqual(router.path.first?.route, RoutePolicy.forceUpdate)
        XCTAssertEqual(router.path.last?.isUpgradePrompt, true)
        XCTAssertNil(backend.read())
    }

    // MARK: - 守卫层

    /// 强更页次要入口 + 已登录 + below_min：DeleteAccount → 升级提示。N-14 后改为 open / force_update_exception（D10-1562）。
    func testGuardDeleteAccountFromForceUpdatePageIsUpgrade() {
        let decision = decide("DeleteAccount", fromForceUpdatePage: true)
        XCTAssertEqual(decision.kind, .upgrade)
        XCTAssertNil(decision.route)
        XCTAssertEqual(decision.reason, GuardReason.unknownRoute)
    }

    /// 游客直接请求 DeleteAccount（页面本身会把游客送去受限登录，这里只记守卫现状）：未发布先于登录前置，同样是升级提示。
    /// N-14 后改为 requireLogin → Login（D10-1562）。
    func testGuardGuestDeleteAccountFromForceUpdatePageIsUpgrade() {
        let decision = decide("DeleteAccount", fromForceUpdatePage: true, session: .guest)
        XCTAssertEqual(decision.kind, .upgrade)
        XCTAssertEqual(decision.reason, GuardReason.unknownRoute)
    }

    /// 不是从强更页发起的 DeleteAccount：仍进强更页（名单要求本次由强更页发起）。N-14 后此条不变（D10-1562）。
    func testGuardDeleteAccountWithoutForceUpdatePageFlagStaysForceUpdate() {
        let decision = decide("DeleteAccount", fromForceUpdatePage: false)
        XCTAssertEqual(decision.kind, .forceUpdate)
        XCTAssertEqual(decision.route, RoutePolicy.forceUpdate)
        XCTAssertEqual(decision.reason, GuardReason.forceUpdateRequired)
    }

    /// 不在次要入口名单里的 Settings：从强更页发起也仍是 forceUpdate（过渡改动只影响名单内路由）。N-14 后不变（D10-1562）。
    func testGuardSettingsFromForceUpdatePageStaysForceUpdate() {
        let decision = decide("Settings", fromForceUpdatePage: true)
        XCTAssertEqual(decision.kind, .forceUpdate)
        XCTAssertEqual(decision.route, RoutePolicy.forceUpdate)
        XCTAssertEqual(decision.reason, GuardReason.forceUpdateRequired)
    }

    /// 已发布的次要入口不受影响：PrivacyCenter 从强更页仍 open / force_update_exception。N-14 后不变（D10-1562）。
    func testGuardPrivacyCenterFromForceUpdatePageStillOpens() {
        for session in [SessionState.guest, .loggedIn, .restricted] {
            let decision = decide("PrivacyCenter", fromForceUpdatePage: true, session: session)
            XCTAssertEqual(decision.kind, .open, session.rawValue)
            XCTAssertEqual(decision.route, "PrivacyCenter", session.rawValue)
            XCTAssertEqual(decision.reason, GuardReason.forceUpdateException, session.rawValue)
        }
    }

    /// 强更页次要入口只认 App 内来源：推送带 DeleteAccount 仍进强更页（不因过渡改成升级提示）。N-14 后不变（D10-1562）。
    func testGuardDeleteAccountFromPushWithForceUpdateFlagStaysForceUpdate() {
        var state = guardState
        state.fromForceUpdatePage = true
        let decision = EntryGuard.decide(
            request: RouteRequest(route: "DeleteAccount", from: .push),
            state: state,
            routes: Routes.all
        )
        XCTAssertEqual(decision.kind, .forceUpdate)
        XCTAssertEqual(decision.reason, GuardReason.forceUpdateRequired)
    }
}
