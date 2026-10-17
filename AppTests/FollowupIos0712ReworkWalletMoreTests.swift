@testable import Couli
import CouliNetwork
import Foundation
import OrderCore
import Router
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-0712 整体重理（钱包与资金页，续）：翻页、写请求结果、待确认记录、建页快照、撤回 / 切环境与待清理。
final class FollowupIos0712ReworkWalletMoreTests: WalletFlowTestCase {
    private static func list(_ id: String, cursor: String?) -> WalletStubProtocol.Reply {
        let next = cursor.map { "\"\($0)\"" } ?? "null"
        return .envelope(
            code: 0, data: "{\"items\":[\(WalletSamples.withdrawal(id))],\"next_cursor\":\(next)}", headers: [:]
        )
    }

    /// 提现记录翻页：响应回来时身份核对读失败 → 不采用、翻页在途标记复位、记待补做；身份确认后再翻这一页。
    func testReworkRecordsLoadMoreAbortedResumesNextPage() async throws {
        let fixture = make()
        script.on("GET /v1/withdrawals", Self.list("W1", cursor: "p1"), .hold)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.withdrawRecords))
        let controller = try XCTUnwrap(entry.controller as? WithdrawRecordsController)
        controller.load()
        await waitUntil("第一页没有到位") { controller.state.phase == .content && !controller.firstPagePending }
        controller.loadMore()
        await waitUntil("翻页没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        fixture.store.failReads(fromNth: 1)
        WalletStubProtocol.release(held, with: Self.list("W2", cursor: nil))
        await waitUntil("翻页响应核对没有结算") { controller.loadPending }
        fixture.store.stopFailing()
        let aborted = controller.state
        XCTAssertFalse(aborted.loadingMore, "翻页在途标记复位")
        XCTAssertEqual(aborted.items.map(\.withdrawalId), ["W1"], "核对失败的翻页不采用")
        script.on("GET /v1/withdrawals", Self.list("W2", cursor: nil))
        fixture.wallet.checkSession()
        await waitUntil("补做后第二页没有到位") { controller.state.items.count == 2 }
        let items = controller.state.items.map(\.withdrawalId)
        XCTAssertEqual(items, ["W1", "W2"])
    }

    /// 劳务协议签署结果回来时身份暂时未知 → 不采用（签署中保持、不出栈）；身份确认后采用，签署成功出栈，不重放签署。
    func testReworkLaborSignResultWhileUnknownAppliesAfterConfirmation() async throws {
        let fixture = make()
        let backend = GateLabor()
        fixture.wallet.installBackends(realname: nil, labor: backend)
        await verifyRealname(fixture)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.laborAgreement), "劳务协议页没有打开")
        let controller = try XCTUnwrap(entry.controller as? LaborAgreementController)
        controller.load()
        await waitUntil("协议没有到位") { controller.state.phase == .content }
        let owner = controller.state.owner
        controller.toggle(owner: owner)
        controller.sign(owner: owner)
        await waitUntil("签署没有发出") { backend.signs == 1 }
        fixture.store.failReads(fromNth: 1)
        backend.release()
        await waitUntil("签署结果没有到达") { controller.deferral.isPending }
        fixture.store.stopFailing()
        // FU-IOS-0713 起口径（RW-03 / F-X-22）：结果已到等身份确认时不再要求「签署中」转圈，只要求签署仍锁住
        let locked = !controller.signEnabled
        XCTAssertTrue(locked, "身份未知：不采用，签署仍锁住")
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.laborAgreement, "不出栈")
        fixture.wallet.checkSession()
        await waitUntil("确认后签署结果没有采用") { fixture.router.path.last?.route != WalletRoutes.laborAgreement }
        XCTAssertEqual(backend.signs, 1, "不重放签署")
    }

    /// 待确认：【确认上一笔】的结果回来时身份暂时未知 → 不采用；身份确认后采用，按成功进提现记录；待确认记录读取在身份未知时也记待补做。
    func testReworkPendingConfirmAndRefreshWhileUnknownResumeOnConfirmation() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        fixture.store.failRead(nth: 1)
        controller.flow.refreshPending()
        XCTAssertTrue(controller.flow.deferral.isPending("pending"), "待确认记录读取：记待补做")
        script.on("POST /v1/withdrawals", .hold)
        fixture.wallet.checkSession()
        let refreshed = controller.flow.deferral.isPending("pending")
        XCTAssertFalse(refreshed, "身份确认后重读")
        flowActions(controller.flow).confirm()
        await waitUntil("确认没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        fixture.store.failReads(fromNth: 1)
        WalletStubProtocol.release(
            held, with: .envelope(code: 0, data: WalletSamples.withdrawal("W-confirm"), headers: [:])
        )
        await waitUntil("确认结果没有到达") { controller.flow.deferral.isPending("pendingCall") }
        fixture.store.stopFailing()
        let route = fixture.router.path.last?.route
        XCTAssertEqual(route, WalletRoutes.withdraw, "身份未知：不采用")
        fixture.wallet.checkSession()
        await waitUntil("确认后没有进提现记录") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
    }

    /// 建页只取一次身份快照：执行器的固定身份就是页面记下的那一份（建页之后的读取失败不落到执行器里）。
    func testReworkWalletEntryBuildUsesOneSnapshot() throws {
        let fixture = make()
        script.on("GET /v1/wallet/summary", .hold)
        fixture.router.open(RouteRequest(route: WalletRoutes.wallet, from: .inApp))
        let top = try XCTUnwrap(fixture.router.path.last)
        // entry：判据核对（第 1 次）→ 建页快照（第 2 次）；第 3 次读取失败不应落到执行器的固定身份里
        fixture.store.failRead(nth: 3)
        let entry = try XCTUnwrap(fixture.wallet.entry(for: top))
        let controller = try XCTUnwrap(entry.controller as? WalletController)
        XCTAssertEqual(controller.state.owner, entry.owner, "执行器与页面同一次快照")
        XCTAssertTrue(entry.identityKnown)
    }

    /// 身份暂时未知、会话世代已变（禁读屏障）：只作废内存——共享禁用期重置、各页换成未确认身份；不更新判据。
    func testReworkWalletUnknownWithGenerationChangeOnlyInvalidatesMemory() throws {
        let fixture = make()
        script.on("GET /v1/wallet/summary", .hold)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.wallet))
        let key = fixture.wallet.sessionKey
        fixture.wallet.gates.read.start(60000)
        fixture.network.client.raiseWithdrawalReadBarriers()
        fixture.wallet.checkSession()
        let known = entry.identityKnown
        XCTAssertFalse(known, "页面换成未确认身份")
        XCTAssertFalse(fixture.wallet.gates.read.active, "共享禁用期重置")
        XCTAssertEqual(fixture.wallet.sessionKey, key, "判据不更新")
    }

    /// 撤回 / 切环境的清理回调按此刻快照重建后，判据随之记下：之后同样未知的核对不再重复重建页面。
    func testReworkWalletCacheClearedAdoptsSnapshotSoNextCheckDefers() throws {
        let fixture = make()
        script.on("GET /v1/wallet/summary", .hold)
        let controller = try XCTUnwrap(fixture.open(WalletRoutes.wallet)?.controller as? WalletController)
        fixture.network.client.raiseWithdrawalReadBarriers()
        try? fixture.cleaner.cleanForEnvironmentSwitch()
        let version = controller.state.version
        fixture.wallet.checkSession()
        let after = controller.state.version
        XCTAssertEqual(after, version, "已按此刻快照重建：不再重复重建")
    }

    /// 已登记的待清理与身份无关：会话中途身份暂时未知时，核对照样先完成清理。
    func testReworkWalletCheckSessionCompletesPendingClearWhileUnknown() {
        let fixture = make()
        let root = fixture.cleaner.store.root
        XCTAssertTrue(OrderSiblingPendingFlag(root: root).set(), "前提：持久待清理标记")
        fixture.store.failRead(nth: 1)
        fixture.wallet.checkSession()
        let pending = fixture.cleaner.store.isPendingClear
        XCTAssertFalse(pending, "待清理已完成")
    }
}

/// 挂住签署的劳务协议后端：协议读取立即成功，签署等测试放行再回成功。
final class GateLabor: LaborBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    var signs: Int {
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

    func current(owner _: RequestOwnership?) async -> ApiResult {
        .success(
            data: Data("{\"version\":\"v1\",\"text\":\"fixture\",\"text_sha256\":\"abc\",\"need_sign\":true}".utf8),
            traceId: nil, idempotencyKey: nil
        )
    }

    func sign(version _: String, textSha256 _: String, owner _: RequestOwnership?) async -> ApiResult {
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
