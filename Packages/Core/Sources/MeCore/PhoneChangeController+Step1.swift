import CouliNetwork
import Foundation
import WalletCore

/// 第 1 步：验证当前手机号（brief §1；锁 d47f660e5：step_up 发码不带 phone，phone_change 验证不带 summary）。发码与验证分开限流
/// （共性第 26 条）：【获取验证码】只看 `gates.sms`、倒计时与在途，【下一步】只看 `gates.verify`；两把闸门、发码截止时间与共享结算都是钱包
/// 那一份（共性第 31 条）。能不能发只看 phone_bound（D10-1682 ②：已知 false 不发）。验证得到的 token 只放本流程内存（不写
/// StepUpTokenCache、不进页面状态与日志），带失效世代：验证在途时别处绑定成功（世代推进）→ 迟到的 token 丢弃（共性第 43 条）。
extension PhoneChangeController {
    /// 本账号 phone_change 的发码槽位（与 10003 面板同一写法：账号 + 号码键 + action）。
    var oldSlot: SmsDeadlines.Slot? {
        guard let account = walletOwner.account else { return nil }
        let phone = wallet.env.stepUpPhone(account: account) ?? StepUpController.phoneChangeBoundSlot
        return SmsDeadlines.Slot.stepUp(account: account, phone: phone, action: Self.action)
    }

    /// 【获取验证码】/【重新获取】。
    public func requestOldCode(version: Int) {
        guard accepts(version), state.step == .step1, state.dialog == nil, !state.oldSending,
              state.oldResendLeftSec == 0,
              let slot = oldSlot
        else { return }
        guard !phoneUnbound else {
            state.oldError = notice(DeleteAccountController.noPhoneKey)
            return
        }
        guard !wallet.gates.sms.active else {
            state.oldError = notice(MeCodes.rateKey)
            return
        }
        // 同一槽位的截止时间还没到（面板或上一次刚发过）：不再发，恢复倒计时（共性第 6 条）
        let left = wallet.sms.remaining(slot, now: wallet.env.nowMillis())
        if left > 0 {
            countdownOld(to: wallet.env.nowMillis() + left)
            return
        }
        // 同一槽位已有在途发码（面板、连点）：不再发
        guard let ticket = wallet.sms.acquire(slot) else { return }
        state.oldSending = true
        state.oldError = nil
        let probe = wallet.gates.sms.probe()
        let body = WalletJSON.text(["purpose": StepUpController.purpose, "action": Self.action])
        let call = ApiCall(operationId: StepUpController.sendOperation, body: body, requiresSession: true)
        let (wallet, walletOwner, scopeStill, gen) = (wallet, walletOwner, scopeStill, stepGen)
        Task { @MainActor [weak self] in
            let result = await wallet.api.send(
                call, isValid: { true }, sendAllowed: probe.allowed, expected: walletOwner.request
            )
            // 共享结算按发起时的身份完成，不依赖子页是否还在（共性第 27、40 条）；作用域已变不写禁用期（共性第 49 条）
            wallet.settlement.settleStepUpRetryAfter(
                result, gate: wallet.gates.sms, owner: walletOwner, scopeStill: scopeStill
            )
            let deadline = wallet.settlement.settleStepUpSms(
                slot: slot, ticket: ticket, result: result, arrived: wallet.env.nowMillis(), owner: walletOwner,
                sms: wallet.sms, gate: wallet.gates.sms
            )
            self?.oldSent(result, deadline: deadline, probe: probe, gen: gen)
        }
    }

    private func oldSent(_ result: ApiResult, deadline: Int64?, probe: SendProbe, gen: Int) {
        guard alive, gen == stepGen, state.step == .step1 else { return }
        state.oldSending = false
        if case .success = result, let deadline {
            state.oldError = nil
            countdownOld(to: deadline)
            // 「已发送」礼貌播报（T14）
            state.announce = notice("step_up.sent", assertive: false)
            return
        }
        if Self.code(result) == 30414 {
            showUnavailable()
            return
        }
        state.oldError = failure(result, probe: probe)
    }

    /// 输入（只留数字，最多 6 位）。
    public func oldCode(_ text: String, version: Int) {
        guard accepts(version), state.step == .step1, !state.verifying else { return }
        state.oldCode = String(text.filter { $0.isASCII && $0.isNumber }.prefix(StepUpUiState.codeLength))
    }

