import Combine
import CouliNetwork
import DesignSystem
import Foundation

/// 绑手机页要 App 接的出口（只在主线程调用）。`UUID` 是本页的导航实例编号（RouteDestination.id）：出栈只作用于这一个实例，不按路由名
/// 找同名页面（APP-09 共性第 50 条）。
@MainActor
public struct BindPhoneHooks {
    /// 本实例此刻在栈顶。
    public var isTop: (UUID) -> Bool = { _ in true }
    /// 场景在前台（scenePhase 为 active；inactive 同样作废导航与弹窗许可，APP-09 共性第 77 条）。
    public var sceneActive: () -> Bool = { true }
    /// 经 Router 以 App 内来源打开（DeleteAccount、Login 等）。
    public var open: (String) -> Void = { _ in }
    /// 本实例绑定成功且持有页面许可（共性第 25 条）：只出栈这一个实例，按「完成前置」恢复待办，轻提示「手机号已绑定」。
    public var completed: (UUID, UInt64) -> Void = { _, _ in }
    /// 进页查清已绑（共性第 38 条）：只出栈这一个实例，只恢复待办（不算完成前置、不重置计时）。
    public var alreadyBound: (UUID, UInt64) -> Void = { _, _ in }
    /// 左上角返回：出栈本实例（未绑定离开的待办恢复由 App 在出栈的同步出口统一处理）。
    public var back: (UUID) -> Void = { _ in }
    /// 统一客服出口（44001 申诉、30414）。
    public var contactService: () -> Void = {}
    /// 读屏播报（App 接 UIAccessibility；测试记下）。
    public var announce: (String) -> Void = { _ in }
    /// 当前会话最近一次第三方登录的 provider 名（并号正文 {provider_name}）；不知道为 nil（用契约 fallback）。
    public var providerName: (UInt64) -> String? = { _ in nil }

    public init() {}
}

/// 页内提示（每次换新编号：出现或换成新的一条时播报一次）。
public struct BindNotice: Equatable, Sendable {
    public let text: String
    public let id: Int
}

/// 字段错误事件：编号 + 目标字段（phone / code）。每次换新编号：页面移焦点、播报一次。
public struct BindFieldEvent: Equatable, Sendable {
    public let id: Int
    public let field: String
}

/// 绑手机页的弹窗（`id` 是弹窗实例编号：确认时同时核对，作废后旧回调无效，APP-12 共性第 20 条）。
public enum BindDialog: Equatable, Sendable {
    /// BindPhoneMerge（30411 mergeable）。
    case merge(ticket: String, phone: String, id: Int)
    /// 44001 风控（标题键）。
    case risk(titleKey: String, id: Int)
    /// 放弃上一次提交的二次确认（绑定点击时的原键）。
    case abandon(key: String, id: Int)

    public var id: Int {
        switch self {
        case let .merge(_, _, id), let .risk(_, id), let .abandon(_, id): id
        }
    }
}

/// 待确认卡（G07：版式照 PhoneChangePendingConfirm，文案共用 pending_confirm.*）。
public struct BindPendingCard: Equatable, Sendable {
    public let key: String
    /// 本机脱敏的提交号码（取自未决记录的摘要）。
    public let maskedPhone: String
    public let submittedAtMillis: Int64
}

/// 绑手机页的执行器（BindPhone / BindPhoneMerge 画板；APP-05b 任务书 §2.3；APP-13a 共性第 6、11、16、23、25、36、38、41 条）：
/// - 固定身份：构造时一次取得（`owner`），页面所有回调都只用这一份；会话换代由 App 在同步出口作废本实例（`invalidate`），再按新身份建新实例；
/// - 页面许可：本实例存活、可见（栈顶且前台）、可见世代与发起时相同，才导航、弹窗、播报；不满足时只存结局，回到有效页面再展示；
/// - 发码 purpose=bind，按规范化号码的倒计时；42901 / 50401 / 10007 / 44001 照共性处理；倒计时结束与发码成功各播报一次；
/// - 绑定：bindPhone 写请求离页不取消，共享结算在 BindPhoneService；30411 mergeable → 并号确认（锁定契约没有并号接口，确认后不发请求，
///   提示暂不可用，TODO(N-29) MERGE-SUCCESS）；结果未知 → 待确认卡（G07）。
@MainActor
public final class BindPhoneController: ObservableObject {
    public let owner: BindPhoneOwner
    public let entryId: UUID
    let service: BindPhoneService
    let texts: LoginTexts
    let hooks: BindPhoneHooks

