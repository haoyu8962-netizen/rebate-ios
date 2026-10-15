import CouliNetwork
import Foundation
import Generated
import Session

/// 短信登录的执行器（APP-05a；03 §4.2、§4.4；BR-ID-04、BR-ID-05、BR-ID-10）：
/// - 发码：先规范化，不合法本地给 20001 同一文案、不发出；同一号码截止前不再发出；成功 60 秒倒计时，42901 按 Retry-After；
/// - 登录：手机号、6 位码、协议勾选时刻齐全才发；带包内协议版本与勾选 / 确认时刻；受限登录不带邀请码；ApiClient 保存
///   会话成功才算登录成功，之后按 AfterLogin.plan 依次执行；
/// - 归属（共性 1）：发码、登录、受限复查都以本次尝试的 `AttemptOwner` 发出（`ApiClient.send(_:isValid:)`），并在可取消的
///   Task 里运行。`invalidateAttempt` 同步作废归属并取消这些 Task（传输层随 Task 取消）；ApiClient 在保存会话的同一把锁里
///   核对归属，迟到的旧响应不保存会话、不通知 Router、不恢复待办；
/// - 登出：带当前会话调 logout（结果不论成败）；会话世代变了要区分「已换成新会话」与「原会话已被清除」（共性 3）。
@MainActor
public final class LoginService {
    let client: ApiClient
    let host: LoginHost
    private let legal: LegalVersions
    private let clock: () -> Int64
    public private(set) var deadlines = SmsSendDeadlines()
    private var owner = AttemptOwner()
    private var tasks: [UUID: () -> Void] = [:]
    private var sending = false
    private var loggingIn = false
    private var loggingOut = false
    /// 最近一次成功保存了会话的登录（APP-04 共性 68：桥 auth.login 绑定本次登录保存的会话世代）。
    public private(set) var lastCommit: LoginCommit?
    private var commitSerial: UInt64 = 0

    public init(
        client: ApiClient,
        host: LoginHost,
        legal: LegalVersions = .bundled,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.client = client
        self.host = host
        self.legal = legal
        self.clock = clock
        // 共性 25：Router 登记待办、发起推送回查时记下此刻的会话世代，登出收尾只清原会话归属的那些。
        host.bindSessionTag { [client] in client.sessionGeneration }
    }

    /// 到目前为止成功保存会话的登录次数（桥 auth.login 打开登录页前记下，结束时只认这之后的登录）。
    public var commitMark: UInt64 {
        commitSerial
    }

    public var now: Int64 {
        clock()
    }

    public var busy: Bool {
        sending || loggingIn
    }

    /// 正在登出（logout 请求在途）：其间网络层发出的会话失效 Effect 由登出流程自己收尾，App 不另开登录页。
    public var isLoggingOut: Bool {
        loggingOut
    }

    /// 换了手机号、取消、离开登录页：在途的发码与登录结果不再改页面、不保存会话；已交给传输层的请求同步取消。
    public func invalidateAttempt() {
        // 共性 24：作废与 ApiClient「核对尝试仍有效 → 写入令牌」共用同一同步区：返回时，这次尝试要么没有保存会话、
        // 之后也不会保存，要么已经保存完成（按作废晚于提交处理：只同步会话、不恢复待办）。
        let current = owner
        client.withLoginCommitLock { current.invalidate() }
        owner = AttemptOwner()
        let cancels = tasks.values
        tasks = [:]
        cancels.forEach { $0() }
    }

    /// 这个号码（任意写法）距可以再发码还有几秒；0 = 可以发。
    public func resendRemainingSec(_ rawPhone: String) -> Int {
        guard let phone = PhoneNumber.normalize(rawPhone).normalized else { return 0 }
        return deadlines.remainingSec(phone, now: clock())
    }

    /// 这个号码在验证码有效期内收到过码（共性 12：发码限流期间仍可进验证码步继续输入）。
    public func hasReceivedCode(_ rawPhone: String) -> Bool {
        guard let phone = PhoneNumber.normalize(rawPhone).normalized else { return false }
        return deadlines.hasReceivedCode(phone, now: clock())
    }

