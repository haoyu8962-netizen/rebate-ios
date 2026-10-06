import Foundation
import Generated
import Session

/// 一次刷新窗口的完整结果。窗口结算时定下、不再改变，直接交给该窗口的每个等待者（lessons 36）。
enum RefreshOutcome: Equatable, Sendable {
    /// 刷新成功（或本世代的令牌已被换掉）：新的 access_token。
    case refreshed(String)
    /// 暂时失败（超时、断连、没有外壳、刷新请求没能发出）：会话保留，等待者按网络错误结束，不带旧令牌发出。
    case transient(String)
    /// 刷新被拒（或新令牌保存失败）：本世代会话已清；带的是那次结算定下的会话 Effect（session_cleared）。
    case cleared(ErrorEffect)
    /// 会话已换代（退出、换账号、重新登录、撤回同意、切换环境）：结束旧调用，不动当前会话。
    case superseded
}

/// 一个刷新窗口：只属于一个会话世代。账号、作废世代与 refresh_token 在入队的那把锁里固定（lessons 24），
/// 执行与结算都以它为准。等待者只在 `ApiClient.lock` 里增删。
final class RefreshWindow: @unchecked Sendable {
    let generation: UInt64
    let epoch: UInt64
    let refreshToken: String
    let account: String?
    var waiters: [CheckedContinuation<RefreshOutcome, Never>] = []
    /// 受限会话屏障在本窗口上等待时的屏障编号（在 `ApiClient.lock` 里写入）：窗口刷新成功即结算该屏障（R3-01）。
    var barrierSerial: UInt64?

    init(generation: UInt64, epoch: UInt64, refreshToken: String, account: String?) {
        self.generation = generation
        self.epoch = epoch
        self.refreshToken = refreshToken
        self.account = account
    }
}

/// 一次已通过的受限会话屏障：会话世代 + 屏障编号（R3-01）。
struct RestrictedBarrierMark: Equatable {
    let generation: UInt64
    let serial: UInt64
}

/// 令牌单飞刷新（按会话世代隔离的窗口）、受限会话屏障、登录响应的令牌保存。
extension ApiClient {
    // MARK: - 刷新窗口

    private enum Admission {
        /// 不用等：直接给结果（emit = 本次顺带清了会话、要发的 Effect；retry = 删除失败要重试）。
        case now(RefreshOutcome, emit: ErrorEffect?, retry: Bool)
        case joined
        case start(RefreshWindow)
    }

    /// 刷新请求一次的结果（解包后、结算前）。
    private enum RefreshAttempt {
        case tokens(access: String, refresh: String, scope: String)
        case rejected
        case transient(String)
        case superseded
    }

    /// 等本世代的刷新结果（10002、10405 refresh_only、受限会话屏障共用）。世代核对、复用已定结果、选窗口与入队在
    /// 同一把锁里完成：
    /// - 调用绑定的世代已不是当前世代：该世代因刷新失败被清 → 复用那次失败（session_cleared，不再清会话、不再发
    ///   Effect）；否则 superseded（用户换了会话，或作废）。
    /// - 本次用的令牌已被同一世代的刷新换掉 → 直接用当前令牌。
    /// - 同一世代已有进行中的窗口 → 并入；否则以此刻的会话快照开一个新窗口。
    func joinRefresh(generation bound: UInt64, usedToken: String?) async -> RefreshOutcome {
        await awaitRefresh { admitLocked(bound, usedToken, $0) } ?? .superseded
    }

    /// 在一把锁里调用 `admit`（判定、取快照、入队）并等结果；`admit` 返回 nil 表示不需要刷新，此时返回 nil。
    private func awaitRefresh(
        _ admit: (CheckedContinuation<RefreshOutcome, Never>) -> Admission?
    ) async -> RefreshOutcome? {
        var emit: ErrorEffect?
        var retry = false
        var skipped = false
        let outcome: RefreshOutcome = await withCheckedContinuation { continuation in
            guard let admission = lock.withLock({ admit(continuation) }) else {
                skipped = true
                continuation.resume(returning: .superseded)
                return
            }
            switch admission {
            case let .now(result, effect, needsRetry):
                emit = effect
                retry = needsRetry
                continuation.resume(returning: result)
            case .joined:
                break
            case let .start(window):
                Task { await self.runRefreshWindow(window) }
            }
        }
        if retry {
            scheduleRevokedRetry()
        }
        if let emit {
            await hooks.onEffect(emit)
        }
        return skipped ? nil : outcome
    }

