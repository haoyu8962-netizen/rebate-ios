import Combine
import CouliNetwork
import Foundation
import Generated
import WalletCore

/// 子页存活标记（面板在构造时就要一个存活判断，那时还没有 self）。
final class PhoneChangeLife {
    var alive = true
}

/// 第 1 步（或 10003 面板）拿到的流程私有 token：只在内存、跟本子页实例走，带失效世代（共性第 39、43 条；G23）。
struct PhoneChangeToken {
    let value: String
    let epoch: UInt64
    let expireAtMillis: Int64
}

/// 10003 面板是为哪次写请求打开的。
enum PhoneChangePanelIntent {
    case submit(PhoneChangeSubmission)
    case confirm(key: String)
}

/// 换号子页执行器（APP-13a-2；brief §1，D10-2203）：
/// - 身份固定（S0）：构造时一次取得 Me 身份、绑手机身份（账号 + 登录世代 + 作废世代 + 作用域）、钱包身份与作用域核对；所有回调捕获渲染时的
///   执行器与表单世代，执行时只比较（共性第 6、16、36 条）；会话同步出口里身份变了即同步作废（清空输入、倒计时、弹窗、token）；
/// - 第 1 步：sendSmsCode {purpose: step_up, action: phone_change}（不带 phone，requiresSession）→ stepUp {action, code}
///   （不带 summary）；
///   发码 / 验证与所有二次验证面板共用 `gates.sms`、`gates.verify`、`SmsDeadlines` 与共享结算（共性第 26、31 条）；
/// - 第 2 步：bind 发码、提交、确认、放弃都经 `PhoneBindPort`（BindPhoneService）：phoneGate、bind 截止时间、未决通知、成功结算与
///   BindPhone 页同一份（共性第 8、9、15、18 条）；提交每次点击新键、带第 1 步 token；10003 → 面板 → 原键原体重放 1 次；
/// - 结果未知 → 待确认（只按本机未决记录），确认 / 放弃只由用户点击；写请求离页不取消（共性第 21、48 条）。
/// 只在主线程使用。
@MainActor
public final class PhoneChangeController: ObservableObject {
    public static let action = "phone_change"
    static let csRoute = "Settings"

    @Published public internal(set) var state = PhoneChangeState()
    public let identity: MeIdentity
    let deps: MeDeps
    let bind: PhoneBindPort
    let wallet: WalletDeps
    /// 构造时一次取得的固定身份（之后只比较）。
    let owner: PhoneBindOwner
    let walletOwner: WalletOwner
    let scopeStill: @Sendable () -> Bool
    let page: UUID?
    weak var host: PhoneChangeHost?
    let life: PhoneChangeLife
    /// 10003 面板（StepUpSheet 的执行器，action = phone_change）。
    let panel: StepUpController
    var left = false
    var serial = 0
    var token: PhoneChangeToken?
    /// 第 1 步世代：重置、作废时推进，迟到的发码 / 验证结果不再改页面。
    var stepGen = 0
    /// 第 2 步表单世代：返回第 1 步、重置时推进（共性第 27、28、35 条）。
    var formGen = 0
    var pendingSerial = 0
    /// 本页自己的写请求刚结束、随后那条共享通知是自己的（不当成别处结算）。
    var ownSettling = false
    var oldTicker: Task<Void, Never>?
    var oldResendUntil: Int64 = 0
    var newTicker: Task<Void, Never>?
    var unsubscribers: [() -> Void] = []
    var watches: Set<AnyCancellable> = []

    init(deps: MeDeps, identity: MeIdentity, ports: PhoneChangePorts, host: PhoneChangeHost?, page: UUID?) {
        let bind = ports.bind
        let wallet = ports.stepUpDeps()
        let owner = bind.identity()
        let scopeStill = bind.scopeStill(owner)
        let life = PhoneChangeLife()
        self.deps = deps
        self.identity = identity
        self.bind = bind
        self.wallet = wallet
        self.owner = owner
        walletOwner = ports.walletOwner()
        self.scopeStill = scopeStill
        self.page = page
        self.host = host
        self.life = life
        panel = StepUpController.phoneChange(deps: wallet, alive: { life.alive }, scopeStill: scopeStill)
        watch()
    }

    // MARK: - 只读判断

    /// 本实例存活：没离开，Me 身份与绑手机固定身份（含作用域）都仍是当前会话。
    public var alive: Bool {
        !left && deps.env.isCurrent(identity) && bind.isCurrent(owner)
    }

    public var stepUp: StepUpController? {
        panel
    }

    /// 页面文案（「我的」类页面的文案来源）。
    public var texts: MeTexts {
        deps.texts
    }

    /// 流程 token 此刻可用：未过期、失效世代未变（只读观察口，不暴露值）。
    public var hasStepToken: Bool {
        currentToken() != nil
    }

    var phoneUnbound: Bool {
        wallet.env.stepUpPhoneBound(walletOwner) == false
    }

    public var oldCodeSendEnabled: Bool {
        alive && state.step == .step1 && !state.oldSending && state.oldResendLeftSec == 0 && !wallet.gates.sms.active
            && !phoneUnbound && state.dialog == nil
    }

    public var nextEnabled: Bool {
        alive && state.step == .step1 && state.oldCode.count == StepUpUiState.codeLength && !state.verifying
            && !wallet.gates.verify.active && !phoneUnbound && state.dialog == nil
    }

    public var newCodeSendEnabled: Bool {
        guard alive, state.step == .step2, !state.newSending, !state.submitting,
              let phone = MePhone.normalize(state.newPhone)
        else { return false }
        return bind.smsRemainingSec(owner, phone: phone) == 0 && !bind.smsSending(owner, phone: phone)
    }

