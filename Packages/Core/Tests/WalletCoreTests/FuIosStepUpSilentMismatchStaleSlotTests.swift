import CouliNetwork
import Foundation
import OrderCore
@testable import WalletCore
import XCTest

// FU-IOS-STEPUP-SILENT-MISMATCH / D10-1792：身份核对不过（stale）时发码落到发送失败态、槽位只按本次 ticket 释放。
// ③a（打开即 stale）在 FuIosStepUpSilentMismatchTests 里，共用这里的槽位、身份与断言。

/// 账号 user-a、号码 13800005678、提现 action 的发码槽位；`staleSlotOwner` 各代身份都落在这一个槽位上。
@MainActor let staleSlot =
    SmsDeadlines.Slot(account: "user-a", phone: "13800005678", action: WithdrawController.action)

func staleSlotOwner(generation: UInt64) -> WalletOwner {
    WalletOwner(
        account: "user-a", key: "user-a#\(generation)#0#0",
        request: RequestOwnership(account: "user-a", generation: generation, epoch: 0), loginEpoch: "login-a"
    )
}

/// 身份核对不过后的发送失败态：可输入（不停在 sending）、sendFailed、不等身份、`sendFailedKey`、不起倒计时。
@MainActor
func assertStaleSendFailed(
    _ panel: StepUpController, _ label: String, file: StaticString = #filePath, line: UInt = #line
) throws {
    let state = try XCTUnwrap(panel.state, "\(label)：没换代清空：面板不收起", file: file, line: line)
    XCTAssertEqual(state.phase, .ready, "\(label)：落到可输入，不停在 sending", file: file, line: line)
    XCTAssertTrue(state.sendFailed, "\(label)：sendFailed", file: file, line: line)
    XCTAssertFalse(state.awaitingIdentity, "\(label)：stale 不进等身份", file: file, line: line)
    XCTAssertEqual(state.error?.key, StepUpController.sendFailedKey, "\(label)：发送失败提示", file: file, line: line)
    XCTAssertEqual(state.resendLeftSec, 0, "\(label)：不起倒计时", file: file, line: line)
}

/// 落定后 `condition` 须在 `seconds` 内一直成立（每拍先让出主线程再看）：倒计时、发码任务下一拍才写入，单拍的否定断言不稳。
@MainActor
func stepUpHolds(
    _ message: String, seconds: TimeInterval = 0.3, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        await Task.yield()
        guard condition() else {
            XCTFail(message, file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    } while Date() < deadline
}

/// 可切换当前身份的替身环境：`check` 走协议缺省（不是 `current` 即 .stale）；槽位键 13800005678、phone_bound 未知、时钟固定。
@MainActor
private final class StaleSwitchEnv: WalletEnv {
    let now: Int64 = 1_760_000_000_000
    var current: WalletOwner
    let appVersion = "1.0.0"
    let earningsSince: String? = nil

    init(current: WalletOwner) {
        self.current = current
    }

    func currentOwner() -> WalletOwner {
        current
    }

    func isCurrent(_ owner: WalletOwner) -> Bool {
        owner == current
    }

    func configText(_: String) -> String? {
        nil
    }

    func helpLinks() -> [String: Any]? {
        nil
    }

    func earningsFlag() -> Bool? {
        nil
    }

    func replace(page _: UUID, route _: String, params _: [String: String]) -> Bool {
        false
    }

    func close(page _: UUID) -> Bool {
        false
    }

    func payoutSaved(page _: UUID) -> Bool {
        false
    }

    func copy(_: String) -> Bool {
        false
    }

    func stepUpPhone(account _: String) -> String? {
        "13800005678"
    }

    func markWalletDirty(_: WalletOwner) {}
    func realnameChanged() {}
    func sensitiveOverlay(_: Bool) {}
    func contactService(from _: String) {}
    func open(_: String, params _: [String: String], from _: UUID?) {}

    func nowMillis() -> Int64 {
        now
    }

    func displayNowMillis() -> Int64 {
        now
    }
}

/// 发码一律挂起、由测试按到达顺序放行的替身 API（只计数，不发任何请求）。
private final class HoldingSmsApi: WalletApi, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiting: [CheckedContinuation<ApiResult, Never>] = []

    var sent: Int {
        lock.withLock { count }
    }

    var held: Int {
        lock.withLock { waiting.count }
    }

    func release(_ result: ApiResult) {
        let next: CheckedContinuation<ApiResult, Never>? = lock.withLock {
            waiting.isEmpty ? nil : waiting.removeFirst()
        }
        next?.resume(returning: result)
    }

    func send(
        _: ApiCall, isValid _: @escaping @Sendable () -> Bool, sendAllowed _: @escaping @Sendable () -> Bool,
        expected _: RequestOwnership?
    ) async -> ApiResult {
        await withCheckedContinuation { continuation in
            lock.withLock {
                count += 1
                waiting.append(continuation)
            }
        }
    }

    func confirmPending(operationId _: String, stepUpToken _: String?, target _: PendingTarget) async -> ApiResult {
        .localReject(reason: LocalRejectReason.invalidCall)
    }

    func abandonPending(operationId _: String, target _: PendingTarget) async -> ApiResult {
        .localReject(reason: LocalRejectReason.invalidCall)
    }

    func pendingStatus(operationId _: String) async -> PendingLookup {
        .none
    }

    func restorePending() async {}
}

