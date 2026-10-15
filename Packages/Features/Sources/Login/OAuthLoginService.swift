import CouliNetwork
import Foundation
import Generated
import Router
import Session

/// 第三方登录要 App 提供的出口（生产实现是 `RouterLoginHost`）。
@MainActor
public protocol OAuthHost: AnyObject {
    /// 第三方登录保存会话的那一刻：重置有效待办的计时并暂缓（共性第 3、9 条）。
    func holdPending(session: UInt64)
    /// 明确释放暂缓并恢复（引导结束、手机号查清）。
    func releasePendingHold(_ mode: PendingHoldRelease, session: UInt64)
    /// 只解除暂缓、不恢复。
    func dropPendingHold(session: UInt64)
    /// 第三方新号：盖在恢复页上弹 LoginBindPhoneGuide。
    func presentBindGuide(session: UInt64, provider: String)
}

/// 一次第三方登录的结果。`stateRaw`：logged_in / cancelled（用户在授权界面取消，静默）/ stale（离页、换会话、迟到）/ busy /
/// agreement_required / rate_limited / unavailable（适配器不可用或拉不起）/ OAuthLoginErrorAction 的 actionRaw / network_error /
/// session_expired。`route` 是登录成功的分流（done / bind_phone_guide）。
public struct OAuthOutcome: Equatable, Sendable {
    public static let loggedIn = LoginOutcome.loggedIn
    public static let cancelled = "cancelled"
    public static let unavailable = "unavailable"
    public static let rateLimited = SmsCountdown.stateRateLimited

    public let stateRaw: String
    public let textKey: String?
    public let trace6: String
    public let route: String?
    public let provider: String

    init(_ stateRaw: String, provider: String, textKey: String? = nil, trace6: String = "", route: String? = nil) {
        self.stateRaw = stateRaw
        self.textKey = textKey
        self.trace6 = trace6
        self.route = route
        self.provider = provider
    }
}

/// 第三方登录的执行器（APP-05b 任务书 §2.1；BR-ID-04 细则；共性第 1–3、8、9、13、14 条）：
/// - 流程：createOauthAttempt → 拉起第三方（nonce 交给 SDK）→ 拿到授权凭证 → loginByWechat / loginByApple；只上送授权凭证，不在客户端
///   换 token；凭证只在内存，不落盘、不进日志；
/// - 归属（共性第 1 条）：流程开始时一次固定会话 / 隐私 / 环境归属（`ownership`）与登录页尝试（LoginService 的 AttemptOwner）；
///   两个请求都带固定归属发送（网络层只比较、零发送），授权返回后、提交前再比较一次——授权等待期间保存了另一会话、离页、取消、超时，
///   整个 attempt 终止，迟到回调只丢弃（`OAuthAttemptSession`）；同一 attempt 只提交一次；
/// - 登录保存沿用 APP-05a 的原子保存（ApiClient 在保存那把锁里核对归属）；保存成功才算登录成功；
/// - 分流：受限会话（deletion_only）走 APP-05a 的登录后计划；full：先暂缓待办（重置计时、不执行），新号记「未绑手机」并弹绑手机引导，
///   老用户手机号状态未知（不当已绑）——先查 getMe，查清后经 Router 守卫恢复，查询失败只恢复登录级待办（共性第 14 条）。
@MainActor
public final class OAuthLoginService {
    let login: LoginService
    let host: OAuthHost
    public let phone: PhoneBindingSync
    /// provider → 适配器（App 注入：正式微信恒不可用，Apple 的 entitlement 开关，Debug 假适配器）。
    public var authorizers: [String: ThirdPartyAuthorizer]
    /// 此刻的请求归属（App：ApiClient.currentOwnership + 撤回清理是否完成）。
    public var ownership: () -> RequestOwnership
    /// 本地授权等待上限（BR-ID-04 缺省 600 秒，TODO(N-29) OAUTH-TIMEOUT：不用 expire_at 收紧）。
    public var timeoutMillis: Int64 = 600_000
    /// 最近一次第三方登录成功的 provider（并号确认正文的 {provider_name}；冷启动后未知，rule-gaps iOS I07）。
    public private(set) var lastProvider: (generation: UInt64, provider: String)?
    private var attempts = OAuthAttemptSession()
    private var callbackSeq = 0
    private var running = false
    /// 本次第三方登录来自受限登录页（`start` 时记下；同一时刻只有一次登录在跑）。
    var restrictedAttempt = false
    var limits: [String: Int64] = [:]
    private var current: (authorizer: ThirdPartyAuthorizer, wait: AuthWait)?

