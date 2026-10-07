import Foundation
import Generated
import Session

/// 公共头 → 签名（03 §4.2 中间件前两步）：每次实际发送前重新组装。
extension ApiClient {
    /// 公共头 → 签名：决定要带的头，读凭据（只在可读时），算签名。
    func prepare(_ call: ApiCall, _ operation: ApiOperation, _ state: NetworkContext) -> Prepared {
        let readable = state.privacy == PrivacyRaw.full && state.credentialsReadable
        // 会话快照与世代在同一把锁里读（已作废的会话按没有）。
        let (read, session) = lock.withLock { (readable ? readSessionLocked() : SessionRead.none, generation) }
        // 会话读取失败（可能有会话）：需要会话的接口一律不发（不能当成没有会话匿名发出，也拿不到可信的 scope、账号），
        // 不需要会话的接口照常不带令牌发出（R2-01）。
        if read == .unreadable, operation.auth != "none" {
            return .rejected(LocalRejectReason.sessionUnreadable)
        }
        let live = read.live
        let accessToken = live?.access
        // device_id 与 install_secret 一次读出（同一份凭据，不拼两次读取的结果）。
        let credentials = readable ? device.credentials : nil
        let deviceId = credentials?.deviceId
        let decision = RequestHeaderPolicy.decide(
            state: requestState(live, state, hasAccessToken: accessToken != nil, deviceId: deviceId),
            operation: operation,
            body: JSONFields.object(call.body)
        )
        guard decision.send else {
            return .rejected(decision.localRejectReason ?? LocalRejectReason.environmentUnsettled)
        }
        guard let base = state.apiBaseURL else {
            return .rejected(LocalRejectReason.environmentUnsettled)
        }
        guard let url = Self.buildURL(base, operation.pathTemplate, call.pathParams, call.query) else {
            return .rejected(LocalRejectReason.invalidCall)
        }
        let body = call.body.map { Data($0.utf8) }
        var headers = anonymousHeaders()
        if decision.includeAuthorization, let accessToken {
            headers[HeaderNames.authorization] = "Bearer \(accessToken)"
        }
        if decision.includeDeviceId, let deviceId {
            headers[HeaderNames.deviceId] = deviceId
        }
        let key = decision.includeIdempotencyKey ? (call.idempotencyKey ?? newId()) : nil
        if let key {
            headers[HeaderNames.idempotencyKey] = key
        }
        headers.merge(callHeaders(call, operation, readable: readable)) { _, new in new }
        if decision.includeSignature {
            guard readable, let secret = credentials?.installSecret else {
                return .rejected(LocalRejectReason.deviceNotReady)
            }
            headers.merge(signatureHeaders(secret, operation.method, url, body)) { _, new in new }
        }
        return .ready(Ready(
            request: PreparedRequest(method: operation.method, url: url, headers: headers, body: body),
            idempotencyKey: key,
            accessToken: accessToken,
            account: live?.account.flatMap { $0.isEmpty ? nil : $0 },
            generation: session
        ))
    }

    /// 调用自带的头：step-up 操作的 X-Step-Up-Token（凭据可读时）、读接口的 If-None-Match（原样）。
    private func callHeaders(_ call: ApiCall, _ operation: ApiOperation, readable: Bool) -> [String: String] {
        var headers: [String: String] = [:]
        if readable, operation.stepUp != nil, let token = call.stepUpToken {
            headers[HeaderNames.stepUpToken] = token
        }
        if operation.isRead, let tag = call.ifNoneMatch, !tag.isEmpty {
            headers[HeaderNames.ifNoneMatch] = tag
        }
        return headers
    }

    /// 不含凭据与设备标识的公共头（每次发送新的 X-Trace-Id）。
    private func anonymousHeaders() -> [String: String] {
        [
            HeaderNames.appId: identity.appId,
            HeaderNames.platform: identity.platform,
            HeaderNames.appVersion: identity.appVersion,
            HeaderNames.build: identity.build,
            HeaderNames.channel: identity.channel,
            HeaderNames.traceId: newId(),
        ]
    }

    /// 签名头：按发出的路径与请求体字节、校正后的时钟、新的 nonce 计算（BR-ID-09）。
    private func signatureHeaders(_ secret: String, _ method: String, _ url: URL, _ body: Data?) -> [String: String] {
        let offset = lock.withLock { clockOffsetMillis }
        let timestamp = RequestSigner.timestamp(nowMillis: clock() + offset)
        let nonceValue = nonce()
        let text = RequestSigner.signingString(
            method: method, pathWithQuery: Self.signedPath(url), timestamp: timestamp, nonce: nonceValue,
            body: body ?? Data()
        )
        return RequestSigner.headers(
            installSecret: secret,
            signingString: text,
            timestamp: timestamp,
            nonce: nonceValue
        )
    }

    /// 会话作用域：凭据不可读或没有会话时按 full（不带令牌，接口照 full 判定）。
    func currentScope(_ state: NetworkContext) -> String {
        liveSession(state)?.scope ?? SessionScope.full
    }

    private func requestState(
        _ live: LiveSession?,
        _ state: NetworkContext,
        hasAccessToken: Bool,
        deviceId: String?
    ) -> NetworkRequestState {
        NetworkRequestState(
            privacy: state.privacy,
            sessionScope: live?.scope ?? SessionScope.full,
            hasAccessToken: hasAccessToken,
            deviceId: deviceId,
            environmentSettled: state.environmentSettled,
            credentialsReadable: state.credentialsReadable
        )
    }
}
