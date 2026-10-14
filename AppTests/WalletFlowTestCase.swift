@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Router
import Wallet
import WalletCore
import XCTest

/// 提现、收款账号流程测试的公共部分：每个用例一个独立的组合（UserDefaults 套件、缓存目录、未决记录内存后端），本地假服务按脚本回答。
@MainActor
class WalletFlowTestCase: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    let script = WalletScript()

    override func setUpWithError() throws {
        suiteName = "\(type(of: self)).\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        WalletStubProtocol.reset()
        script.install()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        WalletStubProtocol.reset()
    }

    func make(account: String = "user-a",
              pending: MemoryPendingKeyBackend = MemoryPendingKeyBackend()) -> WalletAppFixture {
        WalletAppFixture.make(suiteName: suiteName, defaults: defaults, account: account, pending: pending)
    }

    /// 本会话查过实名（守卫放行要实名的资金页）。
    func verifyRealname(_ fixture: WalletAppFixture) async {
        fixture.wallet.realnameChanged()
        await waitUntil("实名状态没取到") { fixture.wallet.realnameVerified() }
    }

    /// 打开提现页并等 rules 与收款账号行到位。
    func withdraw(_ fixture: WalletAppFixture) async throws -> WithdrawController {
        await verifyRealname(fixture)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.withdraw), "提现页没有打开")
        let controller = try XCTUnwrap(entry.controller as? WithdrawController)
        controller.start()
        await waitUntil("rules 没有到位") { controller.state.phase == .content }
        return controller
    }

    func payout(_ fixture: WalletAppFixture) async throws -> PayoutAccountController {
        await verifyRealname(fixture)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.payoutAccount), "收款账号页没有打开")
        let controller = try XCTUnwrap(entry.controller as? PayoutAccountController)
        controller.start()
        await waitUntil("收款账号没有到位") { controller.state.phase != .loading }
        return controller
    }

    /// 页面渲染时取出的按钮回调（与 WithdrawScreen 同一个构造）。
    func actions(_ controller: WithdrawController) -> WithdrawActions {
        WithdrawActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id)
    }

    func flowActions(_ flow: SensitiveFlow) -> FlowActions {
        FlowActions.make(flow, flow.state)
    }

    /// 输入金额并等估算（或 rules）回来。
    func typeAmount(_ controller: WithdrawController, _ text: String) async {
        actions(controller).amount(text)
        await waitUntil("估算没有回来") {
            if case .shown = controller.state.estimate {
                return true
            }
            return controller.state.estimate == .hidden
        }
    }

    var posts: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("POST", "/v1/withdrawals")
    }

    var saves: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("PUT", "/v1/me/payout-account")
    }

    /// 二次验证面板：输入并验证（面板回调取渲染时的实例）。
    func passStepUp(_ stepUp: StepUpController, code: String = "123456") async throws {
        await waitUntil("二次验证面板没有打开") { stepUp.state?.phase == .ready }
        let state = try XCTUnwrap(stepUp.state)
        StepUpActions.make(stepUp, state).code(code)
        let filled = try XCTUnwrap(stepUp.state)
        StepUpActions.make(stepUp, filled).verify()
    }

    /// 让提交进入结果未知（断连）并等待待确认卡出现。
    func enterPending(_ controller: WithdrawController, amount: String = "10") async throws {
        script.on("POST /v1/withdrawals", .disconnect)
        await typeAmount(controller, amount)
        actions(controller).submit()
        await waitUntil("没有进入待确认") { controller.flow.state.pending != nil && controller.flow.state.phase == .pending }
    }
}