    public init(
        login: LoginService, host: OAuthHost, phone: PhoneBindingSync, authorizers: [String: ThirdPartyAuthorizer]
    ) {
        self.login = login
        self.host = host
        self.phone = phone
        self.authorizers = authorizers
        let client = login.client
        ownership = { client.currentOwnership(credentialsReadable: true) }
        // 登录页出栈、换号、登出等作废登录尝试的同步出口：第三方授权的等待一并终止（迟到回调只丢弃）
        login.onAttemptInvalidated.append { [weak self] in self?.leave() }
    }

    public var busy: Bool {
        running
    }

    /// 被拒的回调（观测：迟到、重复、离页之后）。
    public var dropped: [DroppedCallback] {
        attempts.dropped
    }

    /// 已提交的尝试次数（观测）。
    public var submittedCount: Int {
        attempts.submitted.count
    }

    /// 离开登录页（同步出口）：终止当前 attempt，收起第三方界面。
    public func leave() {
        attempts.leave()
        let running = current
        current = nil
        // 等待立即结束（不依赖第三方界面是否回调），之后到达的回调只丢弃
        running?.wait.finish(.left)
        running?.authorizer.abort()
    }

    // MARK: - 登录

    /// 第三方登录。`consentAtMillis`：协议勾选或确认框同意的时刻（未勾选不能发起，BR-ID-04）。`restricted`：从强更页进入的受限登录
    /// （BR-ID-01；登录请求体本来就不带邀请码，受限只影响登录后的分流，见 `loggedIn`）。
    public func start(provider: String, consentAtMillis: Int64?, restricted: Bool = false) async -> OAuthOutcome {
        guard let consentAtMillis else { return OAuthOutcome(LoginOutcome.agreementRequired, provider: provider) }
        guard !running, !login.busy else { return OAuthOutcome(LoginOutcome.busy, provider: provider) }
        guard !rateLimited(provider, now: login.now) else {
            return OAuthOutcome(OAuthOutcome.rateLimited, provider: provider, textKey: "error.42901")
        }
        guard let authorizer = authorizers[provider], authorizer.available,
              let operation = OAuthProvider.loginOperation(provider)
        else {
            return OAuthOutcome(OAuthOutcome.unavailable, provider: provider, textKey: Self.unavailableKey(provider))
        }
        let attempt = login.attemptOwner
        let owner = ownership()
        restrictedAttempt = restricted
        running = true
        defer { running = false }
        let created = await createAttempt(provider: provider, attempt: attempt, owner: owner)
        guard case let .success(attemptId, nonce) = created else {
            if case let .failure(outcome) = created {
                return outcome
            }
            return OAuthOutcome(LoginOutcome.stale, provider: provider)
        }
        let handle = attempts.create()
        attempts.launch(handle)
        let end = await authorizeWithin(authorizer, nonce: nonce, handle: handle)
        guard case let .result(authorization) = end else {
            // 超时：提示重新授权；离页 / 换会话：静默
            return end == .timeout
                ? OAuthOutcome(OAuthLoginErrorAction.reauthorize, provider: provider, textKey: "error.20004")
                : OAuthOutcome(LoginOutcome.stale, provider: provider)
        }
        guard let credential = accept(authorization, handle: handle, provider: provider) else {
            return finishWithout(authorization, provider: provider)
        }
        // 授权等待之后、提交之前复核归属（共性第 1 条）：登录页尝试、会话 / 隐私 / 环境归属任一变了 → 终止整个 attempt
        guard attempt.isValid, ownership() == owner else {
            attempts.leave()
            return OAuthOutcome(LoginOutcome.stale, provider: provider)
        }
        guard attempts.submit(handle) else { return OAuthOutcome(LoginOutcome.stale, provider: provider) }
        return await submit(
            operation: operation, provider: provider, body: loginBody(attemptId, credential, consentAtMillis),
            attempt: attempt, owner: owner
        )
    }

