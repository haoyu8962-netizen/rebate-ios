import Combine
@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-0713 必测 4（2026-10-17 追加，RW-03 / F-X-22 口径）：实名提交、劳务签署（Debug 后端）的结果在身份暂时未知时到达。
/// 要求：不转圈（展示接口 `showsSubmitting / showsSigning` 为假）、显示本页【重试】（`showsRecheck`）；提交 / 签署仍锁住，经页面回调
/// 再点也不调用后端；身份仍不可读时点【重试】并等结算：页面、待确认结果、写锁都保留；恢复后点【重试】按原结果落地：明确的成功结果、
/// 返回发起页、发起页状态刷新；后端入口恰好 1（入口同步计数）。故障按读取位置遍历；负向断言在 `whenIdle()` 之后取值。
final class FollowupIos0713IdentityWriteTests: WalletFlowTestCase {
    private let suites = FreshSuites()

    override func tearDown() {
        suites.removeAll()
        super.tearDown()
    }

    private func fresh(_ tag: String) -> WalletAppFixture {
        WalletStubProtocol.reset()
        script.install()
        let (name, defaults) = suites.make(suiteName, tag)
        return WalletAppFixture.make(suiteName: name, defaults: defaults)
    }

    private func onTop(_ fixture: WalletAppFixture, _ route: String) -> Bool {
        fixture.router.path.last?.route == route
    }

    /// 填表、同意并提交（渲染时的回调），等后端入口收到。
    private func submitRealname(_ controller: RealNameController, _ backend: GateRealName) async throws {
        let actions = RealNameActions.make(controller, controller.state)
        actions.name("张三")
        actions.idNo("11010519491231002X")
        RealNameActions.make(controller, controller.state).submit()
        _ = try XCTUnwrap(controller.state.consentId, "单独同意没有打开")
        RealNameActions.make(controller, controller.state).toggleConsent()
        RealNameActions.make(controller, controller.state).agree()
        await waitUntil("实名提交没有发出") { backend.calls == 1 }
    }

    /// 实名页结果待身份确认的完整状态：在本页、不转圈、显示【重试】、待确认结果还在、提交锁住、没有错误、没有完成提示。
    /// 记下执行器是否发布过完成提示。
    @MainActor
    final class DoneProbe {
        var seen = false
    }

    private func assertRealnameWaiting(_ fixture: WalletAppFixture, _ controller: RealNameController, _ tag: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let state = controller.state
        XCTAssertTrue(onTop(fixture, WalletRoutes.realName), "\(tag)：仍在实名页", file: file, line: line)
        XCTAssertTrue(state.awaitingIdentity, "\(tag)：结果已到、等身份确认", file: file, line: line)
        XCTAssertFalse(state.showsSubmitting, "\(tag)：不转圈", file: file, line: line)
        XCTAssertTrue(state.showsRecheck, "\(tag)：显示本页【重试】", file: file, line: line)
        XCTAssertTrue(controller.deferral.isPending, "\(tag)：待确认结果保留", file: file, line: line)
        XCTAssertFalse(controller.submitEnabled, "\(tag)：提交仍锁住", file: file, line: line)
        XCTAssertNil(state.error, "\(tag)：不显示可重试错误", file: file, line: line)
        XCTAssertNil(state.done, "\(tag)：没有完成提示", file: file, line: line)
    }

    /// 等待期间经页面回调再提交一次（提交 → 同意 → 继续），等执行器空闲后后端入口仍只 1 次；再点【重试】（身份仍不可读）并等结算，仍在等待。
    private func pokeWhileUnknown(_ fixture: WalletAppFixture, _ controller: RealNameController,
                                  _ backend: GateRealName, _ tag: String) async {
        RealNameActions.make(controller, controller.state).submit()
        if controller.state.consentId != nil {
            RealNameActions.make(controller, controller.state).toggleConsent()
            RealNameActions.make(controller, controller.state).agree()
        }
        await controller.whenIdle()
        XCTAssertEqual(backend.calls, 1, "\(tag)：等待期间再点不调用后端")
        RealNameActions.make(controller, controller.state).recheck()
        await controller.whenIdle()
        assertRealnameWaiting(fixture, controller, "\(tag)：身份仍不可读时点【重试】后")
    }

