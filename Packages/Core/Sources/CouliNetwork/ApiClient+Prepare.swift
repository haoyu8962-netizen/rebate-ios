import Foundation
import Generated
import Session

/// 公共头 → 签名（03 §4.2 中间件前两步）：每次实际发送前重新组装。
extension ApiClient {
    /// 发往 stream 入口的契约路径前缀（D10-598 ①）。
    static let agentPathPrefix = "/v1/agent/"

    /// 请求基址：Agent 操作按契约路径模板（不按带查询串的 URL）分流到 stream 入口；stream 未设时与其余操作一样走 api
    /// （D10-598 ①）。环境未就绪时为 nil。
    static func baseURL(_ operation: ApiOperation, _ state: NetworkContext) -> URL? {
        let stream = operation.pathTemplate.hasPrefix(agentPathPrefix) ? state.streamBaseURL : nil
        return stream ?? state.apiBaseURL
    }

    /// 公共头 → 签名：决定要带的头，读凭据（只在可读时），算签名。
    /// `options` 给出时（业务调用）：同一把锁里先比较——快照仍可信、调用仍属当前作废世代、带固定归属的会话世代未变——再读凭据
    /// （APP-08 iOS NEW-01）；任何一项不满足都不读令牌与设备凭据（随后的归属比较按不一致本地结束）。
    func prepare(
        _ call: ApiCall, _ operation: ApiOperation, _ state: NetworkContext, _ options: RunOptions? = nil
    ) -> Prepared {
        // 可读性判断、世代比较与会话读取在同一把锁里，按「先比较、再读取」的顺序（已作废的会话按没有）。
        let guarded = guardedSessionRead(state, options)
        let (read, session, readable) = (guarded.read, guarded.generation, guarded.readable)
        // 会话读取失败（可能有会话）：需要会话的接口一律不发（不能当成没有会话匿名发出，也拿不到可信的 scope、账号），
        // 不需要会话的接口照常不带令牌发出（R2-01）。
        if read == .unreadable, operation.auth != "none" {
            return .rejected(LocalRejectReason.sessionUnreadable)
        }
        let live = read.live
        let accessToken = live?.access
        hooks.afterCredentialAdmission()
        // device_id 与 install_secret 一次读出（同一份凭据，不拼两次读取的结果）。设备凭据也过撤回禁读屏障（APP-08 iOS r3g
        // NEW-05）：设备锁里先查设备自己的屏障，再回到网络锁重做同一项准入比较（锁顺序「设备锁 → 网络锁」），都通过才读。
        // 这里不持网络锁。
        let credentials = readable ? device.credentials(admittedBy: { admittedEpoch(state, options) }) : nil
        let deviceId = credentials?.deviceId
        let decision = RequestHeaderPolicy.decide(
            state: requestState(live, state, hasAccessToken: accessToken != nil, deviceId: deviceId),
            operation: operation,
            body: JSONFields.object(call.body)
        )
        guard decision.send else {
            return .rejected(decision.localRejectReason ?? LocalRejectReason.environmentUnsettled)
        }
        guard let base = Self.baseURL(operation, state) else {
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
        headers.merge(callHeaders(call, operation, readable: readable, state: state)) { _, new in new }
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

    /// 调用自带的头：step-up 操作的 X-Step-Up-Token（凭据可读时）、读接口的 If-None-Match（原样）；个性化推荐关闭时的
    /// X-Personalization: off（APP-12 G03：只在已同意时带，基本模式、未决不带）。
    private func callHeaders(
        _ call: ApiCall, _ operation: ApiOperation, readable: Bool, state: NetworkContext
    ) -> [String: String] {
        var headers: [String: String] = [:]
        if state.privacy == PrivacyRaw.full, state.personalizationOff {
            headers[HeaderNames.personalization] = "off"
        }
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
    /// 组请求用的一次会话读取（APP-08 iOS NEW-01）：同一把锁里先比较（快照仍可信、调用仍属当前作废世代、固定归属的会话世代未变），
    /// 全部通过才读令牌；否则按没有会话、不可读。
    struct GuardedRead {
        let read: SessionRead
        let generation: UInt64
        let readable: Bool
    }

    func guardedSessionRead(_ state: NetworkContext, _ options: RunOptions?) -> GuardedRead {
        lock.withLock {
            let allowed = admitLocked(state, options)
            return GuardedRead(
                read: allowed ? readSessionLocked() : SessionRead.none, generation: generation, readable: allowed
            )
        }
    }

    /// 调用方持有 `lock`：组请求的凭据准入（快照仍可信、调用仍属当前作废世代、固定归属的会话世代未变）。
    func admitLocked(_ state: NetworkContext, _ options: RunOptions?) -> Bool {
        guard credentialsReadableLocked(state, runEpoch: options?.epoch) else {
            return false
        }
        if let expected = options?.expected, expected.generation != generation || expected.epoch != epoch {
            return false
        }
        return true
    }

    /// 设备凭据读取的准入（由设备实现在设备锁里调用，这里再取网络锁）：通过时返回当前作废世代，否则 nil。
    func admittedEpoch(_ state: NetworkContext, _ options: RunOptions?) -> UInt64? {
        lock.withLock { admitLocked(state, options) ? epoch : nil }
    }

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
