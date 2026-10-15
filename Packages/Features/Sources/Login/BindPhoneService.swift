import CouliNetwork
import Foundation
import Generated
import Router
import Session

/// 绑手机页的固定身份（APP-13a 共性第 6、16、36、45 条）：账号 + 登录世代 + 作废世代（网络归属）+ 会话作用域，在页面执行器**构造时一次**
/// 取得；之后对当前会话只做比较，任何回调、请求都只用这一份。
public struct BindPhoneOwner: Equatable, Sendable {
    public let request: RequestOwnership
    public let scope: String?

    public init(request: RequestOwnership, scope: String?) {
        self.request = request
        self.scope = scope
    }

    public var account: String? {
        request.account
    }

    /// 能发绑手机请求的身份：有账号的 full 会话。
    public var usable: Bool {
        account != nil && scope == Session.SessionScope.full
    }
}

/// 一次绑手机写请求的结局（共享未决通知携带它，APP-13a 共性第 24、47 条）。
public enum BindSettledKind: String, Sendable, Equatable {
    /// 绑定成功（首次提交、确认上一次、放弃得到 completed 且原结果成功）。
    case done
    /// 键结束的业务结局（30411 / 30414 / 44001 等，或 completed 原结果是业务错误）。
    case ended
    /// 已放弃（abandoned / 20903）：要重新填写、重新验证。
    case abandoned
    /// 仍待确认或结果未知（进入待确认卡）。
    case pending
    /// 其余（本地拒绝、没发出、限流）。
    case other
}

/// 共享未决通知（notifyPending，APP-13a 共性第 18 条）：所属账号、结局与发起时的完整固定身份（R3-03：账号 + 登录世代 + 作废世代 +
/// 作用域）。账号相同只够重读本机未决记录；成功收尾（退出页面、释放暂缓）还要 `owner` 与收听页面的固定身份相同且仍是当前会话。
public struct BindPendingSettled: Equatable, Sendable {
    public let account: String
    public let kind: BindSettledKind
    public let owner: BindPhoneOwner
}

/// 绑手机页上要做的事（页面执行器按自己的页面许可执行）。
public enum BindPageAction: Equatable, Sendable {
    case done
    /// 30411 mergeable（带并号凭据，只在内存）。
    case merge(ticket: String)
    /// 44001：风控弹窗（标题键）+ 申诉入口。
    case risk(titleKey: String)
    /// 字段错误（phone / code），textKey；`clearCode`：验证码失效（20003）时清空验证码。
    case field(field: String, textKey: String, clearCode: Bool)
    /// 页内提示（错误、限流），5xxxx 附 trace6。
    case notice(textKey: String, trace6: String)
    /// 经 Router 打开（10007 cooling → DeleteAccount；10001 → Login）。
    case navigate(route: String)
    /// 进入或保持待确认（按本机未决记录重读）。
    case pending(noticeKey: String?, trace6: String)
    /// 待确认的键已结束（放弃成功、20903）：回到可编辑、提示。
    case reset(textKey: String)
    /// 没发出 / 已失效：不改页面。
    case silent
}

/// 绑手机的会话级服务（APP-05b 任务书 §2.3；APP-13a 共性第 7–9、17、18、21、25、40、45、48 条）。App 建一份、各绑手机页共用：
/// - phoneGate（`gate`）：提交、确认、放弃共用一份 42901 截止时间，每次实际写出前检查，页面订阅置灰；
/// - 发码（purpose=bind）：按「账号 + 规范化号码」记倒计时与 42901 截止时间，同一号码同一时刻只有一个发码在途；
/// - 写请求（bindPhone、确认、放弃）离页不取消（未决记录兜底），带固定身份发送（网络层只比较、零发送）；结果先在这里按固定身份做
///   共享结算（绑定状态推进更新世代、`onBound` 清全部 step-up token / 刷新「我的」/ 守卫重算、42901、未决通知），再交给页面（页面按
///   自己的许可决定是否更新、导航）；
/// - 首次绑定不带 step-up token、不预先二次验证（BR-ID-08；APP-13a G07 首次绑定确认时同样不预先 step-up）。
/// 只在主线程使用。
@MainActor
public final class BindPhoneService {
    public static let operationId = "bindPhone"
    static let smsPurpose = "bind"