    /// 实名提交成功结果到达时身份暂时未知（按读取位置遍历）。没落地时：完整等待态；持续形态下再点 / 点【重试】仍等待。窗口结束后点【重试】
    /// （之前没有外部会话核对）→ 发布过完成提示「realname.done」、回到发起页（钱包首页）；后端入口恰好 1。实名结论刷新走
    /// AppWallet.refreshRealname（直接用 ApiClient、不经三态），身份未知时会丢，记待裁定，不在此断言。
    func testRealnameResultWhileUnknownIsNotSpinningAndLandsOnceViaInPageRecheck() async throws {
        try await forEachReadPosition("实名提交") { fault, nth in
            let tag = "实名提交/\(fault.rawValue)#\(nth)"
            let fixture = fresh(tag)
            let backend = GateRealName()
            fixture.wallet.installBackends(realname: backend, labor: nil)
            fixture.router.open(RouteRequest(route: WalletRoutes.wallet, from: .inApp))
            let entry = try XCTUnwrap(fixture.open(WalletRoutes.realName), "\(tag)：实名页没有打开")
            let controller = try XCTUnwrap(entry.controller as? RealNameController)
            // 明确的成功结果：执行器发布过完成提示（出栈离页后表单会清空，所以订阅发布的状态记下）
            let done = DoneProbe()
            let watch = controller.$state.sink { state in
                MainActor.assumeIsolated {
                    if state.done?.key == "realname.done" {
                        done.seen = true
                    }
                }
            }
            defer { watch.cancel() }
            try await submitRealname(controller, backend)
            let window = FaultWindow(fixture.store)
            window.begin(fault, nth)
            backend.release()
            await controller.whenIdle()
            if onTop(fixture, WalletRoutes.realName) {
                assertRealnameWaiting(fixture, controller, tag)
                if fault == .from {
                    await pokeWhileUnknown(fixture, controller, backend, tag)
                }
            }
            let used = window.end()
            if onTop(fixture, WalletRoutes.realName) {
                RealNameActions.make(controller, controller.state).recheck()
            }
            await waitUntil("\(tag)：本页【重试】后没有回到发起页") { onTop(fixture, WalletRoutes.wallet) }
            XCTAssertTrue(done.seen, "\(tag)：明确的成功结果（完成提示 realname.done）")
            await controller.whenIdle()
            XCTAssertEqual(backend.calls, 1, "\(tag)：实名提交恰好 1 次")
            return used
        }
    }

    private func assertLaborWaiting(_ fixture: WalletAppFixture, _ controller: LaborAgreementController, _ tag: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let state = controller.state
        XCTAssertTrue(onTop(fixture, WalletRoutes.laborAgreement), "\(tag)：仍在劳务协议页", file: file, line: line)
        XCTAssertTrue(state.awaitingIdentity, "\(tag)：结果已到、等身份确认", file: file, line: line)
        XCTAssertFalse(state.showsSigning, "\(tag)：不转圈", file: file, line: line)
        XCTAssertTrue(state.showsRecheck, "\(tag)：显示本页【重试】", file: file, line: line)
        XCTAssertTrue(controller.deferral.isPending, "\(tag)：待确认结果保留", file: file, line: line)
        XCTAssertFalse(controller.signEnabled, "\(tag)：签署仍锁住", file: file, line: line)
        XCTAssertNil(state.error, "\(tag)：不显示可重试错误", file: file, line: line)
    }