    @Published public internal(set) var phone = ""
    @Published public internal(set) var code = "" {
        didSet {
            // 验证码修订号（R2-03）：内容每变一次 +1（输入、清码、重置），提交时捕获，回来时核对
            if code != oldValue {
                codeRev += 1
            }
        }
    }

    @Published public internal(set) var phoneError: String?
    @Published public internal(set) var codeError: String?
    /// 字段错误事件（编号 + 目标字段）：每次换新，页面移焦点并播报一次（共性第 6 条）。
    @Published public internal(set) var fieldEvent: BindFieldEvent?
    @Published public internal(set) var sending = false
    @Published public internal(set) var submitting = false
    @Published public internal(set) var notice: BindNotice? {
        didSet {
            // 页内提示出现或换成新的一条：播报一次（共性第 6 条；不逐次重复）
            if let notice, notice != oldValue, visibleNow {
                hooks.announce(notice.text)
            }
        }
    }

    @Published public internal(set) var dialog: BindDialog?
    @Published public internal(set) var pending: BindPendingCard?
    @Published public internal(set) var pendingNotice: BindNotice?
    @Published public internal(set) var pendingBusy = false
    @Published public internal(set) var pendingUnreadable = false
    @Published public internal(set) var toast: CouliToastMessage?
    @Published public internal(set) var now: Int64
    /// phoneGate 禁用中（订阅同一份闸门的开始 / 结束，R1-03）：【绑定】、【确认上一次提交】、【放弃上一次提交】统一按它置灰。
    @Published public internal(set) var writeGated = false

    public private(set) var alive = true
    var visible = false
    var visibleGen = 0
    /// 表单世代：换号、清空、重置时 +1（发码结果只更新同一世代的表单）。
    var formGen = 0
    /// 验证码修订号（见 `code`）。
    var codeRev = 0
    var serial = 0
    /// 页面隐藏期间到达的退出（R3-01）：绑定成功 → 完成前置，进页查询查明已绑 → 只恢复。记下发起时的固定身份，回到页面消费时重核
    /// （实例、完整身份、页面许可、共享已绑）；作废（出栈、会话换代重建）时清掉。
    var deferredExit: BindDeferredExit?
    /// 本实例已退出一次（completed / alreadyBound 已调）：之后到达的结果与共享通知不再重复退出。
    var exited = false
    /// 进页的首次网络查询已发过（共享已绑状态每次重新有效都先查，R1-08）。
    private var rechecked = false
    var armedEnd: (phone: String, deadline: Int64)?
    private var ticker: Task<Void, Never>?
    private var unsubscribe: (() -> Void)?
    private var gateWatch: AnyCancellable?

