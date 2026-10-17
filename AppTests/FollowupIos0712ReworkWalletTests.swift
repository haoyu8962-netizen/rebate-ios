@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-0712 整体重理（钱包与资金页）：一处身份快照 + 一套页面恢复机制，全部经生产入口（AppWallet.entry / checkSession）。
/// 异步结果一律等结算条件成立再断言；负向断言引用结算后取出的局部值。
final class FollowupIos0712ReworkWalletTests: WalletFlowTestCase {
    private static let epoch = "fixture-login-user-a"

    /// 打开路由（守卫先放行），建页时 Keychain 暂时读失败（固定身份未确认），返回页面。
    private func openWhileUnknown(_ fixture: WalletAppFixture, _ route: String) throws -> WalletPageEntry {
        fixture.router.open(RouteRequest(route: route, from: .inApp))
        let top = try XCTUnwrap(fixture.router.path.last)
        XCTAssertEqual(top.route, route, "前提：路由已通过守卫")
        fixture.tokens.failReads = .readFailed
        let entry = try XCTUnwrap(fixture.wallet.entry(for: top))
        fixture.tokens.failReads = nil
        XCTAssertFalse(entry.identityKnown, "前提：建页时身份未确认")
        return entry
    }

    // MARK: - 未知期间构造的资金表单（G54 / Android R2-04 同类）

    /// 提现页：未知期间构造 → 结算为可重试（不是无出口的加载）、金额输入不受理；身份确认（判据相同）后同一页换上身份、按它恢复金额草稿、
    /// 加载出页头，之后可以编辑。
    func testReworkWithdrawBuiltWhileUnknownBecomesEditableWithDraftAfterConfirmation() async throws {
        let fixture = make()
        await verifyRealname(fixture)
        let store = fixture.cleaner.store
        store.writeDraft(account: "user-a", loginEpoch: Self.epoch, amount: "12", ticket: store.generation)
        let entry = try openWhileUnknown(fixture, WalletRoutes.withdraw)
        let controller = try XCTUnwrap(entry.controller as? WithdrawController)
        controller.start()
        XCTAssertEqual(controller.state.phase, .error, "不留无出口的加载态")
        XCTAssertFalse(controller.onAmountChange("5", owner: controller.owner), "前提：未确认身份不受理输入")
        fixture.wallet.checkSession()
        XCTAssertEqual(controller.owner.account, "user-a", "同一页换上已确认身份")
        await waitUntil("换上身份后页头没有到位") { controller.state.phase == .content }
        let amount = controller.state.amountText
        XCTAssertEqual(amount, "12", "按已确认身份恢复金额草稿")
        XCTAssertTrue(controller.onAmountChange("15", owner: controller.owner), "可以编辑")
    }

    /// 收款账号页：未知期间构造 → 结算为可重试；身份确认后同一页换上身份并加载出账号，表单可编辑。
    func testReworkPayoutBuiltWhileUnknownBecomesEditableAfterConfirmation() async throws {
        let fixture = make()
        await verifyRealname(fixture)
        let entry = try openWhileUnknown(fixture, WalletRoutes.payoutAccount)
        let controller = try XCTUnwrap(entry.controller as? PayoutAccountController)
        controller.start()
        XCTAssertEqual(controller.state.phase, .error, "不留无出口的加载态")
        fixture.wallet.checkSession()
        XCTAssertEqual(controller.owner.account, "user-a", "同一页换上已确认身份")
        await waitUntil("换上身份后账号没有到位") { controller.state.account != nil }
        XCTAssertTrue(controller.ownsForm(controller.owner), "表单归属已是当前会话（可编辑）")
    }

    // MARK: - 提现记录：路由定位参数

