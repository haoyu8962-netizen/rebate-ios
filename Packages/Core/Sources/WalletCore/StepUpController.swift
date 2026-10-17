import CouliNetwork
import Foundation

/// 二次验证面板的状态（WithdrawStepUp；BR-ID-08、BR-WDR-01）。`phase`：sending（正在发码）、ready（可输入）、noPhone（本机取不到号码，
/// 不发码，iOS I01）、verifying（正在验证）。`resendLeftSec` 为 0 时可重新获取。
public struct StepUpUiState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case sending, ready, noPhone, verifying
    }

    public static let codeLength = 6

    public let action: String
    public var phase: Phase
    public var code = ""
    public var resendLeftSec: Int64 = 0
    public var error: Notice?
    public var awaitingIdentity = false
    public var showsSending: Bool {
        phase == .sending && !awaitingIdentity
    }

    public var showsVerifying: Bool {
        phase == .verifying && !awaitingIdentity
    }

    public var showsRecheck: Bool {
        awaitingIdentity
    }

    /// 面板实例编号（每次打开换新）：面板上的回调带渲染时的编号，执行时核对（APP-11 第 28 条）。
    public let instance: Int
    /// 打开面板的提交 / 确认所属的身份（APP-09 共性第 60 条）：发码、重新获取、验证、读取手机号、占用发码槽位、发包前都核对它仍是当前会话，
    /// 并按它取号码、带账号；不重新绑定执行时的会话。
    public let owner: WalletOwner

    public var canVerify: Bool {
        !awaitingIdentity && phase == .ready && code.count == Self.codeLength
    }
}

/// 二次验证执行器（短信方式；第三方方式只给注销，不在本任务）：打开即对当前 action 发码（sendSmsCode {phone, purpose: step_up, action}），
/// 号码由 App 按账号归属给（`WalletEnv.stepUpPhone`，取不到不发码、不让用户另填）；倒计时按 resend_after_sec（未返回按 60 秒）；输满 6 位才能
/// 【验证并提交】→ stepUp {action, code}，成功把 token 交给发起方（发起方沿用原键重放）。20002 / 20003 清空输入并 assertive 播报；发码与
/// 验证的 42901 分开限流（执行层发送前闸门 + 页面置灰）。面板出现期间属于敏感浮层，关闭后迟到的结果只丢弃。只在主线程使用。
@MainActor
public final class StepUpController: ObservableObject {
    public static let sendOperation = "sendSmsCode"
    public static let verifyOperation = "stepUp"
    public static let purpose = "step_up"
    public static let defaultResendSec: Int64 = 60

    @Published public internal(set) var state: StepUpUiState?
    let deps: WalletDeps
    var alive: () -> Bool
    var instance = 0
    var serial = 0
    var onToken: ((String) -> Void)?
    var onClosed: (() -> Void)?
    var ticker: Task<Void, Never>?
    var resendUntil: Int64 = 0
    let requests = WalletRequests()
    let tasks = SettlingTasks()
    let deferral = IdentityDeferral()
    var waitOther: (() -> Void)?

    init(deps: WalletDeps, alive: @escaping () -> Bool) {
        self.deps = deps
        self.alive = alive
    }

    public var showing: Bool {
        state != nil
    }

    /// 打开面板并发码。`owner` 是打开它的提交 / 确认的身份（共性第 60 条）。
    func open(action: String, owner: WalletOwner, onToken: @escaping (String) -> Void, onClosed: @escaping () -> Void) {
        instance += 1
        self.onToken = onToken
        self.onClosed = onClosed
        state = StepUpUiState(action: action, phase: .sending, instance: instance, owner: owner)
        deps.env.sensitiveOverlay(true)
        send()
    }

    /// 面板上的回调都带渲染时面板的实例与身份（共性第 60、63 条）：不是这个面板的、或已不是当前会话的不受理。
    func owns(_ current: StepUpUiState, instance: Int) -> Bool {
        current.instance == instance && !current.awaitingIdentity && deps.env.isCurrent(current.owner)
    }

    /// 输入回调（渲染时的面板实例）：只留数字，最多 6 位。
    public func onCodeChange(_ text: String, instance: Int) {
        guard var current = state, owns(current, instance: instance), current.phase != .verifying else { return }
        current.code = String(text.filter { $0.isASCII && $0.isNumber }.prefix(StepUpUiState.codeLength))
        state = current
    }

    /// 【重新获取】（倒计时结束、发码禁用期外）。
    public func resend(instance: Int) {
        guard let current = state, owns(current, instance: instance), current.resendLeftSec == 0,
              !deps.gates.sms.active, current.phase == .ready
        else { return }
        send()
    }