/// D10-1792 ②：stale 的发码只释放自己的 ticket。两个面板共用一份真实 WalletDeps（同一 SmsDeadlines 与结算）。
@MainActor
final class FuIosStepUpStaleSlotTests: XCTestCase {
    private let ownerA = staleSlotOwner(generation: 1)
    private let ownerB = staleSlotOwner(generation: 2)
    private var panels: [StepUpController] = []
    /// WalletDeps / WalletSettlement 对 env 是 unowned：env 与 api 由测试实例持有，活过面板与结算的全部异步收尾。
    private var kept: (StaleSwitchEnv, HoldingSmsApi)?

    override func tearDown() async throws {
        while let api = kept?.1, api.held > 0 {
            api.release(.localReject(reason: LocalRejectReason.invalidCall))
        }
        for panel in panels {
            panel.dismiss()
            await panel.whenIdle()
        }
        try await super.tearDown()
    }

    private func openPanel(_ deps: WalletDeps, _ owner: WalletOwner) -> StepUpController {
        let panel = StepUpController(deps: deps, alive: { true })
        panels.append(panel)
        panel.open(action: WithdrawController.action, owner: owner, onToken: { _ in }, onClosed: {})
        return panel
    }

    private static func sms(_ resendAfter: Int) -> ApiResult {
        StepUpPanelApi.ok("{\"resend_after_sec\":\(resendAfter),\"expires_in_sec\":300}")
    }

    /// 选定场景：`SmsDeadlines.acquire` 对同一槽位互斥（已有在途返回 nil，后来的面板只 awaitOther 等、不发），「A、B 同时各自在途」
    /// 在现有模型里不可达，改钉实际可达的时序：A 发码在途 → 当前身份换成 B（同槽位；A 此后 stale，换代清空还没到）→ B 打开只等不发 →
    /// A 结果回来判 stale：A 落发送失败态、只释放 A 的 ticket、不写截止时间 → B 结束等待、可输入、不自动再发 → B【重新获取】占槽位在途 →
    /// A 的迟到释放（同一 ticket 的结算再到一次、直接按 A 的 ticket release）与 A 点【重新获取】都不动 B 的占用 →
    /// B 结果回来按 B 的结果写共享截止时间、起倒计时。B 的这次发码也覆盖 ③a 的「身份恢复后【重新获取】照常发出」。
    func testStaleReleaseOnlyFreesOwnTicketAndKeepsLaterSlotHolder() async throws {
        let env = StaleSwitchEnv(current: ownerA)
        let api = HoldingSmsApi()
        kept = (env, api)
        let deps = WalletDeps(
            api: api, env: env, gates: WalletGates(clock: { 1_760_000_000_000 }), cache: nil,
            mask: AmountMaskStore(), realname: nil, labor: nil
        )
        let ticketA = try nextTicket(deps)
        let panelA = openPanel(deps, ownerA)
        await panelWait("A 没有发出") { api.held == 1 }
        XCTAssertTrue(deps.sms.busy(staleSlot), "前提：A 在途占用槽位")
        env.current = ownerB
        let panelB = openPanel(deps, ownerB)
        XCTAssertEqual(api.sent, 1, "B：同槽位已有在途，不再发")
        XCTAssertEqual(panelB.state?.phase, .sending, "B：等 A 结束")
        api.release(Self.sms(30))
        await panelWait("A 的 stale 结果没有落定") { panelA.state?.sendFailed == true }
        try assertStaleSendFailed(panelA, "A stale")
        XCTAssertFalse(deps.sms.busy(staleSlot), "A stale：释放了 A 自己的 ticket")
        XCTAssertFalse(deps.sms.awaitingIdentity(staleSlot), "A stale：槽位不进等身份")
        XCTAssertEqual(deps.sms.remaining(staleSlot, now: env.now), 0, "A stale：不读结果体、不写共享截止时间")
        await panelWait("B 没有结束等待") { panelB.state?.phase == .ready }
        let waitedB = try XCTUnwrap(panelB.state)
        XCTAssertFalse(waitedB.sendFailed, "B 身份是当前：不落发送失败")
        XCTAssertNil(waitedB.error)
        XCTAssertEqual(waitedB.resendLeftSec, 0, "A 没写截止时间：B 没有倒计时可恢复")
        XCTAssertEqual(api.sent, 1, "B 不自动再发")
        panelB.resend(instance: waitedB.instance)
        await panelWait("B【重新获取】没有发出") { api.held == 1 }
        try assertLateReleaseKeepsHolder(deps, env: env, panelA: panelA, panelB: panelB, ticketA: ticketA)
        XCTAssertEqual(api.sent, 2, "A 已 stale：A 的【重新获取】不受理")
        api.release(Self.sms(48))
        await panelWait("B 没有起倒计时") { panelB.state?.resendLeftSec == 48 }
        XCTAssertEqual(deps.sms.remaining(staleSlot, now: env.now), 48_000, "共享截止时间按 B 的结果写入")
        XCTAssertFalse(deps.sms.busy(staleSlot), "B 结束：释放 B 的 ticket（占用者一直是 B）")
        XCTAssertNil(panelB.state?.error)
        XCTAssertEqual(panelA.state?.resendLeftSec, 0, "A 仍是发送失败态，不跟着起倒计时")
    }

