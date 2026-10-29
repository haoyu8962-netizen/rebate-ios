@testable import Couli
import CouliNetwork
import Foundation
import Generated
import OrderCore
import Router
import Wallet
import WalletCore
import XCTest

/// 钱包页（AC-S2-33、AC-S1-105、TECH-20、G10、G11、G20、G22）：经真实 Router 打开、页面按钮回调出发，断言落点路由与参数、显示结论、缓存与
/// 金额隐藏；42901 在执行层拦截。
@MainActor
final class WalletPageTests: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    let script = WalletScript()

    override func setUpWithError() throws {
        suiteName = "WalletPageTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        WalletStubProtocol.reset()
        script.install()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        WalletStubProtocol.reset()
    }

    func make() -> WalletAppFixture {
        WalletAppFixture.make(suiteName: suiteName, defaults: defaults)
    }

    func walletController(_ fixture: WalletAppFixture) throws -> WalletController {
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.wallet))
        return try XCTUnwrap(entry.controller as? WalletController)
    }

    func loaded(_ fixture: WalletAppFixture) async throws -> WalletController {
        let controller = try walletController(fixture)
        controller.load()
        await waitUntil("钱包摘要没有加载") { controller.state.summary != nil || controller.state.phase == .error }
        return controller
    }

    // MARK: - 路由

    func testRoutesRegisteredAndInRoutesJson() {
        for route in WalletRoutes.all {
            XCTAssertNotNil(Routes.all[route], "\(route) 不在 routes.json")
        }
        for route in WalletRoutes.pages + [WalletRoutes.ledger, WalletRoutes.earnings] {
            XCTAssertNotNil(RouteViewRegistry.builders[route], "\(route) 没有接页面")
        }
        XCTAssertNil(Routes.all["StepUp"])
        XCTAssertNil(Routes.all["WithdrawDetail"])
    }

    /// AC-S2-33 正常：「可提现余额 ¥10」「冻结中 ¥2」「已提现 ¥0」「预估收益 ¥10.19」，三项进度分开；没有「待入账」「累计」。
    func testAcS2_33NormalSummaryFromServerFields() async throws {
        let fixture = make()
        let controller = try await loaded(fixture)
        let summary = try XCTUnwrap(controller.state.summary)
        let view = WalletSummaryView.of(summary, masked: false, nowMs: controller.displayNowMillis())
        XCTAssertEqual(view.hero.fen, 1000)
        XCTAssertEqual(view.frozen.fen, 200)
        XCTAssertEqual(view.withdrawn.fen, 0)
        XCTAssertEqual(view.estimated.fen, 1019)
        XCTAssertEqual(view.receivedLine.fen, 750)
        XCTAssertEqual(view.pausedLine?.fen, 450)
        XCTAssertNotNil(view.earliestMonth)
        XCTAssertTrue(controller.state.withdrawEnabled)
        let drafts = WalletDraftTexts.drafts.values.joined()
        XCTAssertFalse(drafts.contains("待入账"))
        XCTAssertFalse(drafts.contains("累计"))
    }

    /// 抓包确认客户端不自行相加：改 estimated_fen / pending_credit_fen 不影响「预估收益」。
    func testEstimatedTotalIsServerValueNotClientSum() async throws {
        script.ok("GET /v1/wallet/summary", WalletSamples.summary
            .replacingOccurrences(of: "\"estimated_fen\":269", with: "\"estimated_fen\":1")
            .replacingOccurrences(of: "\"pending_credit_fen\":750", with: "\"pending_credit_fen\":2"))
        let fixture = make()
        let controller = try await loaded(fixture)
        let view = WalletSummaryView.of(try XCTUnwrap(controller.state.summary), masked: false, nowMs: 0)
        XCTAssertEqual(view.estimated.fen, 1019)
    }

    /// AC-S2-33 a / b / c：风控暂停提示条（G11 更正：【提现】不置灰）；待抵扣置灰；withdraw_enabled=false 显示 error.30306 并置灰。
    func testAcS2_33RiskNegativeAndDisabled() async throws {
        // swiftlint:disable:next large_tuple
        let cases: [(String, String, Bool)] = [
            ("\"risk_paused_reason\":null", "\"risk_paused_reason\":\"fixture_unlisted_reason\"", true),
            ("\"negative_fen\":0", "\"negative_fen\":200", false),
            ("\"withdraw_enabled\":true", "\"withdraw_enabled\":false", false),
        ]
        for (from, to, enabled) in cases {
            script.ok("GET /v1/wallet/summary", WalletSamples.summary.replacingOccurrences(of: from, with: to))
            let fixture = make()
            let controller = try await loaded(fixture)
            XCTAssertEqual(controller.state.withdrawEnabled, enabled, to)
            let view = WalletSummaryView.of(try XCTUnwrap(controller.state.summary), masked: false, nowMs: 0)
            if to.contains("risk") {
                XCTAssertTrue(view.riskBanner.show)
                XCTAssertEqual(view.riskBanner.textKey, "wallet.draft.risk_paused")
            }
            if to.contains("withdraw_enabled") {
                XCTAssertEqual(view.withdrawReasonKey, "error.30306")
            }
            // 置灰时点【提现】零导航、零请求（FU-IOS-0733：等满 1.5 秒观察窗——实名查询与其后的导航都已落定——再判）
            let before = fixture.router.path.count
            let path = fixture.router.path
            let tab = fixture.router.tabRoot
            let requests = WalletStubProtocol.requests.count
            WalletActions.make(controller, controller.state).withdraw()
            if enabled {
                await waitUntil("可点时进提现页") { fixture.router.path.count > before }
            } else {
                await quietWindow()
                XCTAssertEqual(fixture.router.path.count, before, "置灰时零导航")
                XCTAssertEqual(fixture.router.path, path, "置灰时零导航（栈）：\(to)")
                XCTAssertEqual(fixture.router.tabRoot, tab, "置灰时零导航（Tab）：\(to)")
                let after = WalletStubProtocol.requests.dropFirst(requests).map { "\($0.method) \($0.path)" }
                XCTAssertEqual(after, [], "置灰时零请求（含 GET /v1/me）：\(to)")
            }
            fixture.router.path.removeAll()
        }
    }

    /// 入口：【提现】先查实名再进 Withdraw（无参数）；「提现记录 ›」→ WithdrawRecords（无参数）；订单 → OrderList（Tab 根）；余额流水 →
    /// Ledger；风控提示条 → RiskNotice；收益看板 flag 打开也不显示（Earnings since 为 null，G20）。
    func testEntriesLandOnExactRoutes() async throws {
        let fixture = make()
        let controller = try await loaded(fixture)
        let actions = WalletActions.make(controller, controller.state)
        actions.withdraw()
        await waitUntil("没有进提现页") { fixture.router.path.last?.route == WalletRoutes.withdraw }
        XCTAssertEqual(fixture.router.path.last?.params, [:])
        XCTAssertEqual(WalletStubProtocol.requests("GET", "/v1/me").count, 1, "先取 GET /v1/me 的实名状态")
        fixture.router.path.removeLast()
        actions.records()
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.withdrawRecords)
        XCTAssertEqual(fixture.router.path.last?.params, [:])
        fixture.router.path.removeLast()
        actions.entry(WalletRoutes.ledger)
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.ledger)
        fixture.router.path.removeLast()
        actions.entry(WalletRoutes.riskNotice)
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.riskNotice)
        fixture.router.path.removeLast()
        actions.entry(WalletRoutes.earnings)
        XCTAssertNotEqual(fixture.router.path.last?.route, WalletRoutes.earnings, "收益看板入口隐藏（G20）")
        XCTAssertFalse(controller.earningsVisible)
        XCTAssertFalse(EarningsEntry.visible(
            flag: true,
            routeSince: Routes.all["Earnings"]?.sinceIOS,
            appVersion: "9.9.9"
        ))
        actions.entry(WalletRoutes.orderList)
        XCTAssertEqual(fixture.router.tabRoot.route, WalletRoutes.orderList)
    }

    /// AC-S1-105（钱包部分）：在钱包点眼睛 → 钱包金额「****」，订单页的同一份偏好也随之隐藏；换账号仍隐藏；开关不上传、金额请求不变。
    func testAcS1_105MaskSharedWithOrdersAndSurvivesAccountSwitch() async throws {
        let fixture = make()
        let controller = try await loaded(fixture)
        let requests = WalletStubProtocol.requests.count
        WalletActions.make(controller, controller.state).toggleMask()
        XCTAssertTrue(fixture.wallet.mask.hidden)
        XCTAssertTrue(AmountMaskStore(defaults: defaults).hidden, "订单页读同一份本机偏好（键 amount_mask.hidden）")
        XCTAssertEqual(AmountMaskStore.key, "amount_mask.hidden")
        let view = WalletSummaryView.of(try XCTUnwrap(controller.state.summary), masked: true, nowMs: 0)
        XCTAssertEqual(view.hero.maskedText, "****")
        XCTAssertEqual(WalletStubProtocol.requests.count, requests, "隐藏开关不发请求、不上传")
        try fixture.switchAccount(to: "user-b")
        XCTAssertTrue(fixture.wallet.mask.hidden, "本机偏好不随账号")
    }
}