    private enum Created {
        case success(attemptId: String, nonce: String)
        case failure(OAuthOutcome)
    }

    /// createOauthAttempt（purpose=login）：带固定归属；失败按 OAuthLoginErrorAction 给页面动作。
    private func createAttempt(provider: String, attempt: AttemptOwner, owner: RequestOwnership) async -> Created {
        let body = LoginService.json(["provider": provider, "purpose": "login"])
        let client = login.client
        let result = await login.run {
            await client.send(
                ApiCall(operationId: "createOauthAttempt", body: body), isValid: { attempt.isValid },
                sendAllowed: { true }, expected: owner
            )
        }
        guard attempt.isValid else { return .failure(OAuthOutcome(LoginOutcome.stale, provider: provider)) }
        switch result {
        case let .success(data, traceId, _):
            let object = LoginService.object(data)
            guard let attemptId = object["attempt_id"] as? String, !attemptId.isEmpty,
                  let nonce = object["nonce"] as? String, !nonce.isEmpty
            else {
                return .failure(OAuthOutcome(
                    OAuthLoginErrorAction.serviceError, provider: provider, textKey: LoginService.genericKey,
                    trace6: LoginService.trace6(traceId)
                ))
            }
            return .success(attemptId: attemptId, nonce: nonce)
        case let .failure(code, _, _, traceId, effect, _):
            return .failure(errorOutcome(provider: provider, code: code, effect: effect, traceId: traceId))
        default:
            return .failure(Self.otherOutcome(result, provider: provider))
        }
    }