    /// 【验证并提交】。
    public func verify(instance: Int) {
        guard var current = state, owns(current, instance: instance), current.canVerify,
              current.owner.account != nil
        else { return }
        if deps.gates.verify.active {
            current.error = notice("error.42901")
            state = current
            return
        }
        let owner = current.owner
        current.phase = .verifying
        current.error = nil
        state = current
        let body = WalletJSON.text(["action": current.action, "code": current.code])
        let probe = deps.gates.verify.probe()
        let panel = instance
        let deps = deps
        requests.send(deps.api, ApiCall(operationId: Self.verifyOperation, body: body), probe: probe,
                      expected: owner.request) { [weak self] result in
            // 42901 先按归属写入共享禁用期（会话级，不依赖面板存活），再看面板是否有效（共性第 27、40、66 条）
            deps.settlement.settleRetryAfter(result, gate: deps.gates.verify, owner: owner)
            self?.verifiedArrived(result, panel: panel, current: current, probe: probe)
        }
    }

    func verifiedArrived(_ result: ApiResult, panel: Int, current: StepUpUiState, probe: SendProbe) {
        guard let account = current.owner.account, admit(panel, current.owner, resume: { [weak self] in
            self?.verifiedArrived(result, panel: panel, current: current, probe: probe)
        }) else { return }
        onVerified(result, account: account, action: current.action, probe: probe)
    }

    /// 固定面板的结果只延后采用；重试只请 App 核对身份。
    func admit(_ panel: Int, _ owner: WalletOwner, waiting: Bool = false,
               resume: @escaping @MainActor () -> Void) -> Bool {
        guard alive(), panel == instance, state != nil else { return false }
        let check = waiting ? IdentityCheck.unknown : deps.env.check(owner)
        guard deferral.admit(check, slot: "panel", resume: resume, settle: {
            state?.awaitingIdentity = true
            state?.error = nil
        }) else { return false }
        state?.awaitingIdentity = false
        return true
    }

    public func recheckIdentity(instance: Int) {
        guard state?.instance == instance, state?.awaitingIdentity == true else { return }
        deps.env.recheckIdentity()
    }

    public func resumeAfterIdentityConfirmed() {
        deferral.resume()
    }

    public func whenIdle() async {
        repeat {
            await tasks.whenIdle()
            await requests.settling.whenIdle()
        } while !tasks.isIdle || !requests.settling.isIdle
    }

    func onVerified(_ result: ApiResult, account: String, action: String, probe: SendProbe) {
        guard var current = state else { return }
        if case let .success(data, _, _) = result, let parsed = WalletJSON.stepUp(WalletJSON.parse(data)) {
            deps.tokens.put(action: action, account: account, token: parsed.token, expireAtMs: parsed.expireAtMillis)
            let deliver = onToken
            dismiss()
            deliver?(parsed.token)
            return
        }
        var clear = false
        if case let .failure(code, _, _, _, _, _) = result {
            clear = code == 20002 || code == 20003
        }
        current.phase = .ready
        if clear {
            current.code = ""
        }
        if case .success = result {
            current.error = notice("error.50001")
        } else {
            current.error = failure(result, probe: probe)
        }
        state = current
    }

    /// 用户点【关闭】（点遮罩、下滑不关闭；系统返回、读屏擦除走同一出口）。`instance` 是渲染时的面板实例（APP-11 第 17 条）。
    public func close(instance: Int) {
        guard let current = state, current.instance == instance else { return }
        let closed = onClosed
        dismiss()
        closed?()
    }

    /// 收起面板（拿到 token、会话换代、离页）：在途的验证作废，迟到的结果只丢弃；已发出的发码照常结算共享倒计时（共性第 40 条）。
    func dismiss() {
        deferral.reset()
        instance += 1
        ticker?.cancel()
        ticker = nil
        requests.cancelAll()
        waitOther?()
        waitOther = nil
        if state != nil {
            deps.env.sensitiveOverlay(false)
        }
        state = nil
        onToken = nil
        onClosed = nil
    }

    func notice(_ key: String) -> Notice {
        serial += 1
        return Notice(key, id: serial)
    }

    func failure(_ result: ApiResult, probe: SendProbe) -> Notice? {
        let error = WalletErrors.of(result, probe: probe)
        switch error.kind {
        case .cancelled:
            return nil
        case .gated, .retryAfter:
            // 禁用期已在结果回来时按归属写入；本请求被发送前限流拦下的同样提示 42901（共性第 62 条）
            return notice("error.42901")
        case .forceUpdate:
            return notice("error.10405")
        default:
            serial += 1
            return error.notice(id: serial)
        }
    }
}
