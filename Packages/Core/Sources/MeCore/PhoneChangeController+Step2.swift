import CouliNetwork
import Foundation
import WalletCore

/// 第 2 步：验证新手机号并提交（brief §1）。新号只去首尾空白、原样提交（G33）；bind 发码的截止时间按规范化号码与 BindPhone 页共用
/// （共性第 15、30 条）；每次点【提交】生成新键，带第 1 步 token（未过期、失效世代未变才带）；10003 → 面板 → 原键原体 + 新 token 重放 1 次，
/// 重放再遇 10003 不循环（共性第 17 条）。摘要只放本机脱敏的新号（G24）。
extension PhoneChangeController {
    /// 新号输入（提交中不改）。号码一变就按共享截止时间显示这个号码的倒计时。
    public func newPhone(_ text: String, version: Int) {
        guard accepts(version), state.step == .step2, !state.submitting else { return }
        state.newPhone = text
        state.phoneError = nil
        syncNewCountdown()
    }

    /// 验证码输入（只留数字，最多 6 位）。
    public func newCode(_ text: String, version: Int) {
        guard accepts(version), state.step == .step2, !state.submitting else { return }
        state.newCode = String(text.filter { $0.isASCII && $0.isNumber }.prefix(StepUpUiState.codeLength))
        state.codeError = nil
    }

    /// 第 2 步【获取验证码】（purpose = bind）。号码不合法本地给 20001 同一句、不发（同 BindPhone 页）。
    public func requestNewCode(version: Int) {
        guard accepts(version), state.step == .step2, !state.newSending, !state.submitting else { return }
        guard let phone = MePhone.normalize(state.newPhone) else {
            state.phoneError = notice("error.20001.phone_invalid")
            return
        }
        guard bind.smsRemainingSec(owner, phone: phone) == 0, !bind.smsSending(owner, phone: phone) else {
            syncNewCountdown()
            return
        }
        state.newSending = true
        state.notice = nil
        let gen = formGen
        bind.sendCode(owner, phone: phone) { [weak self] result in
            self?.newSmsArrived(result, gen: gen)
        }
    }

    /// 共享倒计时已在服务里按固定身份结算；页面只在同一实例、同一表单世代时更新（共性第 28、35 条：迟到的发码只结算倒计时）。
    private func newSmsArrived(_ result: PhoneBindSms, gen: Int) {
        guard alive, gen == formGen, state.step == .step2 else { return }
        state.newSending = false
        syncNewCountdown()
        switch result {
        case .sent:
            state.newCodeSent = true
            state.announce = notice("phone_change.new_sent", assertive: false)
        case .rateLimited:
            state.notice = notice(MeCodes.rateKey)
        case let .field(textKey):
            state.phoneError = notice(textKey)
        case let .risk(titleKey):
            state.newCode = ""
            state.dialog = .risk(titleKey: titleKey, id: nextId())
        case let .navigate(route):
            deps.env.open(route, params: [:], from: page)
        case let .notice(textKey, trace6):
            if textKey == "error.30414" {
                showUnavailable()
            } else {
                state.notice = MeNotice(textKey, id: nextId(), traceId: trace6.isEmpty ? nil : trace6,
                                        showTrace6: !trace6.isEmpty)
            }
        case .silent:
            break
        }
    }

    /// 按此刻的新号读共享截止时间、起页面倒计时。
    func syncNewCountdown() {
        newTicker?.cancel()
        newTicker = nil
        guard let phone = MePhone.normalize(state.newPhone) else {
            state.newResendLeftSec = 0
            return
        }
        state.newResendLeftSec = bind.smsRemainingSec(owner, phone: phone)
        guard state.newResendLeftSec > 0 else { return }
        let gen = formGen
        newTicker = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, alive, gen == formGen {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let now = MePhone.normalize(state.newPhone), now == phone else { return }
                state.newResendLeftSec = bind.smsRemainingSec(owner, phone: phone)
                if state.newResendLeftSec == 0 {
                    return
                }
            }
        }
    }

    /// 第 2 步全部瞬时状态重置（返回第 1 步、进第 2 步；新号保留）。
    func resetStep2() {
        formGen += 1
        newTicker?.cancel()
        newTicker = nil
        state.newCode = ""
        state.newSending = false
        state.newCodeSent = false
        state.newResendLeftSec = 0
        state.submitting = false
        state.phoneError = nil
        state.codeError = nil
        state.notice = nil
        syncNewCountdown()
    }

    // MARK: - 提交

    /// 【提交】：每次点击新键；体 {phone: 去首尾空白的原文, code}；摘要 {phone: 本机脱敏}（号码规整不了时不放号码）。
    public func submit(version: Int) {
        guard accepts(version), state.step == .step2, state.pending == nil, !state.submitting, !panel.showing,
              state.newCode.count == StepUpUiState.codeLength, !trimmedPhone.isEmpty
        else { return }
        guard !bind.writeGated(owner) else {
            state.notice = notice(MeCodes.rateKey)
            return
        }
        let phone = trimmedPhone
        let masked = MePhone.normalize(phone).map(MePhone.masked)
        let summary: [String: String] = masked.map { ["phone": $0] } ?? [:]
        let submission = PhoneChangeSubmission(
            key: deps.newKey(), body: WalletJSON.text(["phone": phone, "code": state.newCode]),
            summary: WalletJSON.text(summary), maskedPhone: masked
        )
        send(submission, token: currentToken(), replayed: false)
    }

    func send(_ submission: PhoneChangeSubmission, token: String?, replayed: Bool) {
        state.submitting = true
        state.phoneError = nil
        state.codeError = nil
        state.notice = nil
        let gen = formGen
        bind.submitChange(owner, submission, stepUpToken: token) { [weak self] arrival in
            self?.submitArrived(arrival, submission, replayed: replayed, gen: gen)
        }
    }

    private func submitArrived(_ arrival: PhoneBindArrival, _ submission: PhoneChangeSubmission, replayed: Bool,
                               gen: Int) {
        if arrival.notified {
            ownSettling = true
        }
        // 已离开的页面不改（共享结算已在服务里做完，共性第 25 条）
        guard alive else { return }
        if gen == formGen {
            state.submitting = false
        }
        applySubmit(arrival, submission, replayed: replayed, sameForm: gen == formGen)
    }

    // MARK: - 10003 面板

    /// 提交 / 确认得到 10003：弹面板（action = phone_change，与第 1 步同一套共享发码 / 验证状态），拿到 token 后原键原体再发 1 次。
    func openPanel(_ intent: PhoneChangePanelIntent) {
        token = nil
        wallet.tokens.on10003(action: Self.action)
        panel.openPhoneChange(owner: walletOwner, onToken: { [weak self] value in
            self?.panelVerified(value, intent)
        }, onClosed: { [weak self] in
            self?.objectWillChange.send()
        })
    }

    private func panelVerified(_ value: String, _ intent: PhoneChangePanelIntent) {
        guard alive else { return }
        switch intent {
        case let .submit(submission):
            guard state.step == .step2 else { return }
            send(submission, token: value, replayed: true)
        case let .confirm(key):
            guard state.step == .pending, state.pending?.key == key else { return }
            state.pendingBusy = true
            state.pendingNotice = nil
            confirm(key: key, token: value, replayed: true)
        }
    }
}