    /// 等第三方结果，最长 `timeoutMillis`。超时、离页时等待立即结束（timeout / leave 终止 attempt）；之后才到的回调交给 attempt 记为丢弃。
    private func authorizeWithin(_ authorizer: ThirdPartyAuthorizer, nonce: String, handle: String) async -> AuthWait
        .End {
        let wait = AuthWait()
        current = (authorizer, wait)
        let timeout = timeoutMillis
        Task { @MainActor [weak self] in
            let result = await authorizer.authorize(nonce: nonce)
            if !wait.finish(.result(result)), case .credential = result {
                self?.lateCallback(handle)
            }
        }
        let timer = Task { @MainActor [weak self, weak authorizer] in
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 1)) * 1_000_000)
            guard !Task.isCancelled, wait.finish(.timeout) else { return }
            self?.attempts.timeout()
            authorizer?.abort()
        }
        let end = await wait.value()
        timer.cancel()
        if current?.wait === wait {
            current = nil
        }
        return end
    }

    /// 等待已经结束（超时、离页）之后才到的凭证：交给 attempt 记为丢弃，不提交。
    private func lateCallback(_ handle: String) {
        callbackSeq += 1
        attempts.callback(handle, seq: callbackSeq)
    }

    /// 回调交到 attempt：只有当前、已拉起、未终止的 attempt 收凭证；其余记入 dropped（迟到回调只丢弃）。
    private func accept(_ authorization: OAuthAuthorization?, handle: String, provider _: String) -> OAuthCredential? {
        guard case let .credential(credential) = authorization else {
            if attempts.isLive(handle) {
                attempts.cancel()
            }
            return nil
        }
        callbackSeq += 1
        return attempts.callback(handle, seq: callbackSeq) ? credential : nil
    }

    private func finishWithout(_ authorization: OAuthAuthorization?, provider: String) -> OAuthOutcome {
        switch authorization {
        case .cancelled:
            OAuthOutcome(OAuthOutcome.cancelled, provider: provider)
        case .failed:
            OAuthOutcome(OAuthLoginErrorAction.reauthorize, provider: provider, textKey: "error.20004")
        case .unavailable:
            OAuthOutcome(OAuthOutcome.unavailable, provider: provider, textKey: Self.unavailableKey(provider))
        default:
            // 凭证到了但 attempt 已终止（离页、超时、取消）：迟到回调只丢弃
            OAuthOutcome(LoginOutcome.stale, provider: provider)
        }
    }

    /// 登录请求体：attempt_id + 规定的凭证字段 + 协议版本与勾选时刻（openapi LoginByWechatRequest / LoginByAppleRequest，多余字段 20001）。
    private func loginBody(_ attemptId: String, _ credential: OAuthCredential, _ consentAtMillis: Int64) -> String {
        var body: [String: Any] = [
            "attempt_id": attemptId,
            "legal_versions": ["privacy": login.legalVersions.privacy, "agreement": login.legalVersions.agreement],
            "consent_at": LoginService.isoTime(consentAtMillis),
        ]
        for (key, value) in credential.fields {
            body[key] = value
        }
        return LoginService.json(body)
    }

    private func submit(
        operation: String, provider: String, body: String, attempt: AttemptOwner, owner: RequestOwnership
    ) async -> OAuthOutcome {
        let client = login.client
        let saved = SavedGeneration()
        let result = await login.run {
            await client.send(
                ApiCall(operationId: operation, body: body), isValid: { attempt.isValid },
                onSessionSaved: { saved.record($0) }, expected: owner
            )
        }
        login.recordCommit(saved.value)
        switch result {
        case let .success(data, _, _):
            return await loggedIn(LoginService.object(data), provider: provider, attempt: attempt, saved: saved.value)
        case let .failure(code, _, _, traceId, effect, _):
            guard attempt.isValid else { return OAuthOutcome(LoginOutcome.stale, provider: provider) }
            return errorOutcome(provider: provider, code: code, effect: effect, traceId: traceId)
        default:
            guard attempt.isValid else { return OAuthOutcome(LoginOutcome.stale, provider: provider) }
            return Self.otherOutcome(result, provider: provider)
        }
    }

    // MARK: - 登录成功

    private func loggedIn(_ data: [String: Any], provider: String, attempt: AttemptOwner, saved: UInt64?) async
        -> OAuthOutcome {
        let route = OAuthLoginRoute.ofData(data)
        guard let generation = saved else {
            return OAuthOutcome(
                OAuthLoginErrorAction.serviceError,
                provider: provider,
                textKey: LoginService.genericKey
            )
        }
        lastProvider = (generation, provider)
        let scope = (data["tokens"] as? [String: Any])?["session_scope"] as? String
        if usesLoginPlan(scope: scope) {
            return await planned(data, provider: provider, attempt: attempt, generation: generation, route: route)
        }
        guard attempt.isValid else {
            // 保存之后、这里之前被作废：会话确已建立，只同步会话状态，不关页、不恢复待办（APP-05a 共性 10）
            login.host.sessionSynced()
            return OAuthOutcome(LoginOutcome.stale, provider: provider)
        }
        // 先暂缓（重置计时、不执行），再关登录页、同步会话：之后的自动恢复入口都只保留记录（共性第 3、9 条）
        host.holdPending(session: generation)
        if route.routeRaw == OAuthLoginRoute.bindPhoneGuide {
            phone.store.record(false, generation: generation)
            login.host.closeLogin()
            login.host.sessionChanged()
            host.presentBindGuide(session: generation, provider: provider)
        } else {
            login.host.closeLogin()
            login.host.sessionChanged()
            resolveExistingUser(generation: generation)
        }
        return OAuthOutcome(LoginOutcome.loggedIn, provider: provider, route: route.routeRaw)
    }
}

/// 一次授权等待（只结束一次）：第三方结果、超时、离页三者先到者为准。
@MainActor
final class AuthWait {
    enum End: Equatable {
        case result(OAuthAuthorization)
        case timeout
        case left
    }

    private var ended: End?
    private var continuation: CheckedContinuation<End, Never>?

    /// 结束等待；已结束返回 false。
    @discardableResult
    func finish(_ end: End) -> Bool {
        guard ended == nil else { return false }
        ended = end
        continuation?.resume(returning: end)
        continuation = nil
        return true
    }

    func value() async -> End {
        if let ended {
            return ended
        }
        return await withCheckedContinuation { continuation in
            if let ended {
                continuation.resume(returning: ended)
            } else {
                self.continuation = continuation
            }
        }
    }
}
