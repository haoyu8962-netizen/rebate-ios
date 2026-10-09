import Foundation
import Generated
import Session

/// 管线主体：一次逻辑调用 = 发送（含读接口重试）→ 解包 → 结算（重放、刷新、未决键、Effect）。
extension ApiClient {
    /// 发送阶段的结果：本地结束（拒绝或屏障失败），或已拿到一次传输结果。
    enum Attempted {
        case finished(ApiResult)
        case sent(Ready, TransportOutcome)
    }

    func run(_ call: ApiCall, _ operation: ApiOperation, isReplay: Bool, options start: RunOptions) async -> ApiResult {
        var options = start
        let ready: Ready
        let outcome: TransportOutcome
        switch await attempt(call, operation, &options) {
        case let .finished(result):
            return result
        case let .sent(sentReady, sentOutcome):
            ready = sentReady
            outcome = sentOutcome
        }
        guard case let .response(_, headers, body) = outcome, let envelope = Envelope.parse(body) else {
            return transportFailure(outcome, ready, options.held)
        }
        if envelope.code == 0 {
            if let held = options.held {
                pendingKeys.onResponse(
                    key: held.key, kind: PendingKeyStore.envelopeSuccess, account: held.account, callOwner: held.owner
                )
            }
            // 登录：会话保存成功才算登录成功（R1-11）。
            if case let .notSaved(reason) = await captureLogin(
                operation, envelope.data, epoch: options.epoch, generation: ready.generation, valid: options.callValid,
                saved: options.onSessionSaved
            ) {
                return .sessionNotSaved(reason: reason, traceId: envelope.traceId)
            }
            return .success(
                data: JSONFields.encode(envelope.data), traceId: envelope.traceId, idempotencyKey: ready.idempotencyKey
            )
        }
        // 失效桥调用的迟到 10401：不校时、不重签（APP-04 三端共性第 30 条，其余恢复分支见 `abandonsRecovery`）。
        if envelope.code == Self.invalidSignatureCode, !callStillValid(options) {
            settleHeld(options, kind: PendingKeyStore.envelopeKind(envelope.code))
            return .localReject(reason: LocalRejectReason.callCancelled)
        }
        // 10401 且时钟偏差超过 300 秒：校时、重签后沿用原键与原请求体再发 1 次（BR-ID-09）。校时重签不是重放原请求：
        // 用独立的一次性预算，不动 isReplay（之后的 10002 等仍可按前置动作重放一次，R2-05）。
        if envelope.code == Self.invalidSignatureCode, !options.resigned, operation.signed, correctClock(headers) {
            var resign = options
            resign.resigned = true
            return await run(withKey(call, ready.idempotencyKey), operation, isReplay: isReplay, options: resign)
        }
        let exchange = Exchange(call: call, operation: operation, isReplay: isReplay, options: options, ready: ready)
        return await errorResult(exchange, envelope, headers)
    }

    /// 本地拒绝：释放本次占用的未决键（出现过结果未知的恢复为 unknown，从未发出的新记录删除）。
    func rejected(_ reason: String, _ options: RunOptions) -> ApiResult {
        releaseHeld(options)
        return .localReject(reason: reason)
    }

    /// 释放这次调用持有的未决键占用（只对自己持有的生效）。
    func releaseHeld(_ options: RunOptions) {
        if let held = options.held {
            pendingKeys.release(key: held.key, account: held.account, callOwner: held.owner)
        }
    }