    /// 调用方持有 `lock`。
    private func admitLocked(
        _ bound: UInt64,
        _ usedToken: String?,
        _ continuation: CheckedContinuation<RefreshOutcome, Never>
    ) -> Admission {
        guard bound == generation else {
            return .now(refreshFailures[bound].map { .cleared($0) } ?? .superseded, emit: nil, retry: false)
        }
        let read = readSessionLocked()
        if read == .unreadable {
            // 会话读不出（可能还在）：不刷新、不清会话，原调用按网络错误结束（R2-01）。
            return .now(.transient(LocalRejectReason.sessionUnreadable), emit: nil, retry: false)
        }
        let live = read.live
        if let current = live?.access, current != usedToken {
            return .now(.refreshed(current), emit: nil, retry: false)
        }
        if let window = refreshWindows[bound] {
            window.waiters.append(continuation)
            return .joined
        }
        guard let refresh = live?.refresh, !refresh.isEmpty else {
            // 本世代已没有可刷新的会话（存储里只剩不完整的条目）：按刷新失败清一次，结果记在本世代上。
            let needsRetry = clearSessionLocked()
            let effect = sessionLostEffectLocked()
            recordRefreshFailureLocked(bound, effect)
            return .now(.cleared(effect), emit: effect, retry: needsRetry)
        }
        let window = RefreshWindow(generation: bound, epoch: epoch, refreshToken: refresh, account: live?.account)
        window.waiters.append(continuation)
        refreshWindows[bound] = window
        refreshCount += 1
        return .start(window)
    }

    /// 刷新收尾（三端同序，在同一个完成流程里依次做完）：保存或清除会话 → 定下结果 → 解除窗口 → 结算全部等待者 →
    /// 发出会话 Effect（每个窗口只发一次）。保存 / 清除、定结果与摘下窗口在同一把锁里：之后到达的本世代请求要么已经
    /// 并入（随本结果结算），要么看到已换代并复用本结果，不会带着旧令牌先发出去。
    private func runRefreshWindow(_ window: RefreshWindow) async {
        let attempt = await performRefresh(window)
        // 结算前再读一次状态：失败时按结算那一刻的强更状态定 Effect（lessons 20）。
        _ = await readContext()
        let settled = lock.withLock { settleWindowLocked(window, attempt) }
        for waiter in settled.waiters {
            waiter.resume(returning: settled.outcome)
        }
        if settled.retry {
            scheduleRevokedRetry()
        }
        if let emit = settled.emit {
            await hooks.onEffect(emit)
        }
        if settled.enterForceUpdate {
            await hooks.onForceUpdate(nil)
        }
    }

    /// 一个窗口的结算：定下的结果、要结算的等待者、要发的会话 Effect 与后续动作。
    private struct WindowSettlement {
        var outcome = RefreshOutcome.superseded
        var waiters: [CheckedContinuation<RefreshOutcome, Never>] = []
        var emit: ErrorEffect?
        var retry = false
        var enterForceUpdate = false
    }

    /// 调用方持有 `lock`。保存或清除会话、定结果、摘下窗口。
    private func settleWindowLocked(_ window: RefreshWindow, _ attempt: RefreshAttempt) -> WindowSettlement {
        var settled = WindowSettlement()
        if refreshWindows[window.generation] === window {
            refreshWindows[window.generation] = nil
        }
        settled.waiters = window.waiters
        window.waiters.removeAll()
        guard epoch == window.epoch, generation == window.generation else {
            // 刷新期间会话已换代：结果丢弃，不恢复、不清新会话。
            settled.outcome = refreshFailures[window.generation].map { .cleared($0) } ?? .superseded
            return settled
        }
        switch attempt {
        case let .tokens(access, refresh, scope):
            do {
                try tokens.save(access: access, refresh: refresh, scope: scope, account: window.account)
                settled.outcome = .refreshed(access)
                // 屏障在本窗口上等待且其间没有重新挂上新屏障：在这把锁里结算该屏障（会话世代 + 编号），
                // 不由各等待者醒来后各自清标记（R3-01）。
                if let serial = window.barrierSerial, serial == restrictedBarrierSerial {
                    passRestrictedBarrierLocked()
                }
                // 强更检查未知期间拿到 deletion_only：按「低于」处理（lessons 28，以此刻的强更状态为准）。
                settled.enterForceUpdate = scope == SessionScope.deletionOnly && lastUpdateSeen == UpdateRaw.unknown
                return settled
            } catch {
                // 服务端已轮换令牌而本机存不下：会话无法继续，按刷新失败清掉。
                break
            }
        case .rejected:
            break
        case let .transient(kind):
            settled.outcome = .transient(kind)
            return settled
        case .superseded:
            return settled
        }
        settled.retry = clearSessionLocked()
        let effect = sessionLostEffectLocked()
        recordRefreshFailureLocked(window.generation, effect)
        settled.outcome = .cleared(effect)
        settled.emit = effect
        return settled
    }

