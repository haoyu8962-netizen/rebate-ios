import CouliNetwork
import Foundation

/// 发码（共性第 6、17、26、27、40、60 条）。
extension StepUpController {
    /// 按面板的身份读号码、占用槽位、发包（共性第 60 条）：会话已换（清空通知还没执行）的不读、不占、不发，等清空通知收起面板。
    func send() {
        guard var current = state, deps.env.isCurrent(current.owner) else { return }
        guard let account = current.owner.account, let phone = deps.env.stepUpPhone(account: account) else {
            // 本机取不到当前账号的号码：不编造、不让用户另填，不发码（iOS I01，G31）
            current.phase = .noPhone
            state = current
            return
        }
        if deps.gates.sms.active {
            current.phase = .ready
            current.error = notice("error.42901")
            state = current
            return
        }
        // 同一账号、号码、action 的发码截止时间还没到（重开面板、别的页面刚发过）：不再发，恢复倒计时（共性第 6 条）
        let slot = SmsDeadlines.Slot(account: account, phone: phone, action: current.action)
        let left = deps.sms.remaining(slot, now: deps.env.nowMillis())
        if left > 0 {
            current.phase = .ready
            state = current
            countdown(to: deps.env.nowMillis() + left)
            return
        }
        // 同一槽位已有在途发码（别的面板、连点）：不再发，等它结束后按共享截止时间恢复（共性第 17、26 条）
        guard let ticket = deps.sms.acquire(slot) else {
            current.phase = .sending
            current.error = nil
            state = current
            awaitOther(slot)
            return
        }
        current.phase = .sending
        current.error = nil
        state = current
        launchSend(slot: slot, ticket: ticket, owner: current.owner, panel: current.instance)
    }

    /// 实际发码：不随面板关闭取消（已发出的码要更新共享倒计时）；结果先按点击时的身份写入共享倒计时 / 限流，再按面板是否有效更新界面；
    /// 结束时只释放本次请求的占用。请求带面板身份的网络归属（共性第 39、60 条）。
    func launchSend(slot: SmsDeadlines.Slot, ticket: Int, owner: WalletOwner, panel: Int) {
        // 发码禁用期是本请求的发送前限流闸门（共性第 62 条）；同一截止时间已在占用槽位前核对（槽位占用期间不会有别的发码改它）
        let probe = deps.gates.sms.probe()
        let body = WalletJSON.text(["phone": slot.phone, "purpose": Self.purpose, "action": slot.action])
        let api = deps.api
        Task { @MainActor [weak self, deps] in
            let result = await api.send(
                ApiCall(operationId: Self.sendOperation, body: body), isValid: { true }, sendAllowed: probe.allowed,
                expected: owner.request
            )
            var deadline: Int64?
            if deps.env.isCurrent(owner), case let .success(data, _, _) = result {
                let seconds = WalletJSON.sendSmsCode(WalletJSON.parse(data))?.resendAfterSec ?? 0
                let resend = seconds > 0 ? seconds : Self.defaultResendSec
                let until = deps.env.nowMillis() + resend * 1000
                deps.sms.start(slot, deadline: until)
                deadline = until
            }
            // 失败限流与成功倒计时一样由任务持有的会话级依赖直接结算（共性第 27、40、66 条）：旧面板关闭、释放后迟到的 42901 也写入共享禁用期
            deps.settlement.settleRetryAfter(result, gate: deps.gates.sms, owner: owner)
            deps.sms.release(slot, ticket: ticket)
            guard let self, valid(panel, owner) else { return }
            onSent(result, deadline: deadline, probe: probe)
        }
    }

    /// 别的面板正在发码：等它结束，按共享截止时间恢复倒计时（不自动再发）。
    func awaitOther(_ slot: SmsDeadlines.Slot) {
        guard let current = state else { return }
        let panel = current.instance
        let owner = current.owner
        waitOther?()
        waitOther = deps.sms.changes.subscribe { [weak self] in
            MainActor.assumeIsolated { self?.otherSettled(slot, panel: panel, owner: owner) }
        }
    }

    func otherSettled(_ slot: SmsDeadlines.Slot, panel: Int, owner: WalletOwner) {
        guard !deps.sms.busy(slot), valid(panel, owner), var now = state else { return }
        waitOther?()
        waitOther = nil
        now.phase = .ready
        state = now
        let left = deps.sms.remaining(slot, now: deps.env.nowMillis())
        if left > 0 {
            countdown(to: deps.env.nowMillis() + left)
        }
    }

    func onSent(_ result: ApiResult, deadline: Int64?, probe: SendProbe) {
        guard var current = state else { return }
        current.phase = .ready
        if case .success = result, let deadline {
            current.error = nil
            state = current
            countdown(to: deadline)
            return
        }
        current.error = failure(result, probe: probe)
        state = current
    }

    func countdown(to deadline: Int64) {
        resendUntil = deadline
        ticker?.cancel()
        let panel = instance
        ticker = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, panel == instance, var current = state {
                let left = max(0, (resendUntil - deps.env.nowMillis() + 999) / 1000)
                current.resendLeftSec = left
                state = current
                if left == 0 {
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