    /// 在可取消的 Task 里运行一次网络调用；invalidateAttempt 时取消。
    private func run<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        let id = UUID()
        let task = Task { await body() }
        tasks[id] = { task.cancel() }
        defer { tasks[id] = nil }
        return await task.value
    }

    public func sendCode(_ rawPhone: String) async -> SendCodeOutcome {
        guard let normalized = PhoneNumber.normalize(rawPhone).normalized else {
            // 与服务端 20001 phone_invalid 同一文案，不发短信、不计频控（BR-ID-05）。
            let local = LoginErrorMapper.map(op: LoginErrorMapper.sendSmsCode, code: 20001, data: Self.phoneInvalidData)
            return SendCodeOutcome(local.stateRaw, textKey: local.textKey, field: "phone")
        }
        if let gated = gateOutcome(normalized) {
            return gated
        }
        guard !sending else {
            return SendCodeOutcome(LoginOutcome.busy)
        }
        let attempt = owner
        let body = Self.json(["phone": normalized, "purpose": "login"])
        sending = true
        let client = client
        let result = await run { await client.send(ApiCall(operationId: LoginErrorMapper.sendSmsCode, body: body),
                                                   isValid: { attempt.isValid }) }
        sending = false
        return sendSettled(result, phone: normalized, attempt: attempt)
    }

    /// 这个号码的发码闸门（共性 5、11）：成功发码的倒计时内 → countdown_active；42901 禁用期内 → rate_limited。不发出。
    private func gateOutcome(_ normalized: String) -> SendCodeOutcome? {
        guard let gate = deadlines.active(normalized, now: clock()) else { return nil }
        let remaining = deadlines.remainingSec(normalized, now: clock())
        if gate.kind == SmsCountdown.stateSent {
            return SendCodeOutcome(SendCodeOutcome.countdownActive, countdownSec: remaining, phone: normalized,
                                   hasReceivedCode: true)
        }
        return SendCodeOutcome(SmsCountdown.stateRateLimited, countdownSec: remaining, textKey: "error.42901",
                               phone: normalized, hasReceivedCode: deadlines.hasReceivedCode(normalized, now: clock()))
    }

    /// 发码结果：截止时间不论页面是否还在都记下（服务端已受理或已限流，换号再换回来也不能绕过）；页面结果按归属作废。
    private func sendSettled(_ result: ApiResult, phone normalized: String, attempt: AttemptOwner) -> SendCodeOutcome {
        switch result {
        case let .success(data, _, _):
            let sent = SmsCountdown.fromMillis(code: 0, disableMillis: 0, data: Self.object(data))
            deadlines.record(normalized, until: clock() + Int64(sent.countdownSec) * 1000, kind: SmsCountdown.stateSent)
            deadlines.recordSent(normalized, at: clock())
            guard attempt.isValid else { return SendCodeOutcome(LoginOutcome.stale) }
            return SendCodeOutcome(sent.stateRaw, countdownSec: sent.countdownSec, phone: normalized,
                                   hasReceivedCode: true)
        case let .failure(code, _, data, traceId, effect, _):
            let mapped = LoginErrorMapper.ofEffect(op: LoginErrorMapper.sendSmsCode, code: code, effect: effect)
            let countdown = SmsCountdown.fromMillis(
                code: code, disableMillis: effect.disableMillis ?? 0, data: Self.object(data)
            )
            if code == Self.providerTimeoutCode {
                // 共性 16：供应商超时（50401）时短信可能已发出：允许用户继续输入实际收到的验证码（不计倒计时）。
                deadlines.recordSent(normalized, at: clock())
            }
            if countdown.stateRaw == SmsCountdown.stateRateLimited {
                deadlines.record(normalized, until: clock() + Int64(countdown.countdownSec) * 1000,
                                 kind: SmsCountdown.stateRateLimited)
            }
            guard attempt.isValid else { return SendCodeOutcome(LoginOutcome.stale) }
            return SendCodeOutcome(countdown.stateRaw, countdownSec: countdown.countdownSec, textKey: mapped.textKey,
                                   field: mapped.field, phone: normalized, trace6: Self.trace6(traceId),
                                   hasReceivedCode: deadlines.hasReceivedCode(normalized, now: clock()))
        default:
            if case .transportFailure = result {
                // 共性 22：请求已写出、结果未知（换号 / 离开页面后被取消、超时、断连）：短信可能已发出，这个号码照样保留
                // 「可以继续输入验证码」的期限（不计倒计时）。请求还没写出的（localReject）不记。旧请求不改当前页面（下面的归属）。
                deadlines.recordSent(normalized, at: clock())
            }
            guard attempt.isValid else { return SendCodeOutcome(LoginOutcome.stale) }
            let failed = Self.otherFailure(result)
            return SendCodeOutcome(failed.stateRaw, textKey: failed.textKey, phone: normalized, trace6: failed.trace6)
        }
    }

    /// 短信登录。`consentAtMillis`：勾选或确认框同意的时刻；`restricted`：从强更页进入的受限登录（APP-02c 内部标记）。
    public func login(phone rawPhone: String, code: String, consentAtMillis: Int64?, invite: String,
                      restricted: Bool) async -> LoginOutcome {
        guard let phone = PhoneNumber.normalize(rawPhone).normalized else {
            let local = LoginErrorMapper.map(op: LoginErrorMapper.loginBySms, code: 20001, data: Self.phoneInvalidData)
            return LoginOutcome(local.stateRaw, textKey: local.textKey, field: "phone")
        }
        guard CodeInput.accept(code).complete else {
            return LoginOutcome(LoginOutcome.codeIncomplete, field: "code")
        }
        guard let consentAtMillis else {
            // 未勾选协议不能登录（BR-ID-04）：页面先弹确认框。
            return LoginOutcome(LoginOutcome.agreementRequired)
        }
        guard !loggingIn else {
            return LoginOutcome(LoginOutcome.busy)
        }
        let attempt = owner
        var body: [String: Any] = [
            "phone": phone,
            "code": code,
            "legal_versions": ["privacy": legal.privacy, "agreement": legal.agreement],
            "consent_at": Self.isoTime(consentAtMillis),
        ]
        if let wire = InviteField.wireValue(invite, restricted: restricted) {
            body["invite_code"] = wire
        }
        let text = Self.json(body)
        loggingIn = true
        let client = client
        let saved = SavedGeneration()
        let result = await run {
            await client.send(ApiCall(operationId: LoginErrorMapper.loginBySms, body: text),
                              isValid: { attempt.isValid }, onSessionSaved: { saved.record($0) })
        }
        loggingIn = false
        recordCommit(saved.value)
        switch result {
        case let .success(data, _, _):
            return await loggedIn(Self.object(data), attempt: attempt, restricted: restricted)
        case let .failure(code, _, _, traceId, effect, _):
            guard attempt.isValid else { return LoginOutcome(LoginOutcome.stale) }
            let mapped = LoginErrorMapper.ofEffect(op: LoginErrorMapper.loginBySms, code: code, effect: effect)
            return LoginOutcome(mapped.stateRaw, textKey: mapped.textKey, field: mapped.field,
                                disableMillis: mapped.disableMillis, trace6: Self.trace6(traceId))
        default:
            guard attempt.isValid else { return LoginOutcome(LoginOutcome.stale) }
            return Self.otherFailure(result)
        }
    }

    /// 登出（settings.logout）：返回 true = 本机已回到游客。logout 请求失败（断网等）照样清本机会话
    /// （TODO(N-26) INTEGRATION-02：服务端会话只能等过期，规则未写失败时是否提示）。
    ///
    /// `owner`（APP-12 R1-04，共性第 30 条）：调用方在【退出登录】确认时一次取得的请求归属，之后只比较——logout 请求带它发送（会话世代 / 账号 /
    /// 作废世代不一致零发送），本地清理只按 `owner.generation`；确认之后、执行之前已保存了新会话时不作废新会话的登录尝试、不发、不清新会话
    /// （`superseded` → false）。nil = 原有行为（按此刻的会话世代）。
    public func logout(owner: RequestOwnership? = nil) async -> Bool {
        guard !loggingOut else { return false }
        let generation = owner?.generation ?? client.sessionGeneration
        if client.sessionGeneration == generation {
            invalidateAttempt()
        }
        loggingOut = true
        if client.isolatedSessionScope != nil {
            if let owner {
                _ = await client.send(
                    ApiCall(operationId: "logout"), isValid: { true }, sendAllowed: { true }, expected: owner
                )
            } else {
                _ = await client.send(ApiCall(operationId: "logout"))
            }
        }
        loggingOut = false
        // 共性 3、23：核对世代与删除会话在 ApiClient 保存登录会话的同一把锁里完成（不先读世代、再另行删除）。
        switch client.signOut(expectedGeneration: generation) {
        case .superseded:
            // 等待期间已换成新会话（新登录）：不清新会话，只同步会话状态。
            host.sessionSynced()
            return false
        case .signedOut, .alreadyCleared:
            // 原会话（世代没变，或已被 10404 / 刷新失败清除）：Router 的清理只清原会话归属的待办与回查（共性 25）——
            // 原会话被别处清掉之后用户新建的 pending_action（正在进行的第二次登录要恢复的）不动。
            host.sessionEnded(throughSession: generation)
            host.sessionSynced()
            return true
        }
    }

    /// 本机清会话（当前会话）：ApiClient 按此刻的世代清令牌并换代 → Router.sessionEnded（清 pending_action、作废回查）
    /// → 同步会话状态。
    public func clearLocalSession() {
        let generation = client.sessionGeneration
        _ = client.signOut(expectedGeneration: generation)
        host.sessionEnded(throughSession: generation)
        host.sessionSynced()
    }

    // MARK: - 登录成功

    /// 会话确已由这次登录保存（不论之后是否被作废）：记下保存后的世代，先于关闭登录页（APP-04 共性 68）。
    private func recordCommit(_ generation: UInt64?) {
        guard let generation else { return }
        commitSerial &+= 1
        lastCommit = LoginCommit(serial: commitSerial, generation: generation)
    }

    private func loggedIn(_ data: [String: Any], attempt: AttemptOwner, restricted: Bool) async -> LoginOutcome {
        guard attempt.isValid else {
            // 保存之后、这里之前被作废：会话确已建立，只同步会话状态，不关页、不恢复待办（共性 10）。
            host.sessionSynced()
            return LoginOutcome(LoginOutcome.stale)
        }
        let scope = ((data["tokens"] as? [String: Any])?["session_scope"] as? String) ?? Session.SessionScope.full
        let isNew = JSONBool.isTrue(data["is_new_user"])
        var actions = AfterLogin.plan(response: ["session_scope": scope, "is_new_user": isNew], state: planState())
        if actions.contains(AfterLoginAction.refreshRestricted) {
            // 共性 4、10：deletion_only 与 supported 并存——不动待办；带本次尝试的归属显式复查受限会话，取消时立即结束等待。
            let client = client
            let recheck = await run { await client.recheckRestrictedSession(isValid: { attempt.isValid }) }
            guard attempt.isValid, recheck != .cancelled else {
                host.sessionSynced()
                return LoginOutcome(LoginOutcome.stale)
            }
            if recheck == .cleared {
                // 复查时会话被清除（刷新被拒）：网络层已发会话级 Effect；只同步状态，不恢复待办。
                host.sessionSynced()
                return LoginOutcome("session_expired", textKey: "error.10404")
            }
            let again = AfterLogin.plan(
                response: ["session_scope": recheck == .full ? Session.SessionScope.full : Session.SessionScope
                    .deletionOnly],
                state: planState()
            )
            var replanned = [AfterLoginAction.saveSession, AfterLoginAction.refreshRestricted]
            replanned += again.filter { $0 != AfterLoginAction.saveSession && $0 != AfterLoginAction.refreshRestricted }
            if again.contains(AfterLoginAction.refreshRestricted) {
                replanned.append(AfterLoginAction.holdPending)
            }
            actions = replanned
        }
        execute(actions)
        var inviteResult: String?
        var inviteCode: Int?
        if !restricted, let bind = data["invite_bind"] as? [String: Any] {
            inviteResult = bind["result"] as? String
            inviteCode = (bind["code"] as? NSNumber)?.intValue
        }
        return LoginOutcome(LoginOutcome.loggedIn, actions: actions, inviteResult: inviteResult, inviteCode: inviteCode)
    }
}
