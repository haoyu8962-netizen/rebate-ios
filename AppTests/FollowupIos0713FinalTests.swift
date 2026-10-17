@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-0713 终版补测（变异执行 49/65 后补）：
/// - M11：二次验证通过、续发确认（runConfirm）前身份恰好变为未知 → 保留并在确认后续发一次；
/// - M17a / M17b：实名 / 劳务成功时页面不可见（仍在栈内）→ 再次提交 / 签署被拦；
/// - M18：劳务在签署中、等身份、已完成三种状态下再次 load() 不覆盖写结果；
/// - M43a、M44a/b/c/d/e/i：完成信号承重——`whenIdle()` 之后直接做正向断言（不再轮询），SensitiveFlow+Pending 的
///   abandon、refreshPending、runConfirm 三个任务各一例；
/// - M22b：installBackends 之后 WalletApi 入口计数仍生效。
/// 用例名前缀 `test_fuios0713_final_`。
final class FollowupIos0713FinalTests: WalletFlowTestCase {
    private let suites = FreshSuites()

    override func tearDown() {
        suites.removeAll()
        super.tearDown()
    }

    static let smsOk = FollowupIos0713StepUpTests.smsOk
    static let stepOk = FollowupIos0713StepUpTests.stepOk
    static let need = FollowupIos0713StepUpTests.need
    static let landed = FollowupIos0713StepUpTests.landed

    func fresh(_ tag: String) -> WalletAppFixture {
        WalletStubProtocol.reset()
        script.install()
        let (name, defaults) = suites.make(suiteName, tag)
        return WalletAppFixture.make(suiteName: name, defaults: defaults)
    }

    func onTop(_ fixture: WalletAppFixture, _ route: String) -> Bool {
        fixture.router.path.last?.route == route
    }

    func idle(_ controller: WithdrawController) async {
        for _ in 0..<3 {
            await controller.flow.stepUp.whenIdle()
            await controller.flow.whenIdle()
        }
    }

    func confirmCalls(_ fixture: WalletAppFixture) -> Int {
        fixture.api.calls("confirm:" + WithdrawController.operation)
    }

    // MARK: - M11：确认续发前身份未知

    /// 待确认的一笔点【确认上一笔】得到 10003 → 二次验证通过 → token 交给确认续发；放行验证响应时按读取位置注入单次 / 持续读取失败
    /// （覆盖「面板核对通过、续发确认前那一次读取失败」）。续发确认请求在假服务挂住：故障窗口在它到达服务端或页面给出结局时结束
    /// （之后的回包与导航不在本条范围，见 F-IOS-17）。撤掉故障后只经会话核对。接受的结局（都不得静默挂住）：
    /// ① 续发确认一次到达服务端 → 放行后落地（确认入口 2：10003 那次 + 续发）；
    /// ② 共享结算仍保留 10003 结果、续发前补不上 → 不续发，待确认保留并提示「稍后再试」（RV-02 既有口径）；
    /// ③ 续发在网络层发送前本地拒绝（F-IOS-16）→ 待确认保留并提示网络错误。验证入口始终 1 次。
    func test_fuios0713_final_confirmReplayHeldWhenIdentityTurnsUnknownBeforeRunConfirm() async throws {
        try await forEachReadPosition("确认续发") { fault, nth in
            let tag = "确认续发/\(fault.rawValue)#\(nth)"
            let fixture = fresh(tag)
            let controller = try await withdraw(fixture)
            try await enterPending(controller)
            script.on("POST /v1/withdrawals", Self.need, .hold)
            script.on("POST /v1/auth/step-up", .hold, Self.stepOk)
            flowActions(controller.flow).confirm()
            let stepUp = controller.flow.stepUp
            await waitUntil("\(tag)：确认没有触发二次验证") { stepUp.state?.phase == .ready }
            let held = try await verifyAndHold(stepUp, tag)
            let window = FaultWindow(fixture.store)
            window.begin(fault, nth)
            WalletStubProtocol.release(held, with: Self.stepOk)
            await waitUntil("\(tag)：验证结果到达后静默挂住（没有续发、没有等身份、没有提示）") {
                settledConfirm(controller)
            }
            let used = window.end()
            fixture.wallet.checkSession()
            await waitUntil("\(tag)：确认后静默挂住（没有续发、没有提示）") {
                WalletStubProtocol.heldIds.count == 1 || explicitNotice(controller)
            }
            try await assertConfirmOutcome(fixture, controller, tag)
            return used
        }
    }