    let client: ApiClient
    public let sync: PhoneBindingSync
    public let gate = RetryAfterGate()
    /// 此刻的身份（App：网络归属 + 撤回清理是否完成 + 会话作用域）。页面执行器构造时调一次；之后只用来比较。
    public var identity: () -> BindPhoneOwner
    public var clock: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    public var newKey: () -> String = { UUID().uuidString.lowercased() }
    /// 绑定成功的共享结算出口（App：清全部 action 的 step-up token、刷新「我的」、解除暂缓、守卫重算）。已核对固定身份仍是当前会话。
    public var onBound: ((BindPhoneOwner) -> Void)?
    private var listeners: [Int: (BindPendingSettled) -> Void] = [:]
    private var listenerSerial = 0
    private var sms = BindSmsDeadlines()
    private var smsSending: Set<String> = []
    private var writing: Set<String> = []
    /// phoneGate 是哪个固定归属的 42901 记下的（R1-09）：会话级限流只限制同一归属；归属变更时在同步出口清掉。
    var gateOwner: RequestOwnership?

    public init(client: ApiClient, sync: PhoneBindingSync) {
        self.client = client
        self.sync = sync
        identity = { [client] in
            BindPhoneOwner(
                request: client.currentOwnership(credentialsReadable: true), scope: client.isolatedSessionScope
            )
        }
    }

    public var store: PhoneBindingStore {
        sync.store
    }

    /// 固定身份仍是当前会话（只比较）。
    public func isCurrent(_ owner: BindPhoneOwner) -> Bool {
        owner.usable && identity() == owner
    }

    // MARK: - 未决通知

    /// 订阅未决结算（页面出栈、换代时取消）。
    public func subscribe(_ listener: @escaping (BindPendingSettled) -> Void) -> () -> Void {
        listenerSerial += 1
        let id = listenerSerial
        listeners[id] = listener
        return { [weak self] in self?.listeners[id] = nil }
    }

    func notifyPending(_ owner: BindPhoneOwner, account: String, _ kind: BindSettledKind) {
        let event = BindPendingSettled(account: account, kind: kind, owner: owner)
        for listener in listeners.values {
            listener(event)
        }
    }

    /// 这个账号有本进程发出、还没结论的绑手机写请求（G63：新页面不发第二个，按 busy 处理）。
    public func writing(_ owner: BindPhoneOwner) -> Bool {
        owner.account.map { writing.contains($0) } ?? false
    }

    /// 本机未决记录（只读，按固定身份的账号核对）。
    public func pendingStatus(_ owner: BindPhoneOwner) async -> PendingLookup {
        guard isCurrent(owner) else { return .none }
        let lookup = await client.pendingStatus(operationId: Self.operationId)
        guard isCurrent(owner) else { return .none }
        if case let .record(record) = lookup, record.account != owner.account {
            return .none
        }
        return lookup
    }

    // MARK: - 发码

    /// 这个号码的发码剩余秒数（成功发码的倒计时或 42901 禁用期）。
    public func smsRemainingSec(_ owner: BindPhoneOwner, phone: String, now: Int64) -> Int {
        sms.remainingSec(Self.slot(owner, phone), now: now)
    }

    public func smsRateLimited(_ owner: BindPhoneOwner, phone: String, now: Int64) -> Bool {
        sms.active(Self.slot(owner, phone), now: now)?.kind == SmsCountdown.stateRateLimited
    }

    /// 这个号码的发码截止时刻（倒计时结束播报绑定原号码与真实截止时间，鸿蒙 / Android 共性第 17 条）。
    public func smsDeadline(_ owner: BindPhoneOwner, phone: String) -> Int64? {
        sms.deadline(Self.slot(owner, phone))
    }

    public func smsSending(_ owner: BindPhoneOwner, phone: String) -> Bool {
        smsSending.contains(Self.slot(owner, phone))
    }

    static func slot(_ owner: BindPhoneOwner, _ phone: String) -> String {
        "\(owner.account ?? "-")|\(phone)|\(smsPurpose)"
    }

