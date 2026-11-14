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
        // 会话读取失败（可能有会话 = 身份未知）：不能当成没有会话匿名发出，也拿不到可信的 scope、账号——只有 x-auth=none 与声明了
        // `sendsWhenIdentityUnknown` 的 optional 照常不带令牌发出，其余一律 session_unreadable 本地拒绝（R2-01、D10-1709）。
        // 这一步先于固定账号核对：未声明的调用固定了账号也报 session_unreadable；声明了的再由 `expectedMismatch(_:_:_:)` 核账号。
        if read == .unreadable, !Self.sendsWhenIdentityUnknown(operation, call) {
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
            generation: session, sessionWithoutAccess: live != nil && accessToken == nil
        ))
    }

    /// 身份未知（会话读不出，或读得出但没有可用 access，D10-1709）时这一次调用能否照常不带令牌发出：x-auth=none 能；x-auth=optional
    /// 只有调用点声明了 `ApiCall.sendsWhenIdentityUnknown`、且没置 `requiresSession` 才能；其余（login / phone / realname、置了
    /// requiresSession 的 optional）不能。确认游客（本机没有会话）不走这里，optional 照常匿名发出。
    static func sendsWhenIdentityUnknown(_ operation: ApiOperation, _ call: ApiCall) -> Bool {
        switch operation.auth {
        case authNone:
            true
        case authOptional:
            !call.requiresSession && call.sendsWhenIdentityUnknown
        default:
            false
        }
    }

    /// 组请求之后的核对（返回本地结束原因，nil = 可发）：先核固定归属（`expectedMismatch(_:_:_:)`），再核身份未知的第二种——
    /// x-auth=optional 的调用读到了会话却没有可用 access（D10-1709 本线口径），未声明 `sendsWhenIdentityUnknown` 的按 session_unreadable
    /// 本地拒绝、零发送（不当成游客匿名发出）。固定账号核对在前：固定了账号的调用照旧 account_mismatch（LockIosPinnedAccountTests 3）。
    /// 置了 requiresSession 的 optional（段 3 的 step_up 发码）必须带着本人令牌发出：组好的请求没有 Authorization（没有会话、或会话没有可用
    /// access）就按 session_unreadable 本地拒（段 2 第 3 次评审 S2-2：不能比缺省调用更松、不带令牌发出）。
    func readyMismatch(_ ready: Ready, _ operation: ApiOperation, _ call: ApiCall, _ options: RunOptions) -> String? {
        if let reason = expectedMismatch(ready, operation, options) {
            return reason
        }
        guard operation.auth == Self.authOptional else { return nil }
        if call.requiresSession {
            return ready.request.headers[HeaderNames.authorization] == nil ? LocalRejectReason.sessionUnreadable : nil
        }
        return ready.sessionWithoutAccess && !call.sendsWhenIdentityUnknown ? LocalRejectReason.sessionUnreadable : nil
    }

    /// 这一次调用要不要等受限会话刷新屏障（D10-1658 ④）：x-auth=none 不要；x-auth=optional 缺省不要——有令牌就带、没有就不带，不等屏障
    /// （登录 / 绑手机发码在受限会话刷新在途时照常发出），只有调用方置了 `ApiCall.requiresSession`（预留给二次验证面板的 step_up 发码，
    /// 段 3 接入）才要；其余（login / phone / realname）都要。会话读不出时能不能发另由 `sendsWhenIdentityUnknown(_:_:)` 决定（D10-1709）。
    /// 是否带 Authorization 另由 `RequestHeaderPolicy.decide` 按「有令牌且 x-auth 不是 none」决定，与这里无关；固定了账号的 optional
    /// 调用没带上那个账号的令牌时，由组请求之后的 `expectedMismatch(_:_:_:)` 按 account_mismatch 拒（不在这里）。
    static func needsSession(_ operation: ApiOperation, _ call: ApiCall) -> Bool {
        switch operation.auth {
        case authNone:
            false
        case authOptional:
            call.requiresSession
        default:
            true
        }
    }

    static let authNone = "none"
    static let authOptional = "optional"

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
        withSessionLock {
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
