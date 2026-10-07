import Foundation
import Generated
import Session

/// 刷新请求本身（`POST /v1/auth/refresh`）：组头签名、10401 校时重签、10402 重新注册后重放（APP-03b）。
extension ApiClient {
    /// `POST /v1/auth/refresh`（不经过 ErrorActionMapper），只用窗口快照里的 refresh_token。不会抛错。
    /// 收到 10401 且响应头 Date 可校时（偏差超过 300 秒）时，校时后用新的 X-Timestamp、X-Nonce 重签再发 1 次
    /// （BR-ID-09；同一窗口的账号、世代与请求体不变，续发前重新校验状态）（R2-04）。
    func performRefresh(_ window: RefreshWindow) async -> RefreshAttempt {
        guard let operation = ApiOperations.byId(Self.refreshOperation) else {
            return .rejected
        }
        guard let body = (try? JSONSerialization.data(withJSONObject: ["refresh_token": window.refreshToken]))
            .flatMap({ String(data: $0, encoding: .utf8) })
        else {
            return .rejected
        }
        var resigned = false
        var reRegistered = false
        while true {
            let outcome: TransportOutcome
            let sentDeviceId: String?
            switch await sendRefreshOnce(window, operation, body) {
            case let .finished(attempt):
                return attempt
            case let .sent(value, deviceId):
                outcome = value
                sentDeviceId = deviceId
            }
            guard case let .response(_, headers, data) = outcome, let envelope = Envelope.parse(data) else {
                return Self.unanswered(outcome)
            }
            if envelope.code == Self.invalidSignatureCode, !resigned, operation.signed {
                if let ended = resignRefresh(window, headers) {
                    return ended
                }
                resigned = true
                continue
            }
            // 10402（X-Device-Id 无效）：走同一个设备注册单飞入口，成功后重新组头签名，至多重放一次（APP-03b 共性 6）。
            // 不是刷新被拒，不清会话。凭据隔离与重注册预算分开（共性 25）：重放再次收到 10402 时也隔离这次所用的
            // 凭据，结束本次刷新，后续恢复交给唯一一条注册退避链。
            if envelope.code == Self.deviceInvalidCode {
                if let ended = await refreshDeviceRejected(window, sentDeviceId, reRegistered: reRegistered) {
                    return ended
                }
                reRegistered = true
                continue
            }
            return Self.refreshTokens(envelope)
        }
    }

    /// 刷新请求没有拿到响应信封：被取消的按 superseded，其余按暂时失败。
    static func unanswered(_ outcome: TransportOutcome) -> RefreshAttempt {
        if case let .failure(kind) = outcome, kind == HttpTransport.kindCancelled {
            return .superseded
        }
        return .transient(transportKind(outcome))
    }

    /// 刷新收到 10401：校时重发之前先确认窗口里仍有有效调用方，一个都没有就不校时、不重发（APP-04 三端共性第 41 条），
    /// 返回结束结果；能校时返回 nil（调用方重签再发一次）；不能校时按刷新被拒处理。
    private func resignRefresh(_ window: RefreshWindow, _ headers: [String: String]) -> RefreshAttempt? {
        guard refreshHasLiveCaller(window) else {
            return Self.abandonedRefresh
        }
        return correctClock(headers) ? nil : .rejected
    }

    /// 刷新接口的令牌在 data（TokenPairResponse）；缺项或非 0 码按被拒。
    static func refreshTokens(_ envelope: Envelope) -> RefreshAttempt {
        guard envelope.code == 0, let pair = envelope.data as? [String: Any],
              let access = JSONFields.string(pair, "access_token"), !access.isEmpty,
              let refresh = JSONFields.string(pair, "refresh_token"), !refresh.isEmpty,
              let scope = JSONFields.string(pair, "session_scope"), !scope.isEmpty
        else {
            return .rejected
        }
        return .tokens(access: access, refresh: refresh, scope: scope)
    }

    enum RefreshSend {
        case finished(RefreshAttempt)
        /// 已发出：传输结果与这次带的 X-Device-Id。
        case sent(TransportOutcome, String?)
    }