    /// B 在途时：A 的迟到释放（同一 ticket 的 stale 结算再到一次、直接按 A 的 ticket release）、A 点【重新获取】都不动 B 的占用。
    private func assertLateReleaseKeepsHolder(
        _ deps: WalletDeps, env: StaleSwitchEnv, panelA: StepUpController, panelB: StepUpController, ticketA: Int
    ) throws {
        let late = SmsArrival(slot: staleSlot, ticket: ticketA, result: Self.sms(30), arrived: env.now)
        deps.settlement.settleSms(late, owner: ownerA, sms: deps.sms, gate: deps.gates.sms)
        deps.sms.release(staleSlot, ticket: ticketA)
        XCTAssertTrue(deps.sms.busy(staleSlot), "A 的迟到释放不清掉 B 的占用")
        XCTAssertFalse(deps.sms.awaitingIdentity(staleSlot), "A 的迟到结算不把 B 的槽位挂成等身份")
        XCTAssertNil(deps.sms.acquire(staleSlot), "槽位仍被 B 占用（ticket 未被动）")
        XCTAssertEqual(deps.sms.remaining(staleSlot, now: env.now), 0, "A 的迟到结果不读、不写截止时间")
        XCTAssertEqual(panelB.state?.phase, .sending, "B 仍在发码中")
        let failedA = try XCTUnwrap(panelA.state)
        panelA.resend(instance: failedA.instance)
        try assertStaleSendFailed(panelA, "A 点【重新获取】后")
    }

    /// 下一次 acquire 会拿到的票据：在空槽位上连取两次探针（各自立即释放），核对票据逐次加 1 后推出下一张；探针不留占用。
    private func nextTicket(_ deps: WalletDeps) throws -> Int {
        let first = try XCTUnwrap(deps.sms.acquire(staleSlot), "前提：槽位空闲")
        deps.sms.release(staleSlot, ticket: first)
        let second = try XCTUnwrap(deps.sms.acquire(staleSlot), "前提：槽位空闲")
        deps.sms.release(staleSlot, ticket: second)
        XCTAssertEqual(second, first + 1, "前提：票据逐次加 1")
        XCTAssertFalse(deps.sms.busy(staleSlot), "前提：探针不留占用")
        return second + 1
    }

    /// D10-1792（otherSettled 判 stale，StepUpController+Send.swift `otherSettled` 的 stale 分支）：A 发码在途、B 同槽位打开并等待，
    /// 当前身份再换成第三者 C（A、B 都 stale）→ 放行 A 的结果：B 不再等、落到发送失败态，对 `sms.changes` 的订阅取消
    /// （监听数回到 B 打开前的基线）；之后再发一次 `sms.changes`，B 的状态（含错误编号）不变。
    func testWaitingPanelFallsToSendFailedWhenOtherSettlesWhileStale() async throws {
        let env = StaleSwitchEnv(current: ownerA)
        let api = HoldingSmsApi()
        kept = (env, api)
        let deps = WalletDeps(
            api: api, env: env, gates: WalletGates(clock: { 1_760_000_000_000 }), cache: nil,
            mask: AmountMaskStore(), realname: nil, labor: nil
        )
        let panelA = openPanel(deps, ownerA)
        await panelWait("A 没有发出") { api.held == 1 }
        let baseline = deps.sms.changes.listenerCount
        env.current = ownerB
        let panelB = openPanel(deps, ownerB)
        XCTAssertEqual(panelB.state?.phase, .sending, "前提：B 等 A 结束")
        XCTAssertEqual(deps.sms.changes.listenerCount, baseline + 1, "前提：B 订阅了槽位变化")
        env.current = staleSlotOwner(generation: 3)

        api.release(Self.sms(30))
        await panelWait("B 没有落定") { panelB.state?.sendFailed == true }
        try assertStaleSendFailed(panelB, "B 等待中 stale")
        try assertStaleSendFailed(panelA, "A stale")
        XCTAssertEqual(deps.sms.changes.listenerCount, baseline, "B 落定后取消对槽位变化的订阅")
        XCTAssertFalse(deps.sms.busy(staleSlot), "A stale：释放了 A 的 ticket")
        XCTAssertEqual(api.sent, 1, "B 不发码")
        let settled = try XCTUnwrap(panelB.state)
        deps.sms.changes.send(())
        await stepUpHolds("B 落定后不再响应槽位变化") { panelB.state == settled }
        XCTAssertEqual(api.sent, 1)
    }
}
