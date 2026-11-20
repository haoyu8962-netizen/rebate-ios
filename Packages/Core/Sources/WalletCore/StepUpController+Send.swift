import CouliNetwork
import Foundation

/// 一次发码的结果与到达时刻。截止时间只在身份核对放行后才从结果里取：核对不过（stale）时结果体一个字段都不读（D10-1790 ②）。
struct SmsArrival {
    let slot: SmsDeadlines.Slot
    let ticket: Int
    let result: ApiResult
    let arrived: Int64

    /// 成功时的重新获取截止时间（到达时刻起按 resend_after_sec，未返回按 60 秒）；不是成功为 nil。
    var deadline: Int64? {
        guard case let .success(data, _, _) = result else { return nil }
        let seconds = WalletJSON.sendSmsCode(WalletJSON.parse(data))?.resendAfterSec ?? 0
        return arrived + (seconds > 0 ? seconds : StepUpController.defaultResendSec) * 1000
    }
}

/// 发码（共性第 6、17、26、27、40、60 条）。
extension StepUpController {
    /// 按面板的身份读绑定状态、占用槽位、发包（共性第 60 条）：会话已换（清空通知还没执行）的不读、不占、不发，等清空通知收起面板。
    func send() {
        guard var current = state else { return }
        // 打开 / 重新获取那一刻身份就核对不过（stale）：不读、不占、零发送，落到发送失败 + 可重新获取（D10-1792 ③a）
        guard admit(current.instance, current.owner, stale: { sendFailed() },
                    resume: { [weak self] in self?.send() }) else { return }
        current.awaitingIdentity = false
        current.sendFailed = false
        // 能否发码只看 Me.phone_bound（D10-1682 ②，不再看本机是否知道号码）：已知没绑手机不发码、不让用户另填；未知照常发（服务端没绑手机回
        // 20001 data.fields=[code]，D10-1658 ①）。号码不上送，槽位键只作本机发码截止时间与在途占用的键（App 没给用占位）。
        // 本地按 phone_bound 拦只用于改收款 / 换号 / 注销，不碰提现（D10-1667：提现只剩旧后端 10003 兼容路径，交给服务端判）
        let unbound = deps.env.stepUpPhoneBound(current.owner) == false
        let blockUnbound = unbound && current.action != WithdrawController.action
        guard let account = current.owner.account, !blockUnbound else {
            current.phase = .noPhone
            state = current
            return
        }
        let phone = deps.env.stepUpPhone(account: account) ?? Self.boundSlot
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
    /// 结束时只释放本次请求的占用。请求带面板身份的网络归属（共性第 39、60 条）。请求体不带 phone（B1-02zzz：step_up 带 phone 回 20001），
    /// 调用置 `requiresSession`（D10-1658 ④、段 2 评审 S2-1）：受限会话先等刷新，组好的请求没有本人令牌就本地 session_unreadable、零发送。
    func launchSend(slot: SmsDeadlines.Slot, ticket: Int, owner: WalletOwner, panel: Int) {
        // 发码禁用期是本请求的发送前限流闸门（共性第 62 条）；同一截止时间已在占用槽位前核对（槽位占用期间不会有别的发码改它）
        let probe = deps.gates.sms.probe()
        let body = WalletJSON.text(["purpose": Self.purpose, "action": slot.action])
        let api = deps.api
        let scopeStill = scopeStill
        let tasks = tasks
        tasks.begin()
        Task { @MainActor [weak self, deps] in
            defer { tasks.end() }
            let result = await api.send(
                ApiCall(operationId: Self.sendOperation, body: body, requiresSession: true), isValid: { true },
                sendAllowed: probe.allowed,
                expected: owner.request
            )
            // 失败限流与成功倒计时一样由任务持有的会话级依赖直接结算（共性第 27、40、66 条）：旧面板关闭、释放后迟到的 42901 也写入共享禁用期
            // 注销面板另核对所属流程的作用域（作用域已变不写，FU-IOS-WALLETSETTLEMENT-SCOPE）；其余面板 scopeStill 为 nil
            deps.settlement.settleRetryAfter(result, gate: deps.gates.sms, owner: owner, scopeStill: scopeStill)
            let arrival = SmsArrival(slot: slot, ticket: ticket, result: result, arrived: deps.env.nowMillis())
            deps.settlement.settleSms(arrival, owner: owner, sms: deps.sms, gate: deps.gates.sms)
            self?.sentArrived(result, arrival: arrival, panel: panel, owner: owner, probe: probe)
        }
    }

    /// 结果回来时面板身份核对不过（stale：换会话、登出，或同账号同世代此刻没有可用 access）：不交付结果（不读结果体、不起倒计时），
    /// 面板落到发送失败 + 可重新获取（D10-1790）；真换会话 / 登出时随后的会话变化通知照旧收起面板。
    func sentArrived(_ result: ApiResult, arrival: SmsArrival, panel: Int, owner: WalletOwner, probe: SendProbe) {
        let resume: @MainActor () -> Void = { [weak self] in
            self?.sentArrived(result, arrival: arrival, panel: panel, owner: owner, probe: probe)
        }
        guard admit(panel, owner, waiting: deps.sms.awaitingIdentity(arrival.slot), stale: { sendFailed() },
                    resume: resume) else { return }
        onSent(result, deadline: arrival.deadline, probe: probe)
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
        otherSettled(slot, panel: panel, owner: owner)
    }

    /// 那次发码结束时面板身份核对不过（stale）：同 `sentArrived`，不再等、落到发送失败 + 可重新获取（D10-1790；结算对 stale 释放槽位）。
    func otherSettled(_ slot: SmsDeadlines.Slot, panel: Int, owner: WalletOwner) {
        guard !deps.sms.busy(slot) || deps.sms.awaitingIdentity(slot) else { return }
        let resume: @MainActor () -> Void = { [weak self] in
            self?.otherSettled(slot, panel: panel, owner: owner)
        }
        guard admit(panel, owner, waiting: deps.sms.awaitingIdentity(slot), stale: {
            waitOther?()
            waitOther = nil
            sendFailed()
        }, resume: resume), var now = state else { return }
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
        // 本地拒绝、一条没发（发码那一刻会话读得到同一账号却没有可用 access → account_mismatch；会话读不出）：不静默（D10-1790）
        if case let .localReject(reason) = result, Self.unsentRejects.contains(reason) {
            sendFailed()
            return
        }
        current.error = failure(result, probe: probe)
        state = current
    }

    /// 发送失败提示的文案键只在这一处取（D10-1792，待换专用键 step_up.sms.send_failed，换时只动这一行）。
    static let sendFailedKey = WalletErrors.networkKey

    /// 发码没有发出、也不交付结果：停在可输入、提示发送失败（网络错误文案键）、不起倒计时、【重新获取】可点，说明位不显示「已发送」。
    func sendFailed() {
        guard var current = state else { return }
        current.phase = .ready
        current.awaitingIdentity = false
        current.sendFailed = true
        current.error = notice(Self.sendFailedKey)
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