    /// 带 withdrawal_id 打开：定位单响应回来时身份核对读失败 → 在途标记结清、结算为可重试；身份确认后补取的一轮仍带定位参数，置顶这张单。
    func testReworkRecordsFocusAbortedAtResponseResumesWithRouteParam() async throws {
        let fixture = make()
        script.on("GET /v1/withdrawals/W9", .hold)
        let entry = try XCTUnwrap(fixture.open(
            WalletRoutes.withdrawRecords, params: [WalletRoutes.withdrawalId: .string("W9")]
        ))
        let controller = try XCTUnwrap(entry.controller as? WithdrawRecordsController)
        controller.load()
        await waitUntil("定位请求没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        script.on("GET /v1/withdrawals/W9")
        fixture.store.failReads(fromNth: 1)
        WalletStubProtocol.release(held, with: .envelope(
            code: 0, data: WalletSamples.withdrawal("W9", status: "PAID_API", channel: "c"), headers: [:]
        ))
        await waitUntil("定位响应核对没有结算") { controller.loadPending && !controller.firstPagePending }
        fixture.store.stopFailing()
        let aborted = controller.state
        XCTAssertEqual(aborted.phase, .error, "可重试的结算态")
        XCTAssertNil(aborted.pinnedId, "核对失败的响应不采用")
        fixture.wallet.checkSession()
        await waitUntil("补取后定位单没有置顶") { controller.state.pinnedId == "W9" }
        let pending = controller.loadPending
        XCTAssertFalse(pending)
    }

    // MARK: - 劳务协议、实名、提交结果

    /// 劳务协议：读取发送前身份核对读失败 → 结算为可重试、记待补取；身份确认后同一页补取出协议。
    func testReworkLaborLoadAbortedResumesOnConfirmation() async throws {
        let fixture = make()
        fixture.wallet.installBackends(realname: nil, labor: FixtureLabor())
        await verifyRealname(fixture)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.laborAgreement), "劳务协议页没有打开")
        let controller = try XCTUnwrap(entry.controller as? LaborAgreementController)
        fixture.store.failRead(nth: 1)
        controller.load()
        XCTAssertEqual(controller.state.phase, .error, "不留无出口的加载态")
        XCTAssertTrue(controller.deferral.isPending, "记待补取")
        fixture.wallet.checkSession()
        await waitUntil("补取后协议没有到位") { controller.state.phase == .content }
        let text = controller.state.text
        XCTAssertEqual(text, "fixture")
    }

    /// 实名：提交结果回来时身份暂时未知 → 不采用、不重放（提交中保持）；身份确认后仍是本表单身份才采用（完成提示）。
    func testReworkRealnameResultArrivingWhileUnknownAppliesAfterConfirmation() async throws {
        let fixture = make()
        let backend = GateRealName()
        fixture.wallet.installBackends(realname: backend, labor: nil)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.realName), "实名页没有打开")
        let controller = try XCTUnwrap(entry.controller as? RealNameController)
        let owner = controller.state.owner
        controller.onNameChange("张三", owner: owner)
        controller.onIdChange("11010519491231002X", owner: owner)
        controller.submit(owner: owner)
        let consent = try XCTUnwrap(controller.state.consentId)
        controller.toggleConsent(consent: consent, owner: owner)
        controller.agreeAndSubmit(consent: consent, owner: owner)
        await waitUntil("实名提交没有发出") { backend.calls == 1 }
        fixture.store.failReads(fromNth: 1)
        backend.release()
        await waitUntil("提交结果没有到达") { controller.deferral.isPending }
        fixture.store.stopFailing()
        let held = controller.state
        // FU-IOS-0713 起口径（RW-03 / F-X-22）：结果已到等身份确认时不再要求「提交中」转圈，只要求提交仍锁住
        XCTAssertFalse(controller.submitEnabled, "身份未知：不采用，提交仍锁住")
        XCTAssertNil(held.done)
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.realName, "身份未知：不出栈")
        fixture.wallet.checkSession()
        // 采用成功结果：完成后出栈回发起页
        await waitUntil("确认后结果没有采用") { fixture.router.path.last?.route != WalletRoutes.realName }
        let calls = backend.calls
        XCTAssertEqual(calls, 1, "不重放提交")
    }

    /// 提现提交结果回来时身份暂时未知 → 不采用（不进记录页）；身份确认后采用，按成功进提现记录。
    func testReworkWithdrawSubmitResultWhileUnknownAppliesAfterConfirmation() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        script.on("POST /v1/withdrawals", .hold)
        actions(controller).submit()
        await waitUntil("提交没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        fixture.store.failReads(fromNth: 1)
        WalletStubProtocol.release(
            held, with: .envelope(code: 0, data: WalletSamples.withdrawal("W-new"), headers: [:])
        )
        await waitUntil("提交结果没有到达") { controller.flow.deferral.isPending }
        fixture.store.stopFailing()
        let route = fixture.router.path.last?.route
        XCTAssertEqual(route, WalletRoutes.withdraw, "身份未知：不采用")
        fixture.wallet.checkSession()
        await waitUntil("确认后没有进提现记录") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        XCTAssertEqual(posts.count, 1, "不重放提交")
    }

    // MARK: - 换代判据、F-X-21

    /// 首次确认没有会话（初始化身份未知、之后确认令牌已不在）：按换代处理——共享禁用期重置，判据记为「没有会话」。
    func testReworkWalletFirstConfirmedNoSessionResetsGates() throws {
        let fixture = WalletAppFixture.make(suiteName: suiteName, defaults: defaults, unknownIdentityAtInit: true)
        XCTAssertEqual(fixture.wallet.sessionKey, "", "前提：初始化身份未知")
        try fixture.tokens.clear()
        fixture.wallet.gates.read.start(60000)
        fixture.wallet.checkSession()
        let active = fixture.wallet.gates.read.active
        XCTAssertFalse(active, "共享禁用期重置")
        XCTAssertTrue(fixture.wallet.sessionKey.hasPrefix("-#"), "判据记为确认没有会话")
    }

    /// 缺持久化登录世代的合法旧会话：钱包在线可用（摘要加载出来），摘要缓存不读不写。
    func testReworkWalletLegacySessionLoadsOnlineWithoutCache() async throws {
        let fixture = make()
        try fixture.tokens.save(access: "at", refresh: "rt", scope: "full", account: "user-a", loginEpoch: nil)
        fixture.wallet.checkSession()
        let controller = try XCTUnwrap(fixture.open(WalletRoutes.wallet)?.controller as? WalletController)
        XCTAssertNil(controller.state.owner.loginEpoch, "前提：缺世代")
        controller.load()
        await waitUntil("在线摘要没有到位") { controller.state.summary != nil }
        let root = fixture.cleaner.store.root
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 != "pending_clear" }
        XCTAssertEqual(entries, [], "不写摘要缓存")
        XCTAssertNil(fixture.cleaner.store.read(account: "user-a", loginEpoch: nil))
    }

    /// 未知期间构造的各资金页上点【重试】/ 下拉：请 App 立即核对一次，身份已恢复就同一页换上身份并加载。
    func testReworkRetryOnUnknownBuiltFundPagesRechecksIdentity() async throws {
        let fixture = make()
        fixture.wallet.installBackends(realname: nil, labor: FixtureLabor())
        await verifyRealname(fixture)
        let routes = [
            WalletRoutes.wallet, WalletRoutes.withdrawRecords, WalletRoutes.payoutAccount, WalletRoutes.withdraw,
            WalletRoutes.laborAgreement,
        ]
        for route in routes {
            let entry = try openWhileUnknown(fixture, route)
            switch entry.controller {
            case let page as WalletController:
                page.refresh()
            case let page as WithdrawRecordsController:
                page.refresh()
            case let page as PayoutAccountController:
                page.retry()
            case let page as WithdrawController:
                page.retry()
            case let page as LaborAgreementController:
                page.retry()
            default:
                XCTFail("\(route) 没有页面")
            }
            let rebound = entry.identityKnown
            XCTAssertTrue(rebound, "\(route)：重试触发核对、同一页换上身份")
            fixture.router.path.removeAll()
        }
    }
}

/// 挂住的实名后端：收到提交后等测试放行再回成功。
final class GateRealName: RealNameBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    var calls: Int {
        lock.withLock { count }
    }

    func release() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume()
    }

    func submit(name _: String, idNo _: String, idempotencyKey _: String,
                owner _: RequestOwnership?) async -> ApiResult {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                count += 1
                if released {
                    return true
                }
                waiter = continuation
                return false
            }
            if ready {
                continuation.resume()
            }
        }
        return .success(data: Data("{}".utf8), traceId: nil, idempotencyKey: nil)
    }
}