    /// 发码（purpose=bind，BR-ID-05）：`phone` 已规范化。截止时间与限流不论页面是否还在都按固定身份记下；页面结果交 `completion`。
    public func sendCode(
        _ owner: BindPhoneOwner, phone: String, completion: @escaping (BindSmsResult) -> Void
    ) {
        let slot = Self.slot(owner, phone)
        guard isCurrent(owner) else {
            completion(.silent)
            return
        }
        if let active = sms.active(slot, now: clock()) {
            completion(active.kind == SmsCountdown.stateSent ? .sent : .rateLimited)
            return
        }
        guard !smsSending.contains(slot) else {
            completion(.silent)
            return
        }
        smsSending.insert(slot)
        let body = LoginService.json(["phone": phone, "purpose": Self.smsPurpose])
        let client = client
        // 发码离页不取消（共性第 40 条）：结算按固定身份完成；归属变了网络层零发送
        Task { @MainActor [weak self] in
            let result = await client.send(
                ApiCall(operationId: BindPhoneAction.smsOperation, body: body), isValid: { true },
                sendAllowed: { true }, expected: owner.request
            )
            guard let self else { return }
            smsSending.remove(slot)
            completion(smsSettled(result, owner: owner, slot: slot))
        }
    }

    private func smsSettled(_ result: ApiResult, owner: BindPhoneOwner, slot: String) -> BindSmsResult {
        // 旧会话的结果不改新会话的倒计时与限流（APP-12 共性第 34 条）
        guard isCurrent(owner) else { return .silent }
        switch result {
        case let .success(data, _, _):
            let sent = SmsCountdown.fromMillis(code: 0, disableMillis: 0, data: LoginService.object(data))
            sms.record(slot, until: clock() + Int64(sent.countdownSec) * 1000, kind: SmsCountdown.stateSent)
            sms.recordSent(slot, at: clock())
            return .sent
        case let .failure(code, _, data, traceId, effect, _):
            return smsFailure(code: code, data: LoginService.object(data), traceId: traceId, effect: effect, slot: slot)
        case .transportFailure:
            // 已写出、结果未知：短信可能已发出（APP-05a 共性 22），不计倒计时
            sms.recordSent(slot, at: clock())
            return .notice(textKey: LoginService.genericKey, trace6: "")
        default:
            return .silent
        }
    }

    private func smsFailure(code: Int, data: [String: Any], traceId: String?, effect: ErrorEffect, slot: String)
        -> BindSmsResult {
        switch code {
        case 42901:
            let millis = effect.disableMillis ?? ErrorActionMapper.defaultRetryAfterMillis
            sms.record(slot, until: clock() + max(1000, millis), kind: SmsCountdown.stateRateLimited)
            return .rateLimited
        case 50401:
            // 供应商超时：结果未知，可能已发出（APP-05a 共性 16）——允许继续输入实际收到的码，不计倒计时
            sms.recordSent(slot, at: clock())
            return .notice(textKey: effect.textKey ?? "error.50401", trace6: LoginService.trace6(traceId))
        case 20001:
            let key = ErrorActionMapper.resolveTextKey(
                code: code, reason: data["reason"] as? String, hasText: { DefaultTexts.text($0) != nil }
            )
            return .field(field: "phone", textKey: key ?? "error.20001")
        case 44001:
            return .risk(titleKey: effect.textKey ?? "error.44001")
        case 10007 where effect.kind == .navigate:
            // 注销冷静期：经 Router 打开注销进度页（可撤回），不弹处理中提示（BR-TEXT-14 表 A，共性第 10、16 条）
            return .navigate(route: effect.route ?? "DeleteAccount")
        default:
            return .notice(
                textKey: effect.textKey ?? LoginService.genericKey,
                trace6: effect.includeTrace6 ? LoginService.trace6(traceId) : ""
            )
        }
    }

    // MARK: - 绑定

    /// 首次绑定（bindPhone）：每次点击生成新键；网络层发送前写未决记录（结果未知 → 待确认）。`phone` 已规范化，`code` 6 位。
    /// `completion` 在共享结算之后调用（页面已出栈也会结算）。
    public func submit(
        _ owner: BindPhoneOwner, phone: String, code: String, completion: @escaping (BindPageAction) -> Void
    ) {
        guard isCurrent(owner), let account = owner.account else {
            completion(.silent)
            return
        }
        guard !writing.contains(account) else {
            completion(.pending(noticeKey: nil, trace6: ""))
            return
        }
        isolateGate(owner)
        guard !writeGated(owner) else {
            completion(.notice(textKey: "error.42901", trace6: ""))
            return
        }
        let body = LoginService.json(["phone": phone, "code": code])
        let summary = LoginService.json(["phone": PhoneNumber.masked(phone)])
        let call = ApiCall(
            operationId: Self.operationId, body: body, idempotencyKey: newKey(), summary: summary
        )
        run(owner, account: account, phase: .submit, completion: completion) { [client] probe in
            await client.send(call, isValid: { true }, sendAllowed: probe.allowed, expected: owner.request)
        }
    }