    /// `POST /v1/auth/refresh`（不经过 ErrorActionMapper），只用窗口快照里的 refresh_token。不会抛错。
    /// 收到 10401 且响应头 Date 可校时（偏差超过 300 秒）时，校时后用新的 X-Timestamp、X-Nonce 重签再发 1 次
    /// （BR-ID-09；同一窗口的账号、世代与请求体不变，续发前重新校验状态）（R2-04）。
    private func performRefresh(_ window: RefreshWindow) async -> RefreshAttempt {
        guard let operation = ApiOperations.byId(Self.refreshOperation) else {
            return .rejected
        }
        guard let body = (try? JSONSerialization.data(withJSONObject: ["refresh_token": window.refreshToken]))
            .flatMap({ String(data: $0, encoding: .utf8) })
        else {
            return .rejected
        }
        var resigned = false
        while true {
            let outcome: TransportOutcome
            switch await sendRefreshOnce(window, operation, body) {
            case let .finished(attempt):
                return attempt
            case let .sent(value):
                outcome = value
            }
            guard case let .response(_, headers, data) = outcome, let envelope = Envelope.parse(data) else {
                if case let .failure(kind) = outcome, kind == HttpTransport.kindCancelled {
                    return .superseded
                }
                return .transient(Self.transportKind(outcome))
            }
            if envelope.code == Self.invalidSignatureCode, !resigned, operation.signed, correctClock(headers) {
                resigned = true
                continue
            }
            // 刷新接口的令牌在 data（TokenPairResponse）。
            guard envelope.code == 0, let pair = envelope.data as? [String: Any],
                  let access = JSONFields.string(pair, "access_token"), !access.isEmpty,
                  let refresh = JSONFields.string(pair, "refresh_token"), !refresh.isEmpty,
                  let scope = JSONFields.string(pair, "session_scope"), !scope.isEmpty
            else {
                return .rejected
            }
            return .tokens(access: access, refresh: refresh, scope: scope)
        }
    }

    private enum RefreshSend {
        case finished(RefreshAttempt)
        case sent(TransportOutcome)
    }

    /// 刷新请求发一次：每次（含校时重签）都重新取状态、核对作废世代与会话世代、重新组头签名。
    private func sendRefreshOnce(_ window: RefreshWindow, _ operation: ApiOperation,
                                 _ body: String) async -> RefreshSend {
        let state = await readContext()
        guard isCurrent(window.epoch), state.privacy == PrivacyRaw.full, state.credentialsReadable else {
            return .finished(.superseded)
        }
        let ready: Ready
        switch prepare(ApiCall(operationId: Self.refreshOperation, body: body), operation, state) {
        case let .rejected(reason):
            // 刷新请求本地发不出去（设备未注册等）：不是服务端拒绝，不清会话。
            return .finished(.transient(reason))
        case let .ready(value):
            ready = value
        }
        guard ready.generation == window.generation else {
            return .finished(.superseded)
        }
        let outcome = await transport.send(
            ready.request, timeoutMillis: RetryPolicy.forOperation(operation).timeoutMillis
        ) { [weak self] in
            guard let self else {
                return false
            }
            return isCurrent(window.epoch) && currentGeneration == window.generation
        }
        return .sent(outcome)
    }

    static func transportKind(_ outcome: TransportOutcome) -> String {
        if case let .failure(kind) = outcome {
            return kind
        }
        return HttpTransport.kindNoEnvelope
    }

    /// 调用方持有 `lock`。记下「这一代因刷新失败被清」（只留最近几代）。
    private func recordRefreshFailureLocked(_ value: UInt64, _ effect: ErrorEffect) {
        refreshFailures[value] = effect
        while refreshFailures.count > Self.refreshFailureMemory, let oldest = refreshFailures.keys.min() {
            refreshFailures[oldest] = nil
        }
    }