    /// 【下一步】：stepUp {action: phone_change, code}。
    public func next(version: Int) {
        guard accepts(version), nextEnabled else { return }
        let body = StepUpSummary.verifyBody(action: Self.action, code: state.oldCode, summary: nil)
        let probe = wallet.gates.verify.probe()
        state.verifying = true
        state.oldError = nil
        let (wallet, walletOwner, scopeStill) = (wallet, walletOwner, scopeStill)
        let (gen, epoch) = (stepGen, bind.tokenEpoch())
        Task { @MainActor [weak self] in
            let result = await wallet.api.send(
                ApiCall(operationId: StepUpController.verifyOperation, body: body), isValid: { true },
                sendAllowed: probe.allowed, expected: walletOwner.request
            )
            // 42901 先按发起时的身份写进与所有面板共用的 gates.verify（共性第 31 条；作用域已变不写，共性第 49 条）
            wallet.settlement.settleStepUpRetryAfter(
                result, gate: wallet.gates.verify, owner: walletOwner, scopeStill: scopeStill
            )
            self?.verified(result, probe: probe, gen: gen, epoch: epoch)
        }
    }

    private func verified(_ result: ApiResult, probe: SendProbe, gen: Int, epoch: UInt64) {
        guard alive, gen == stepGen, state.step == .step1 else { return }
        state.verifying = false
        // 验证在途时 token 已被作废（别处绑定成功、成功结算）：迟到的 token 丢弃，不进第 2 步（共性第 43 条）
        guard epoch == bind.tokenEpoch() else { return }
        if case let .success(data, _, _) = result, let parsed = WalletJSON.stepUp(WalletJSON.parse(data)) {
            token = PhoneChangeToken(value: parsed.token, epoch: epoch, expireAtMillis: parsed.expireAtMillis)
            enterStep2()
            return
        }
        let code = Self.code(result)
        if code == 30414 {
            showUnavailable()
            return
        }
        if let code, code == 20002 || code == 20003 {
            // 清空输入、assertive 播报（brief §1）
            state.oldCode = ""
            state.oldError = notice("error.\(code)")
            return
        }
        state.oldError = Self.isSuccess(result) ? notice("error.50001") : failure(result, probe: probe)
    }

    private func enterStep2() {
        // 这次的验证码已经用掉：本槽位的「重新获取」倒计时作废，之后 10003 面板可以立即发新码（交回「测试 / 口径」第 1 条）
        if let slot = oldSlot, wallet.sms.remaining(slot, now: wallet.env.nowMillis()) > 0 {
            wallet.sms.start(slot, deadline: wallet.env.nowMillis())
        }
        stepGen += 1
        oldTicker?.cancel()
        oldTicker = nil
        state.oldCode = ""
        state.oldError = nil
        state.oldSending = false
        state.oldResendLeftSec = 0
        state.step = .step2
        resetStep2()
        state.version += 1
    }

    /// 回到第 1 步时按共享截止时间恢复倒计时。
    func restoreOldCountdown() {
        guard let slot = oldSlot else { return }
        let left = wallet.sms.remaining(slot, now: wallet.env.nowMillis())
        if left > 0 {
            countdownOld(to: wallet.env.nowMillis() + left)
        } else {
            state.oldResendLeftSec = 0
        }
    }

    func countdownOld(to deadline: Int64) {
        oldResendUntil = deadline
        oldTicker?.cancel()
        state.oldResendLeftSec = max(0, (deadline - wallet.env.nowMillis() + 999) / 1000)
        let gen = stepGen
        oldTicker = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, alive, gen == stepGen {
                let left = max(0, (oldResendUntil - wallet.env.nowMillis() + 999) / 1000)
                state.oldResendLeftSec = left
                if left == 0 {
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// 发码 / 验证失败的页内提示（20002 / 20003 assertive；被作废的静默；强更由网络层分流）。
    func failure(_ result: ApiResult, probe: SendProbe) -> MeNotice? {
        let error = MeErrors.of(result, probe: probe)
        switch error.kind {
        case .cancelled, .forceUpdate:
            return nil
        case .gated, .retryAfter:
            return notice(MeCodes.rateKey)
        default:
            return MeErrors.notice(error, id: nextId())
        }
    }

    static func code(_ result: ApiResult) -> Int? {
        if case let .failure(code, _, _, _, _, _) = result {
            return code
        }
        return nil
    }

    static func isSuccess(_ result: ApiResult) -> Bool {
        if case .success = result {
            return true
        }
        return false
    }
}