    public var submitEnabled: Bool {
        alive && state.step == .step2 && state.pending == nil && !state.submitting
            && state.newCode.count == StepUpUiState.codeLength && !trimmedPhone.isEmpty && !bind.writeGated(owner)
            && !panel.showing && state.dialog == nil
    }

    public var pendingActionsEnabled: Bool {
        alive && state.step == .pending && state.pending != nil && !state.pendingBusy && !bind.writeGated(owner)
            && !panel.showing
    }

    var trimmedPhone: String {
        state.newPhone.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 回调核对：本实例仍有效、渲染时的表单世代仍是当前的。
    func accepts(_ version: Int) -> Bool {
        alive && state.version == version
    }

    func currentToken() -> String? {
        guard !left, let token, token.epoch == bind.tokenEpoch(), wallet.env.nowMillis() < token.expireAtMillis
        else { return nil }
        return token.value
    }

    // MARK: - 进入与离开

    /// 进入子页（SettingsController 建子页时同步调）：按本机未决记录恢复待确认（有记录直接显示，0 次写请求）。
    public func start() {
        guard alive else { return }
        refreshPending()
    }

    /// 同步出口（出栈、关子页、换代）：作废本实例、收起面板、清空输入 / 倒计时 / 弹窗 / 私有 token，并清 StepUpTokenCache 的
    /// phone_change 条目（G23）。写请求不取消（未决记录兜底）。
    public func leave() {
        guard !left else { return }
        left = true
        life.alive = false
        panel.detach()
        oldTicker?.cancel()
        newTicker?.cancel()
        oldTicker = nil
        newTicker = nil
        token = nil
        wallet.tokens.on10003(action: Self.action)
        for unsubscribe in unsubscribers {
            unsubscribe()
        }
        unsubscribers = []
        watches.removeAll()
        let version = state.version + 1
        state = PhoneChangeState()
        state.version = version
    }

    /// 订阅：会话同步出口（身份变了同步作废）、共享未决通知、几把闸门的禁用期（页面重绘）。
    private func watch() {
        unsubscribers.append(bind.observeSession { [weak self] in self?.sessionChanged() })
        unsubscribers.append(bind.subscribe { [weak self] event in self?.settledElsewhere(event) })
        for gate in [bind.writeGate, wallet.gates.sms, wallet.gates.verify] {
            gate.$blocked.removeDuplicates().sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }.store(in: &watches)
        }
        panel.$state.map { $0 != nil }.removeDuplicates().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }.store(in: &watches)
    }

    private func sessionChanged() {
        guard !left, !(deps.env.isCurrent(identity) && bind.isCurrent(owner)) else { return }
        if let host {
            host.closePhoneChange(self)
        }
        leave()
    }

    // MARK: - 返回、完成、弹窗

    /// 页面返回与系统返回的同一处理（共性第 27 条）：第 2 步 → 回第 1 步并重置第 2 步瞬时状态，返回 true（子页不关）；其余 → false（关子页）。
    func handleBack() -> Bool {
        guard alive, state.step == .step2 else { return false }
        resetStep2()
        state.step = .step1
        state.version += 1
        restoreOldCountdown()
        return true
    }

    /// 页面左上角返回（PhoneChangeActions.back）。
    public func back(version: Int) {
        guard accepts(version) else { return }
        if !handleBack() {
            host?.closePhoneChange(self)
        }
    }

    /// Done【完成】：回设置页的唯一实例。
    public func finish(version: Int) {
        guard accepts(version), state.step == .done else { return }
        host?.closePhoneChange(self)
    }

    /// 「原手机号不能用了？联系客服」：统一客服出口，不提交、不发码。
    public func oldUnavailable(version: Int) {
        guard accepts(version), state.step == .step1 else { return }
        deps.env.customerService(from: Self.csRoute)
    }

    /// 【知道了】/【再想想】：只认正显示的这一个弹窗；30414 之后回设置页（D10-2203 补 (b)）。
    public func dismissDialog(_ dialog: PhoneChangeDialog) {
        guard alive, state.dialog == dialog else { return }
        state.dialog = nil
        if case .unavailable = dialog {
            host?.closePhoneChange(self)
        }
    }

    /// 30414【联系客服】、44001【联系客服申诉】：统一客服出口；30414 之后同样回设置页。
    public func contactService(_ dialog: PhoneChangeDialog) {
        guard alive, state.dialog == dialog else { return }
        switch dialog {
        case .unavailable:
            state.dialog = nil
            deps.env.customerService(from: Self.csRoute)
            host?.closePhoneChange(self)
        case .risk:
            state.dialog = nil
            deps.env.customerService(from: Self.csRoute)
        case .abandon:
            break
        }
    }

    // MARK: - 工具

    func nextId() -> Int {
        serial += 1
        return serial
    }

    func notice(_ key: String, assertive: Bool = true) -> MeNotice {
        MeNotice(key, id: nextId(), assertive: assertive)
    }

    /// 30411 换号专句（brief §11 第 8 项），字典没有时回落 error.30411。
    static var phoneTakenKey: String {
        DefaultTexts.text("error.30411.phone_change") != nil ? "error.30411.phone_change" : "error.30411"
    }

    /// 44001 弹窗标题：字典有 risk_msg.<code> 用它，回落 error.44001（G42：快照没有 risk_msg.*）。
    static func riskTitleKey(_ data: Data?) -> String {
        let object = (WalletJSON.parse(data) as? [String: Any]) ?? [:]
        if let code = object["risk_msg_code"] as? String, DefaultTexts.text("risk_msg.\(code)") != nil {
            return "risk_msg.\(code)"
        }
        return "error.44001"
    }

    func showUnavailable() {
        state.dialog = .unavailable(id: nextId())
    }
}