    /// 调用方持有 `lock`。会话丢失（刷新失败）的 Effect：以最近读到的强更状态为准（结算前刚读过）。
    func sessionLostEffectLocked() -> ErrorEffect {
        lastUpdateSeen == UpdateRaw.below
            ? ErrorEffect(code: 10002, kind: .clearSessionStayForceUpdate, route: "ForceUpdate")
            : ErrorEffect(code: 10002, kind: .clearSessionLogin, route: "Login")
    }

    // MARK: - 受限会话屏障

    /// 强更恢复通知触发的主动刷新（不依附任何请求）。失败时同样发出会话 Effect（由窗口发一次）。
    func refreshRestrictedSessionNow() async {
        let state = await readContext()
        var options = RunOptions(epoch: currentEpoch)
        bindOwnership(state, &options)
        _ = await restrictedBarrier(state, authenticated: true, options)
    }

    /// 受限会话屏障（BR-ID-01 细则「受限会话」）：进程启动或强更恢复为受支持后，存储的会话是 deletion_only 时，
    /// 带令牌的请求先等一次单飞刷新。按窗口的完整结果结算（lessons 31）：被拒清会话、结束原调用（session_cleared，
    /// 跳登录 / 停在强更页）；超时或暂时失败不清会话、屏障保留，原调用按网络错误结束，不带旧受限令牌发出；
    /// 会话已换代的按 session_changed 结束。
    func restrictedBarrierIfNeeded(
        _ state: NetworkContext,
        _ operation: ApiOperation,
        _ options: RunOptions
    ) async -> ApiResult? {
        await restrictedBarrier(state, authenticated: operation.auth != "none", options)
    }

    private func restrictedBarrier(
        _ state: NetworkContext,
        authenticated: Bool,
        _ options: RunOptions
    ) async -> ApiResult? {
        guard authenticated, let bound = options.boundGeneration else {
            return nil
        }
        // 屏障判定、会话快照与刷新入队在同一把锁里（R3-01）：屏障一旦在某个窗口结算，之后的调用读到的就是已通过。
        let outcome = await awaitRefresh { barrierAdmitLocked(state, bound, $0) }
        switch outcome {
        case nil, .refreshed:
            return nil
        case let .transient(kind):
            // 暂时失败：屏障保留（下一次带令牌的请求再刷新），本次调用按网络错误结束。
            return .transportFailure(kind: kind, httpStatus: nil, idempotencyKey: nil, pendingKeyUnknown: false)
        case let .cleared(effect):
            return .sessionCleared(effect: effect)
        case .superseded:
            return .localReject(reason: supersededReason(options))
        }
    }

    /// 调用方持有 `lock`。屏障判定 → 取会话快照 → 并入或开刷新窗口；不需要刷新时返回 nil。
    private func barrierAdmitLocked(
        _ state: NetworkContext,
        _ bound: UInt64,
        _ continuation: CheckedContinuation<RefreshOutcome, Never>
    ) -> Admission? {
        // 冷启动的屏障不看强更状态（below 也先刷新）；恢复触发的只在不低于时执行（R2-03）。本世代已通过的编号直接复用。
        let serial = restrictedBarrierSerial
        let due = coldStartRefreshDue || (recoveryRefreshDue && state.update != UpdateRaw.below)
        guard due, restrictedBarrierPassed != RestrictedBarrierMark(generation: generation, serial: serial),
              state.privacy == PrivacyRaw.full, state.credentialsReadable,
              let live = readSessionLocked().live, let access = live.access
        else {
            return nil
        }
        guard live.scope == SessionScope.deletionOnly, live.refresh != nil else {
            passRestrictedBarrierLocked()
            return nil
        }
        let admission = admitLocked(bound, access, continuation)
        if case .now = admission {} else {
            refreshWindows[bound]?.barrierSerial = serial
        }
        return admission
    }

    /// 调用方持有 `lock`。恢复为受支持：挂上新一轮屏障（新编号）。
    func armRecoveryBarrierLocked() {
        recoveryRefreshDue = true
        restrictedBarrierSerial &+= 1
    }

    /// 调用方持有 `lock`。当前编号的受限会话屏障已过（刷新成功或存储的会话不是受限的）：按会话世代 + 编号记下结果。
    private func passRestrictedBarrierLocked() {
        restrictedBarrierPassed = RestrictedBarrierMark(generation: generation, serial: restrictedBarrierSerial)
        coldStartRefreshDue = false
        recoveryRefreshDue = false
    }
}