    /// 【确认上一次提交】：原键原体重发（只在结果未知时接受），不预先二次验证（G07）。`key` 是待确认卡渲染时固定的原键。
    public func confirm(_ owner: BindPhoneOwner, key: String, completion: @escaping (BindPageAction) -> Void) {
        guard isCurrent(owner), let account = owner.account else {
            completion(.silent)
            return
        }
        isolateGate(owner)
        guard !writeGated(owner) else {
            completion(.pending(noticeKey: SensitiveTexts.retryLater, trace6: ""))
            return
        }
        run(owner, account: account, phase: .confirm, completion: completion) { [client] probe in
            await client.confirmPending(
                operationId: Self.operationId, stepUpToken: nil,
                target: PendingTarget(account: account, key: key, expected: owner.request, sendAllowed: probe.allowed)
            )
        }
    }

    /// 【确定放弃】（二次确认之后）：作废原键。
    public func abandon(_ owner: BindPhoneOwner, key: String, completion: @escaping (BindPageAction) -> Void) {
        guard isCurrent(owner), let account = owner.account else {
            completion(.silent)
            return
        }
        isolateGate(owner)
        guard !writeGated(owner) else {
            completion(.pending(noticeKey: SensitiveTexts.retryLater, trace6: ""))
            return
        }
        run(owner, account: account, phase: .abandon, completion: completion) { [client] probe in
            await client.abandonPending(
                operationId: Self.operationId,
                target: PendingTarget(account: account, key: key, expected: owner.request, sendAllowed: probe.allowed)
            )
        }
    }

    private func run(
        _ owner: BindPhoneOwner, account: String, phase: BindOutcomes.Phase,
        completion: @escaping (BindPageAction) -> Void,
        send: @escaping @Sendable (SendProbe) async -> ApiResult
    ) {
        writing.insert(account)
        let probe = gate.probe()
        // 写请求离页不取消（APP-13a 共性第 21 条）：任务持有固定身份直接结算（共性第 66 条），页面更新另经 completion
        Task { @MainActor [weak self] in
            let result = await send(probe)
            guard let self else { return }
            writing.remove(account)
            let (action, kind) = BindOutcomes.map(result, phase: phase, gated: probe.gated(result))
            settle(owner, result: result, kind: kind)
            completion(action)
            notifyPending(owner, account: account, kind)
        }
    }

    /// 共享结算（APP-13a 共性第 9、25、66 条）：只按固定身份；会话已换的不动新会话。
    private func settle(_ owner: BindPhoneOwner, result: ApiResult, kind: BindSettledKind) {
        guard isCurrent(owner) else { return }
        if case let .failure(code, _, _, _, effect, _) = result, code == 42901 {
            startGate(owner, millis: effect.disableMillis ?? ErrorActionMapper.defaultRetryAfterMillis)
        }
        if kind == .done {
            store.recordBindSucceeded(generation: owner.request.generation)
            onBound?(owner)
        }
    }
}

/// 发码结果（页面按自己的表单身份决定是否显示）。
public enum BindSmsResult: Equatable, Sendable {
    case sent
    case rateLimited
    case field(field: String, textKey: String)
    case risk(titleKey: String)
    case navigate(route: String)
    case notice(textKey: String, trace6: String)
    case silent
}

/// 待确认卡与通用提示的契约键。
enum SensitiveTexts {
    static let retryLater = "pending_confirm.retry_later"
    static let cannotConfirm = "pending_confirm.cannot_confirm"
    static let abandoned = "pending_confirm.abandoned"
    static let abandonBusy = "pending_confirm.abandon_busy"
}

/// 绑手机发码的截止时间（按「账号 | 规范化号码 | bind」；APP-09 共性第 6 条同口径，与登录发码分开）。只在内存。
struct BindSmsDeadlines {
    private var deadlines = SmsSendDeadlines()

    mutating func record(_ slot: String, until: Int64, kind: String) {
        deadlines.record(slot, until: until, kind: kind)
    }

    mutating func recordSent(_ slot: String, at now: Int64) {
        deadlines.recordSent(slot, at: now)
    }

    func active(_ slot: String, now: Int64) -> SmsSendDeadlines.Deadline? {
        deadlines.active(slot, now: now)
    }

    func remainingSec(_ slot: String, now: Int64) -> Int {
        deadlines.remainingSec(slot, now: now)
    }

    func deadline(_ slot: String) -> Int64? {
        deadlines.until(slot)
    }
}