    /// 验证结果到达后的可观察结局：续发确认已到服务端、或结果 / token 在等身份、或页面给出提示。
    private func settledConfirm(_ controller: WithdrawController) -> Bool {
        let flow = controller.flow.state
        return WalletStubProtocol.heldIds.count == 1 || flow.awaitingIdentity || explicitNotice(controller)
            || controller.flow.stepUp.state?.showsRecheck == true
    }

    /// 待确认卡上明确的「没续发」提示：稍后再试（RV-02）或网络错误（F-IOS-16）。
    private func explicitNotice(_ controller: WithdrawController) -> Bool {
        let key = controller.flow.state.pendingNotice?.key
        return key == SensitiveOutcome.retryLaterKey || key == WalletErrors.networkKey
    }

    private func assertConfirmOutcome(_ fixture: WalletAppFixture, _ controller: WithdrawController,
                                      _ tag: String) async throws {
        if WalletStubProtocol.heldIds.count == 1 {
            WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first), with: Self.landed)
            await idle(controller)
            XCTAssertTrue(onTop(fixture, WalletRoutes.withdrawRecords), "\(tag)：续发确认后落地")
            XCTAssertEqual(confirmCalls(fixture), 2, "\(tag)：确认入口 2 次（10003 那次 + 续发一次）")
        } else {
            await idle(controller)
            let state = controller.flow.state
            XCTAssertNotNil(state.pending, "\(tag)：没续发时待确认保留")
            let key = state.pendingNotice?.key
            XCTAssertTrue(key == SensitiveOutcome.retryLaterKey || key == WalletErrors.networkKey,
                          "\(tag)：没续发时必须明确提示（稍后再试 / 网络错误），实际 \(key ?? "nil")")
        }
        XCTAssertEqual(fixture.api.calls(StepUpController.verifyOperation), 1, "\(tag)：验证入口恰好 1 次")
    }

    func verifyAndHold(_ stepUp: StepUpController, _ tag: String) async throws -> Int {
        let state = try XCTUnwrap(stepUp.state)
        StepUpActions.make(stepUp, state).code("123456")
        let filled = try XCTUnwrap(stepUp.state)
        StepUpActions.make(stepUp, filled).verify()
        await waitUntil("\(tag)：验证没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        return try XCTUnwrap(WalletStubProtocol.heldIds.first)
    }

    // MARK: - M17a / M17b：成功时页面不可见，再次提交 / 签署被拦

    /// 实名：页面不可见（进后台）时提交成功（出栈留到回到可见）；此时页面仍在栈内，经页面回调重新填写并提交 → 后端入口仍 1 次。
    func test_fuios0713_final_realnameSuccessWhileHiddenBlocksResubmit() async throws {
        let fixture = fresh("实名后台成功")
        let backend = GateRealName()
        fixture.wallet.installBackends(realname: backend, labor: nil)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.realName))
        let controller = try XCTUnwrap(entry.controller as? RealNameController)
        try await submitRealname(controller, backend)
        fixture.wallet.sceneChanged(active: false)
        backend.release()
        await controller.whenIdle()
        XCTAssertTrue(onTop(fixture, WalletRoutes.realName), "前提：页面不可见，出栈留到回到可见，仍在栈内")
        let actions = RealNameActions.make(controller, controller.state)
        actions.name("张三")
        actions.idNo("11010519491231002X")
        RealNameActions.make(controller, controller.state).submit()
        if controller.state.consentId != nil {
            RealNameActions.make(controller, controller.state).toggleConsent()
            RealNameActions.make(controller, controller.state).agree()
        }
        await controller.whenIdle()
        XCTAssertFalse(controller.submitEnabled, "成功后提交锁住")
        XCTAssertEqual(backend.calls, 1, "成功后再提交被拦")
    }

    func submitRealname(_ controller: RealNameController, _ backend: GateRealName) async throws {
        let actions = RealNameActions.make(controller, controller.state)
        actions.name("张三")
        actions.idNo("11010519491231002X")
        RealNameActions.make(controller, controller.state).submit()
        _ = try XCTUnwrap(controller.state.consentId, "单独同意没有打开")
        RealNameActions.make(controller, controller.state).toggleConsent()
        RealNameActions.make(controller, controller.state).agree()
        await waitUntil("实名提交没有发出") { backend.calls == 1 }
    }

    /// 打开提现页 → 劳务协议页，读到协议并勾选（load 经 whenIdle 结算后直接断言内容到位：M44i）。
    func laborReady(_ fixture: WalletAppFixture,
                    _ backend: GateLabor) async throws -> LaborAgreementController {
        fixture.wallet.installBackends(realname: nil, labor: backend)
        _ = try await withdraw(fixture)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.laborAgreement))
        let controller = try XCTUnwrap(entry.controller as? LaborAgreementController)
        controller.load()
        await controller.whenIdle()
        XCTAssertEqual(controller.state.phase, .content, "load 经完成信号结算后协议已到位")
        LaborActions.make(controller, controller.state).toggle()
        return controller
    }

    /// 劳务：页面不可见时签署成功；页面仍在栈内，经页面回调再签 → 后端签署入口仍 1 次；此时再 load() 不覆盖已完成的结果（M18 已完成态）。
    func test_fuios0713_final_laborSuccessWhileHiddenBlocksResignAndReload() async throws {
        let fixture = fresh("劳务后台成功")
        await verifyRealname(fixture)
        let backend = GateLabor()
        let controller = try await laborReady(fixture, backend)
        LaborActions.make(controller, controller.state).sign()
        await waitUntil("签署没有发出") { backend.signs == 1 }
        fixture.wallet.sceneChanged(active: false)
        backend.release()
        await controller.whenIdle()
        XCTAssertTrue(onTop(fixture, WalletRoutes.laborAgreement), "前提：页面不可见，仍在栈内")
        LaborActions.make(controller, controller.state).sign()
        await controller.whenIdle()
        XCTAssertEqual(backend.signs, 1, "成功后再签被拦")
        XCTAssertFalse(controller.signEnabled, "成功后签署锁住")
        controller.load()
        XCTAssertNotEqual(controller.state.phase, .loading, "已完成：load() 不重新读取覆盖结果")
        await controller.whenIdle()
        XCTAssertFalse(controller.signEnabled, "已完成：load() 之后签署仍锁住")
    }

    // MARK: - M18：签署中 / 等身份时 load() 不覆盖

    /// 签署在途时 load()：不重新读取（不进加载中、签署中保持）；签署结果照常落地一次。
    func test_fuios0713_final_laborReloadWhileSigningDoesNotOverwrite() async throws {
        let fixture = fresh("劳务签署中重读")
        await verifyRealname(fixture)
        let backend = GateLabor()
        let controller = try await laborReady(fixture, backend)
        LaborActions.make(controller, controller.state).sign()
        await waitUntil("签署没有发出") { backend.signs == 1 }
        controller.load()
        XCTAssertEqual(controller.state.phase, .content, "签署中：load() 不重新读取")
        XCTAssertTrue(controller.state.signing, "签署中保持")
        backend.release()
        await controller.whenIdle()
        XCTAssertTrue(onTop(fixture, WalletRoutes.withdraw), "签署结果落地：回到提现页")
        XCTAssertEqual(backend.signs, 1, "签署 1 次")
    }

    /// 签署结果在身份持续未知时到达（等身份）；Keychain 恢复后、确认之前 load()：不覆盖等身份状态；本页【重试】按原结果落地。
    func test_fuios0713_final_laborReloadWhileAwaitingIdentityDoesNotOverwrite() async throws {
        let fixture = fresh("劳务等身份重读")
        await verifyRealname(fixture)
        let backend = GateLabor()
        let controller = try await laborReady(fixture, backend)
        LaborActions.make(controller, controller.state).sign()
        await waitUntil("签署没有发出") { backend.signs == 1 }
        fixture.store.failReads(fromNth: 1)
        backend.release()
        await controller.whenIdle()
        XCTAssertTrue(controller.state.awaitingIdentity, "前提：结果待身份确认")
        fixture.store.disarm()
        controller.load()
        XCTAssertTrue(controller.state.awaitingIdentity, "等身份：load() 不覆盖")
        XCTAssertNotEqual(controller.state.phase, .loading, "等身份：load() 不重新读取")
        await controller.whenIdle()
        XCTAssertTrue(controller.deferral.isPending, "保留的结果仍在")
        LaborActions.make(controller, controller.state).recheck()
        await controller.whenIdle()
        XCTAssertTrue(onTop(fixture, WalletRoutes.withdraw), "本页【重试】按原结果落地")
        XCTAssertEqual(backend.signs, 1, "签署 1 次")
    }
}