    /// 打开提现页 → 劳务协议页，读到协议、勾选、签署，等后端签署入口收到。
    private func signLabor(_ fixture: WalletAppFixture, _ backend: GateLabor,
                           _ tag: String) async throws -> LaborAgreementController {
        _ = try await withdraw(fixture)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.laborAgreement), "\(tag)：劳务协议页没有打开")
        let controller = try XCTUnwrap(entry.controller as? LaborAgreementController)
        controller.load()
        await waitUntil("\(tag)：协议没有到位") { controller.state.phase == .content }
        LaborActions.make(controller, controller.state).toggle()
        LaborActions.make(controller, controller.state).sign()
        await waitUntil("\(tag)：签署没有发出") { backend.signs == 1 }
        return controller
    }

    /// 劳务签署成功结果到达时身份暂时未知（按读取位置遍历）：同上口径；落地 = 回到发起的提现页，签署结果按成功采用（不再等身份、签署
    /// 结束、没有错误、保留的结果已取出；签署后 Withdraw 的 rules 重取由页面出现驱动，单测不渲染页面，不在此断言）；后端签署入口恰好 1。
    func testLaborSignResultWhileUnknownIsNotSpinningAndLandsOnceViaInPageRecheck() async throws {
        try await forEachReadPosition("劳务签署") { fault, nth in
            let tag = "劳务签署/\(fault.rawValue)#\(nth)"
            let fixture = fresh(tag)
            let backend = GateLabor()
            fixture.wallet.installBackends(realname: nil, labor: backend)
            await verifyRealname(fixture)
            let controller = try await signLabor(fixture, backend, tag)
            let window = FaultWindow(fixture.store)
            window.begin(fault, nth)
            backend.release()
            await controller.whenIdle()
            if onTop(fixture, WalletRoutes.laborAgreement) {
                assertLaborWaiting(fixture, controller, tag)
                if fault == .from {
                    LaborActions.make(controller, controller.state).sign()
                    LaborActions.make(controller, controller.state).recheck()
                    await controller.whenIdle()
                    XCTAssertEqual(backend.signs, 1, "\(tag)：等待期间再点不调用后端")
                    assertLaborWaiting(fixture, controller, "\(tag)：身份仍不可读时点【重试】后")
                }
            }
            let used = window.end()
            if onTop(fixture, WalletRoutes.laborAgreement) {
                LaborActions.make(controller, controller.state).recheck()
            }
            await waitUntil("\(tag)：本页【重试】后没有回到提现页") { onTop(fixture, WalletRoutes.withdraw) }
            await controller.whenIdle()
            let landed = controller.state
            XCTAssertFalse(landed.awaitingIdentity, "\(tag)：结果已采用（不再等身份）")
            XCTAssertFalse(landed.signing, "\(tag)：签署已结束")
            XCTAssertNil(landed.error, "\(tag)：按成功采用（没有错误）")
            XCTAssertFalse(controller.deferral.isPending, "\(tag)：保留的结果已取出")
            XCTAssertEqual(backend.signs, 1, "\(tag)：签署恰好 1 次")
            return used
        }
    }

    /// 对照（确认换代才丢弃）：实名结果在身份持续未知时到达，之后确认换成另一个账号 → 不采用（没有完成提示、表单清空）、不重放。
    func testRealnameHeldResultDroppedOnConfirmedSessionChange() async throws {
        let fixture = fresh("实名换代对照")
        let backend = GateRealName()
        fixture.wallet.installBackends(realname: backend, labor: nil)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.realName))
        let controller = try XCTUnwrap(entry.controller as? RealNameController)
        try await submitRealname(controller, backend)
        fixture.store.failReads(fromNth: 1)
        backend.release()
        await controller.whenIdle()
        fixture.store.disarm()
        try fixture.switchAccount(to: "user-b")
        fixture.wallet.checkSession()
        await controller.whenIdle()
        XCTAssertNil(controller.state.done, "不采用旧结果")
        XCTAssertEqual(controller.state.name, "", "表单清空")
        XCTAssertEqual(backend.calls, 1, "不重放")
    }
}