    public init(owner: BindPhoneOwner, entryId: UUID, service: BindPhoneService, texts: LoginTexts,
                hooks: BindPhoneHooks) {
        self.owner = owner
        self.entryId = entryId
        self.service = service
        self.texts = texts
        self.hooks = hooks
        now = service.clock()
        unsubscribe = service.subscribe { [weak self] settled in
            guard let self, alive, settled.account == owner.account else { return }
            refreshPending()
            // 别的实例绑定成功：本页查清已绑，只出栈本实例并只恢复（不算本页完成前置）。R3-03：账号相同只够重读未决记录；退出与释放
            // 暂缓还要通知携带的发起身份就是本页的固定身份（账号 + 登录世代 + 作废世代 + 作用域），且仍是当前会话、共享状态已绑
            if settled.kind == .done, deferredExit == nil, settled.owner == owner, permitted(visibleGen) {
                exitNow(.resumeOnly)
            }
        }
        // phoneGate 的开始与结束都驱动页面刷新（R1-03）：限流到期、短信计时器已停时【绑定】也要恢复可点
        gateWatch = service.gate.$blocked.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.gateChanged() }
        }
    }

    /// 按此刻闸门重算禁用状态（`$blocked` 在值变化前发布；截止时刻此时已更新，这里按时钟现算）。
    private func gateChanged() {
        writeGated = alive && service.writeGated(owner)
    }

    // MARK: - 生命周期

    /// 此刻持有页面许可：存活、可见、栈顶、前台，且可见世代与 `ticket` 相同。
    func permitted(_ ticket: Int) -> Bool {
        alive && visible && visibleGen == ticket && hooks.isTop(entryId) && hooks.sceneActive()
    }

    /// 页面出现（含从别的页返回、回前台）：可见世代 +1；补展示被暂存的结局；首次出现查一次手机号状态与未决记录。
    public func appeared() {
        guard alive else { return }
        visible = true
        visibleGen += 1
        now = service.clock()
        restartTicker()
        if let deferred = deferredExit {
            // 延后的退出只由记下它的同一身份消费，消费时重核（R3-01，鸿蒙 FU-HM-0720 R1-02 同口径）。F-IOS-12：appeared 时仍可能
            // inactive / 不在栈顶——exitNow 统一核对 visibleNow，没有许可时原记录（含原退出方式）保留，等下一次恢复再消费
            if deferred.owner != owner || !boundExitAllowed {
                deferredExit = nil
            } else if exitNow(deferred.kind) {
                return
            }
        }
        // 隐藏期间到达的弹窗类结局不补弹（R1-04）：待确认信息从共享状态（本机未决记录）重新读
        refreshPending()
        recheckBound()
    }

    /// 被覆盖、退到后台、场景 inactive：许可作废（写请求照常结算）。
    public func disappeared() {
        guard visible else { return }
        visible = false
        visibleGen += 1
    }

    /// 出栈或会话换代的同步出口：作废本实例，清空输入、倒计时、弹窗与并号凭据，释放订阅（APP-12 共性第 1 条）。
    public func invalidate() {
        alive = false
        visible = false
        visibleGen += 1
        unsubscribe?()
        unsubscribe = nil
        gateWatch = nil
        ticker?.cancel()
        ticker = nil
        phone = ""
        code = ""
        dialog = nil
        pending = nil
        armedEnd = nil
        deferredExit = nil
    }

    /// 进页查清手机号状态（共性第 38 条）：每次页面重新有效都先查共享已绑状态——已绑就只退出本实例并只恢复待办（R1-08：查询在
    /// inactive 期间返回、当时没有许可时，回到前台由这里补处理）；仍未知时只在首次查一次 getMe，结果只交给发起时的同一实例与可见世代。
    private func recheckBound() {
        let generation = owner.request.generation
        // F-IOS-12：共享已绑时同样经 exitNow 核对 visibleNow；没有许可时记下延后（只恢复），不再发查询
        if exitNow(.resumeOnly) || deferredExit != nil {
            return
        }
        guard !rechecked, service.store.bound(generation: generation) == nil else { return }
        rechecked = true
        service.sync.query { [weak self] outcome in
            // R3-01：查明已绑时页面已经恢复（本次 appeared 已执行过）就当场退出一次，仍隐藏才延后
            guard let self, outcome == .bound(true) else { return }
            boundArrived(.resumeOnly)
        }
    }

    // MARK: - 输入

    var normalizedPhone: String? {
        PhoneNumber.normalize(phone).normalized
    }

    public func setPhone(_ value: String) {
        guard alive, value != phone else { return }
        phone = value
        phoneError = nil
        formGen += 1
        // 换号：旧号码的并号凭据随弹窗作废（R1-05）
        if case .merge = dialog {
            dialog = nil
        }
        // 换号：旧号码的倒计时结束不播报（共性第 17 条）；新号码按自己的截止时间显示
        if let armed = armedEnd, armed.phone != normalizedPhone {
            armedEnd = nil
        }
        now = service.clock()
        restartTicker()
    }

    public func clearPhone() {
        setPhone("")
    }

    public func setCode(_ value: String) {
        guard alive else { return }
        let clean = CodeInput.sanitize(value)
        guard clean != code else { return }
        code = clean
        codeError = nil
    }

    // MARK: - 显示

    /// 当前号码距可以再发码还有几秒（倒计时或 42901）。
    public var resendRemaining: Int {
        guard let phone = normalizedPhone else { return 0 }
        return service.smsRemainingSec(owner, phone: phone, now: now)
    }

    public var canSendCode: Bool {
        alive && !sending && resendRemaining == 0 && pending == nil
    }

    /// 【绑定】可点：号码合法、6 位码齐全、没有待确认、不在 phoneGate 禁用期、不在提交中。
    public var canSubmit: Bool {
        alive && normalizedPhone != nil && CodeInput.accept(code).complete && !submitting && pending == nil
            && !pendingUnreadable && !service.writeGated(owner)
    }

    /// 待确认卡的【确认上一次提交】/【放弃上一次提交】可点：不在处理中、不在 phoneGate 禁用期（R1-03，与【绑定】同一禁用状态）。
    public var pendingActionsEnabled: Bool {
        alive && !pendingBusy && !service.writeGated(owner)
    }

    public var inputsLocked: Bool {
        pending != nil
    }

    func text(_ key: String) -> String {
        texts.text(key)
    }

    func nextId() -> Int {
        serial += 1
        return serial
    }

    /// 统一错误消息（5xxxx 附 trace6，ErrorTrace 统一追加）。
    func show(_ key: String, trace6: String) -> BindNotice {
        let vars = trace6.isEmpty ? [:] : ["trace6": trace6]
        var message = texts.format(key, vars)
        if message.isEmpty {
            message = texts.format(LoginService.genericKey, vars)
        }
        if !trace6.isEmpty, !message.contains(trace6) {
            message += ErrorTrace.suffixTemplate.replacingOccurrences(of: "{trace6}", with: trace6)
        }
        return BindNotice(text: message, id: nextId())
    }

    // MARK: - 许可与计时

    /// 此刻的可见世代（发起异步请求时记下，结果回来时核对）。
    var visibleTicket: Int {
        visibleGen
    }

    var formGenValue: Int {
        formGen
    }

    var codeRevValue: Int {
        codeRev
    }

    /// 此刻可见（存活、可见、栈顶、前台）。
    var visibleNow: Bool {
        permitted(visibleGen)
    }

    /// 发码成功：记下这个号码与真实截止时刻，倒计时走完时播报一次。
    func armDeadline(_ phone: String, _ deadline: Int64) {
        armedEnd = (phone, deadline)
    }

    func restartTickerIfNeeded() {
        restartTicker()
    }

    func restartTicker() {
        ticker?.cancel()
        ticker = nil
        guard alive, resendRemaining > 0 || armedEnd != nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                tick()
                if resendRemaining == 0, armedEnd == nil {
                    ticker = nil
                    return
                }
            }
        }
    }

    /// 每秒重算；倒计时真正走完（同一规范化号码、记下的截止时刻已到）播报一次「可以重新获取」（共性第 11、17 条，不逐秒播报）。
    func tick() {
        now = service.clock()
        guard let armed = armedEnd, armed.phone == normalizedPhone, now >= armed.deadline else { return }
        armedEnd = nil
        if visible, alive {
            hooks.announce(text(BindPhoneKeys.canResend))
        }
    }
}