    /// 调用归属在任何屏障等待之前绑定（lessons 30）：有令牌时记下会话世代与账号；之后会话变了就结束旧调用。
    func bindOwnership(_ state: NetworkContext, _ options: inout RunOptions) {
        guard options.boundGeneration == nil, state.privacy == PrivacyRaw.full, state.credentialsReadable else {
            return
        }
        let (read, session) = lock.withLock { (readSessionLocked(), generation) }
        let live = read.live
        guard live?.access != nil else {
            return
        }
        options.boundGeneration = session
        if options.boundAccount == nil {
            options.boundAccount = live?.account.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// 每次实际发送前重新取状态、过屏障、重新校验与组头签名；读接口超时 / 断连按策略退避重试。
    func attempt(_ call: ApiCall, _ operation: ApiOperation, _ options: inout RunOptions) async -> Attempted {
        let retry = RetryPolicy.forOperation(operation)
        var retried = 0
        var admitted = false
        while true {
            guard stillValid(options) else {
                return .finished(rejected(LocalRejectReason.callCancelled, options))
            }
            let state = await readContext()
            bindOwnership(state, &options)
            if let failure = await restrictedBarrierIfNeeded(state, operation, options) {
                if case let .localReject(reason) = failure {
                    return .finished(rejected(reason, options))
                }
                releaseHeld(options)
                return .finished(failure)
            }
            guard stillValid(options) else {
                return .finished(rejected(LocalRejectReason.callCancelled, options))
            }
            let ready: Ready
            switch admit(call, operation, state, &options, admitted: &admitted) {
            case let .rejected(reason):
                return .finished(rejected(reason, options))
            case let .ready(value):
                ready = value
            }
            guard let outcome = await sendOnce(ready, timeoutMillis: retry.timeoutMillis, options) else {
                // 登记时就已作废、请求没有写出：按本地结束（call_cancelled），与「已写出、结果未知」分开（APP-05a 共性 22）。
                return .finished(rejected(LocalRejectReason.callCancelled, options))
            }
            if case let .failure(kind) = outcome,
               kind == HttpTransport.kindTimeout || kind == HttpTransport.kindDisconnect,
               retried < retry.autoRetries {
                retried += 1
                await sleeper(retry.backoffMillis)
                continue
            }
            if case let .response(status, headers, _) = outcome {
                Self.responseSink?.record(status: status, headers: headers)
            }
            return .sent(ready, outcome)
        }
    }

    /// 组头签名 → 会话世代与账号核对 → 四个 step-up 操作登记未决记录（落盘成功才发；写操作只发一次，只登记一次）。
    func admit(
        _ call: ApiCall,
        _ operation: ApiOperation,
        _ state: NetworkContext,
        _ options: inout RunOptions,
        admitted: inout Bool
    ) -> Prepared {
        let prepared = prepare(call, operation, state)
        guard case let .ready(ready) = prepared else {
            return prepared
        }
        // 会话世代：带过令牌的调用之后只在同一世代里重试、重放。
        if let bound = options.boundGeneration {
            guard ready.generation == bound else {
                return .rejected(LocalRejectReason.sessionChanged)
            }
        } else if ready.accessToken != nil {
            options.boundGeneration = ready.generation
        }
        // 带凭据发出时账号必须仍是绑定的那个；凭据不可读时本次不带任何凭据（白名单匿名发出或被放行判定拒绝）。
        if let account = options.boundAccount, let current = ready.account, current != account {
            return .rejected(LocalRejectReason.accountMismatch)
        }
        guard operation.stepUp != nil, !admitted else {
            return .ready(ready)
        }
        if let reason = registerPending(call, operation, ready, &options) {
            return .rejected(reason)
        }
        admitted = true
        return .ready(ready)
    }

    /// 四个 step-up 操作：账号只取自会话；未决记录落盘成功才发。返回拒绝原因，nil = 已登记（或沿用本进程已占用的键）。
    private func registerPending(
        _ call: ApiCall,
        _ operation: ApiOperation,
        _ ready: Ready,
        _ options: inout RunOptions
    ) -> String? {
        guard let account = ready.account else {
            return LocalRejectReason.accountUnknown
        }
        guard let key = ready.idempotencyKey else {
            return LocalRejectReason.invalidCall
        }
        if let held = options.held, held.account != account || held.key != key {
            return LocalRejectReason.accountMismatch
        }
        let owner = options.held?.owner
        let submission = PendingKeyStore.Submission(
            operationId: operation.operationId, key: key, body: call.body ?? "", account: account, summary: call.summary
        )
        switch pendingKeys.prepareSend(submission, owner: owner) {
        case let .admitted(granted):
            options.held = PendingHold(key: key, account: account, owner: granted)
            return nil
        case .blocked:
            return LocalRejectReason.pendingKeyUnresolved
        case .storeFailed:
            return LocalRejectReason.pendingStoreFailed
        }
    }

    /// 没有统一外壳（超时、断连、取消、网关错误页、3xx）：四个 step-up 操作的键进入结果未知。
    func transportFailure(_ outcome: TransportOutcome, _ ready: Ready, _ held: PendingHold?) -> ApiResult {
        let kind: String
        let status: Int?
        switch outcome {
        case let .failure(failureKind):
            kind = failureKind
            status = nil
        case let .response(code, _, _):
            kind = HttpTransport.kindNoEnvelope
            status = code
        }
        if let held {
            // 写回 unknown 失败时内存里仍按 unknown（覆盖层），结果里照样标出结果未知（lessons 32）。
            pendingKeys.onResponse(
                key: held.key, kind: PendingKeyStore.noEnvelope, account: held.account, callOwner: held.owner
            )
        }
        return .transportFailure(
            kind: kind, httpStatus: status, idempotencyKey: ready.idempotencyKey,
            pendingKeyUnknown: held.map(isUnknown) ?? false
        )
    }

    /// 一次已发出并拿到外壳的交换。
    struct Exchange {
        let call: ApiCall
        let operation: ApiOperation
        let isReplay: Bool
        let options: RunOptions
        let ready: Ready
    }

    /// 业务错误码：ErrorActionMapper → 管线自己处理的（刷新重放、重新注册重放、强更、只刷新、清会话）→ 结算未决键。
    func errorResult(_ exchange: Exchange, _ envelope: Envelope, _ headers: [String: String]) async -> ApiResult {
        let (call, operation, options, ready) = (exchange.call, exchange.operation, exchange.options, exchange.ready)
        let data = envelope.data as? [String: Any] ?? [:]
        let state = await readContext()
        let mapped = ErrorActionMapper.map(ErrorActionInput(
            code: envelope.code, data: data, operation: operation, headers: headers, isReplay: exchange.isReplay,
            state: ErrorActionState(
                update: state.update, sessionScope: currentScope(state), appVersion: identity.appVersion
            ),
            fromProductCard: call.fromProductCard
        ))
        // 自动重放沿用同一个键：重放期间未决记录保持本进程占用（不先结算）。
        let replayCall = withKey(call, ready.idempotencyKey)
        var effect: ErrorEffect
        var cleared = false
        switch await pipelineAction(mapped, data, exchange) {
        case .replay:
            return await run(replayCall, operation, isReplay: true, options: options)
        case let .end(reason):
            // 已收到外壳：按收到的码结算未决键，再结束旧调用（不交付任何会话级副作用）。
            settleHeld(options, kind: PendingKeyStore.envelopeKind(envelope.code))
            return .localReject(reason: reason)
        case let .effect(value):
            effect = value
        case let .cleared(value):
            effect = value
            cleared = true
        case let .transient(kind):
            // 等待中的刷新暂时失败：不清会话，原请求不再发出，按网络错误结束（lessons 31）。
            settleHeld(options, kind: PendingKeyStore.envelopeKind(envelope.code))
            return .transportFailure(
                kind: kind, httpStatus: nil, idempotencyKey: ready.idempotencyKey,
                pendingKeyUnknown: options.held.map(isUnknown) ?? false
            )
        }
        effect = settledEffect(effect, envelope.code, options)
        if cleared {
            // 会话 Effect 已由刷新窗口（或复用的那次失败）发过一次，这里只把结果交给调用方。
            return .sessionCleared(effect: effect)
        }
        await hooks.onEffect(effect)
        return .failure(
            code: envelope.code, msg: envelope.msg, data: JSONFields.encode(envelope.data),
            traceId: envelope.traceId, effect: effect, idempotencyKey: ready.idempotencyKey
        )
    }

    enum PipelineAction {
        case replay
        case end(String)
        case effect(ErrorEffect)
        /// 等待中的刷新失败（或本世代早先已因刷新失败被清）：会话已清，重放不再发出。
        case cleared(ErrorEffect)
        /// 等待中的刷新暂时失败（超时、断连）：不清会话，原请求按网络错误结束。
        case transient(String)
    }

    /// 作废请求的前置码只引导；结算未决键；键已结果未知时不换新键、不登记 pending_action，发起页进入待确认
    /// （BR-ID-10；10003 例外：二次验证后仍同键继续，`confirmPending(stepUpToken:)`）。
    func settledEffect(_ effect: ErrorEffect, _ code: Int, _ options: RunOptions) -> ErrorEffect {
        var result = effect
        if options.guideOnlyPrerequisites, ErrorActionMapper.prerequisiteCodes.contains(code) {
            result.kind = .guideOnly
            result.replay = .none
            result.registerPending = false
        }
        settleHeld(options, kind: PendingKeyStore.envelopeKind(code))
        if let held = options.held, isUnknown(held) {
            result.registerPending = false
            result.replay = result.kind == .stepUp ? .sameKey : .none
            result.pendingKeyUnknown = true
            // 非终结的 2xxxx（20903 已作废除外）：页面动作与文案统一改成「暂时确认不了」，保留确认 / 放弃入口，
            // 不输出 new_key_resubmit 之类要求换键的动作（R1-08）。
            if (20000...29999).contains(code), code != Self.abandonedCode {
                result.kind = .pageAction
                result.action = ErrorPageAction.pendingConfirm
                result.textKey = Self.cannotConfirmTextKey
                result.route = nil
                result.fields = nil
            }
        }
        return result
    }

    static let abandonedCode = 20903
    static let cannotConfirmTextKey = "pending_confirm.cannot_confirm"

    func settleHeld(_ options: RunOptions, kind: String) {
        if let held = options.held {
            pendingKeys.onResponse(key: held.key, kind: kind, account: held.account, callOwner: held.owner)
        }
    }

    /// 管线自己执行的 Effect。旧世代响应的会话级副作用一概不交付（lessons 34、40）：该世代因刷新失败被清的复用那次结果
    /// （session_cleared，不再清会话、不再发 Effect），其余按 session_changed（作废的按 call_cancelled）结束。
    func pipelineAction(_ effect: ErrorEffect, _ data: [String: Any], _ exchange: Exchange) async -> PipelineAction {
        let ready = exchange.ready
        if Self.isSessionScoped(effect) {
            let (current, failure) = lock.withLock { (generation, refreshFailures[ready.generation]) }
            if current != ready.generation {
                if let failure {
                    return .cleared(failure)
                }
                return .end(supersededReason(exchange.options))
            }
        }
        if let ended = screenDeviceRejection(effect, exchange) {
            return ended
        }
        if abandonsRecovery(effect, exchange.options) {
            return .end(LocalRejectReason.callCancelled)
        }
        switch effect.kind {
        case .refreshReplay, .refreshOnly:
            return await refreshAction(effect, exchange)
        case .registerDeviceReplay:
            return await reRegisterAction(effect, exchange)
        case .forceUpdate:
            await forceUpdateUnlessCallerHandles(data, exchange.call)
        case .clearSessionLogin:
            return clearAction(effect, exchange)
        default:
            break
        }
        return .effect(effect)
    }

    /// 10404 清会话：清理是否发生、Effect 归属哪一代，在同一把锁里定下（APP-05a 共性 26）。上面的世代核对之后、这里之前已换代
    /// （新登录已保存）的，不清新会话，也不发会话失效 Effect——按旧世代的响应结束。
    private func clearAction(_ effect: ErrorEffect, _ exchange: Exchange) -> PipelineAction {
        let ready = exchange.ready
        guard let cleared = clearSession(ifGeneration: ready.generation) else {
            let failure = lock.withLock { refreshFailures[ready.generation] }
            return failure.map { .cleared($0) } ?? .end(supersededReason(exchange.options))
        }
        var owned = effect
        owned.sessionGeneration = cleared
        return .effect(owned)
    }

    /// 首次 10402：重新注册（注册表在入口里先隔离被拒凭据），成功后沿用原键重放 1 次。调用有效性一并交给注册窗口；
    /// 重新注册期间调用失效（APP-04 三端共性第 22、46 条）时本地结束，不重放。
    private func reRegisterAction(_ effect: ErrorEffect, _ exchange: Exchange) async -> PipelineAction {
        let registered = await hooks.reRegisterDevice(
            exchange.ready.request.headers[HeaderNames.deviceId], exchange.options.callValid
        )
        if !callStillValid(exchange.options) {
            return .end(LocalRejectReason.callCancelled)
        }
        return registered
            ? .replay : .effect(ErrorEffect(code: effect.code, kind: .genericError, includeTrace6: true))
    }

    func withKey(_ call: ApiCall, _ key: String?) -> ApiCall {
        var copy = call
        copy.idempotencyKey = key
        return copy
    }

    func isUnknown(_ held: PendingHold) -> Bool {
        pendingKeys.state(key: held.key, account: held.account).stateRaw == PendingKeyStore.unknown
    }
}