    /// 窗口里的调用方全部失效（页面关闭、换文档等）：停止续发，按暂时失败结算（不清会话、不动令牌）。
    static let abandonedRefresh = RefreshAttempt.transient(LocalRejectReason.callCancelled)

    /// X-Device-Id 无效（BR-ID-09）。
    static let deviceInvalidCode = 10402
    /// 刷新遇到 10402 且重新注册没能完成：按暂时失败结束（不清会话）。
    static let deviceNotRegisteredKind = "device_not_registered"

    /// 刷新请求发一次：每次（含校时重签、重新注册后的重放）都重新取状态、核对作废世代、会话世代与窗口里是否还有有效的
    /// 调用方（APP-04 三端共性第 41 条），再重新组头签名。
    func sendRefreshOnce(_ window: RefreshWindow, _ operation: ApiOperation,
                         _ body: String) async -> RefreshSend {
        let state = await readContext()
        guard isCurrent(window.epoch), state.privacy == PrivacyRaw.full, state.credentialsReadable else {
            return .finished(.superseded)
        }
        guard refreshHasLiveCaller(window) else {
            return .finished(Self.abandonedRefresh)
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
        // 窗口任务被取消（最后一个有效调用方到期，共性第 54 条）时，在途的刷新请求随之取消。
        let outcome = await transport.send(
            ready.request, timeoutMillis: RetryPolicy.forOperation(operation).timeoutMillis, cancelWithTask: true
        ) { [weak self] in
            guard let self else {
                return false
            }
            return isCurrent(window.epoch) && currentGeneration == window.generation && refreshHasLiveCaller(window)
        }
        if case let .failure(kind) = outcome, kind == HttpTransport.kindCancelled, !refreshHasLiveCaller(window) {
            return .finished(Self.abandonedRefresh)
        }
        return .sent(outcome, ready.request.headers[HeaderNames.deviceId])
    }

    /// 刷新收到 10402：作废世代按 superseded；预算已用完时隔离这次所用的凭据并结束；否则重新注册，
    /// 成功返回 nil（调用方重新组头签名、重放一次）。
    private func refreshDeviceRejected(
        _ window: RefreshWindow, _ sentDeviceId: String?, reRegistered: Bool
    ) async -> RefreshAttempt? {
        guard isCurrent(window.epoch) else {
            return .superseded
        }
        if reRegistered {
            hooks.deviceRejected(sentDeviceId)
            return .transient(Self.deviceNotRegisteredKind)
        }
        // 重新注册之前确认窗口里仍有有效调用方（APP-04 三端共性第 41 条）：没有就不发起注册、不重放。
        guard refreshHasLiveCaller(window) else {
            return Self.abandonedRefresh
        }
        // 有效调用方约束一并交给重新注册窗口（共性第 22、46 条）：注册在内部等待后、读标识前、实际发送前都要查它。
        let registered = await hooks.reRegisterDevice(sentDeviceId) { [weak self] in
            self?.refreshHasLiveCaller(window) ?? false
        }
        guard refreshHasLiveCaller(window) else {
            return Self.abandonedRefresh
        }
        guard registered else {
            return .transient(Self.deviceNotRegisteredKind)
        }
        return nil
    }

    /// 业务请求的 10402（管线）：凭据隔离与重注册、重放预算分开（APP-03b 共性 25）。作废世代的响应结束原调用；
    /// 有效世代里重放再次收到 10402（预算已用完，映射为通用错误）时隔离这次所用的凭据，原调用按通用错误结束，
    /// 后续恢复交给唯一一条注册退避链。首次 10402 由 `reRegisterDevice` 入口先隔离再重新注册。
    func screenDeviceRejection(_ effect: ErrorEffect, _ exchange: Exchange) -> PipelineAction? {
        guard effect.code == Self.deviceInvalidCode else {
            return nil
        }
        guard isCurrent(exchange.options.epoch) else {
            return .end(LocalRejectReason.callCancelled)
        }
        if effect.kind != .registerDeviceReplay {
            hooks.deviceRejected(exchange.ready.request.headers[HeaderNames.deviceId])
        }
        return nil
    }

    static func transportKind(_ outcome: TransportOutcome) -> String {
        if case let .failure(kind) = outcome {
            return kind
        }
        return HttpTransport.kindNoEnvelope
    }
}
