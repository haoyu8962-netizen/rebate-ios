import CouliNetwork
import Foundation

/// 换手机号（APP-13a-2，D10-2203 ②）复用钱包的二次验证控制器与共享结算：这里只给「我的」Core（MeCore）开放已有内部入口的可见性，
/// 不加新逻辑、不改已有文件——提现、收款账号、注销的调用点与行为一行不动（零变化由 App13a2WalletZeroChangeTests 与已有资金用例钉住）。
/// - 换号页提交 / 确认得到 10003 时弹的面板：`phoneChange` 构造（action = phone_change，发码 / 验证共用 `gates.sms`、`gates.verify`、
///   `SmsDeadlines`，验证不带 summary：契约 phone_change 不绑摘要）、`openPhoneChange` 打开、`detach` 收起；
/// - 换号第 1 步（页内验证当前手机号，不是面板）：发码 / 验证的 42901 与发码截止时间经 `settleStepUpRetryAfter`、`settleStepUpSms`
///   交同一个会话级 `WalletSettlement` 结算（与面板同一套共享状态，共性第 26、31 条）。
public extension StepUpController {
    /// step_up_action 枚举里的换手机号。
    nonisolated static let phoneChangeAction = "phone_change"

    /// 发码槽位里代表「账号当前绑定的手机号」的占位（同 `boundSlot`；App 没给槽位键时用）。
    static var phoneChangeBoundSlot: String {
        boundSlot
    }

    /// 换号页的 10003 面板执行器。`alive`：所属换号页仍有效；`scopeStill`：换号页构造时固定的会话作用域此刻仍未变（作用域已变时发码 /
    /// 验证的 42901 不写共享禁用期，同注销面板，FU-IOS-WALLETSETTLEMENT-SCOPE）。
    static func phoneChange(
        deps: WalletDeps, alive: @escaping () -> Bool, scopeStill: (@Sendable () -> Bool)?
    ) -> StepUpController {
        let controller = StepUpController(deps: deps, alive: alive)
        controller.scopeStill = scopeStill
        return controller
    }

    /// 打开面板并发码（action = phone_change，不带 summary）。`owner` 是发起这次提交 / 确认的固定身份。
    func openPhoneChange(owner: WalletOwner, onToken: @escaping (String) -> Void, onClosed: @escaping () -> Void) {
        open(action: Self.phoneChangeAction, owner: owner, summary: nil, onToken: onToken, onClosed: onClosed)
    }

    /// 收起面板（换号页离开、换代、结局落定）：在途验证作废，已发出的发码照常结算共享倒计时（同 `dismiss`）。
    func detach() {
        dismiss()
    }
}

public extension SmsDeadlines.Slot {
    /// 二次验证发码槽位（账号、号码键、action），与面板 `send()` 的槽位同一写法。
    static func stepUp(account: String, phone: String, action: String) -> SmsDeadlines.Slot {
        SmsDeadlines.Slot(account: account, phone: phone, action: action)
    }
}

public extension WalletSettlement {
    /// 发码 / 验证的 42901 按发起时的身份写共享禁用期（即 `settleRetryAfter`，面板是否还在都写）。
    func settleStepUpRetryAfter(
        _ result: ApiResult, gate: RetryAfterGate, owner: WalletOwner, scopeStill: (@Sendable () -> Bool)?
    ) {
        settleRetryAfter(result, gate: gate, owner: owner, scopeStill: scopeStill)
    }

    /// 发码结果的共享结算（即 `settleSms`：截止时间取到达时刻，释放本次占用）。返回成功时的重新获取截止时间（不是成功为 nil），
    /// 页面只在自己仍有效时拿它起倒计时。
    @discardableResult
    func settleStepUpSms(_ sent: StepUpSmsSent, owner: WalletOwner, sms: SmsDeadlines, gate: RetryAfterGate) -> Int64? {
        let arrival = SmsArrival(slot: sent.slot, ticket: sent.ticket, result: sent.result, arrived: sent.arrived)
        settleSms(arrival, owner: owner, sms: sms, gate: gate)
        return arrival.deadline
    }
}

/// 一次发码的结果与到达时刻（`settleStepUpSms` 的入参；同内部 `SmsArrival`）：槽位、占用票据、结果、到达时刻。
public struct StepUpSmsSent: Sendable {
    public let slot: SmsDeadlines.Slot
    public let ticket: Int
    public let result: ApiResult
    public let arrived: Int64

    public init(slot: SmsDeadlines.Slot, ticket: Int, result: ApiResult, arrived: Int64) {
        self.slot = slot
        self.ticket = ticket
        self.result = result
        self.arrived = arrived
    }
}
