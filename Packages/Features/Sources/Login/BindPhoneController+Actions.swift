import CouliNetwork
import DesignSystem
import Foundation

/// 绑手机页、引导与第三方登录区用到的文案键（契约已有的直接取；其余在 App 草稿表 LoginDraftTexts，TODO(N-26) 待定稿）。
public enum BindPhoneKeys {
    public static let title = "bind_phone.title"
    /// 说明条（与 LoginBindPhoneGuide 正文同一句，契约 invite.bind_phone_guide.body）。
    public static let info = "invite.bind_phone_guide.body"
    public static let codePlaceholder = "bind_phone.code.placeholder"
    public static let countdown = "bind_phone.countdown"
    public static let submit = "bind_phone.submit"
    public static let done = "bind_phone.done"
    public static let canResend = "bind_phone.can_resend"
    public static let mergeTitle = "bind_phone.merge.title"
    public static let mergeBody = "error.30411.mergeable"
    public static let mergeInto = "bind_phone.merge.into"
    public static let mergeAccount = "bind_phone.merge.account"
    public static let mergeCancel = "bind_phone.merge.cancel"
    public static let mergeOK = "bind_phone.merge.ok"
    public static let mergeUnavailable = "bind_phone.merge.unavailable"
    public static let pendingTitle = "pending_confirm.title"
    public static let pendingDesc = "pending_confirm.phone_change.desc"
    public static let pendingAction = "pending_confirm.phone_change.action"
    public static let pendingAbandon = "pending_confirm.abandon"
    public static let pendingAbandonConfirm = "pending_confirm.abandon.confirm"
    public static let pendingAbandonOK = "pending_confirm.abandon.ok"
    public static let pendingAbandonCancel = "pending_confirm.abandon.cancel"
    public static let pendingPhoneLabel = "bind_phone.pending.phone_label"
    public static let pendingTimeLabel = "bind_phone.pending.time_label"
    public static let pendingHint = "bind_phone.pending_hint"
    public static let riskOK = "login.risk_blocked.ok"
    public static let appeal = "cs.appeal_entry"
}

/// 发码、绑定、待确认与并号确认。
public extension BindPhoneController {
    // MARK: - 发码

    /// 【获取验证码】（purpose=bind）。号码不合法本地给 20001 同一文案、不发出（BR-ID-05）。
    func sendCode() {
        guard alive, !sending, pending == nil else { return }
        guard let normalized = normalizedPhone else {
            fieldError("phone", "error.20001.phone_invalid", clearCode: false)
            return
        }
        guard resendRemaining == 0 else { return }
        sending = true
        let form = formGenValue
        let ticket = visibleTicket
        service.sendCode(owner, phone: normalized) { [weak self] result in
            guard let self else { return }
            sending = false
            smsArrived(result, phone: normalized, form: form, ticket: ticket)
        }
    }

    private func smsArrived(_ result: BindSmsResult, phone normalized: String, form: Int, ticket: Int) {
        // 共享倒计时 / 限流已在服务里按固定归属结算；页面只在同一实例、同一表单世代时更新（换号、离页后的旧结果不播报，共性第 11 条）。
        // 字段错误、提示、弹窗、导航与发码成功播报还要**发起时**的页面许可 `ticket`（iOS R2-02，共性第 22、27 条）：隐藏过、场景
        // inactive、被覆盖后到达的只丢弃，回到页面也不补；倒计时的显示与「可以重新获取」的截止时刻照常按共享状态记下
        guard alive else { return }
        now = service.clock()
        guard form == formGenValue else {
            // R3-02：发码在途时编辑过号码（清空再粘回、等价格式）——旧表单的提示、字段错误、发送对象播报都丢弃；但共享倒计时 / 限流
            // 截止时间已变，本实例与固定身份仍有效时按**当前**规范化号码刷新计时器（到期自动恢复【获取验证码】，共性第 30、34 条）
            staleFormSmsArrived(result, phone: normalized)
            return
        }
        let allowed = permitted(ticket)
        switch result {
        case .sent:
            codeSent(normalized, announce: allowed)
        case let .risk(titleKey):
            present(.risk(titleKey: titleKey, id: nextId()), ticket: ticket)
        case .silent:
            break
        default:
            if allowed {
                smsPageUpdate(result)
            }
        }
        restartTickerIfNeeded()
    }

    /// 表单世代已变的发码结果（R3-02）：只重算共享倒计时并启动计时器；当前号码仍是发出的那个号码时照记截止时刻（倒计时走完播报
    /// 「可以重新获取」一次，属于共享倒计时），其余反馈不给。
    private func staleFormSmsArrived(_ result: BindSmsResult, phone normalized: String) {
        guard service.isCurrent(owner) else { return }
        if result == .sent, normalizedPhone == normalized,
           let deadline = service.smsDeadline(owner, phone: normalized) {
            armDeadline(normalized, deadline)
        }
        restartTickerIfNeeded()
    }

    /// 发码结果里只改本页的部分（限流提示、字段错误、导航、提示）：调用方已核对发起时的页面许可。
    private func smsPageUpdate(_ result: BindSmsResult) {
        switch result {
        case .rateLimited:
            notice = show("error.42901", trace6: "")
        case let .field(field, textKey):
            fieldError(field, textKey, clearCode: false)
        case let .navigate(route):
            hooks.open(route)
        case let .notice(textKey, trace6):
            notice = show(textKey, trace6: trace6)
        default:
            break
        }
    }

    /// 发码成功：记下这个号码与截止时刻（倒计时走完播报一次），持有发起时的页面许可才播报一次脱敏的发送对象（共性第 11、27 条）。
    private func codeSent(_ normalized: String, announce: Bool) {
        if let deadline = service.smsDeadline(owner, phone: normalized) {
            armDeadline(normalized, deadline)
        }
        if announce {
            hooks.announce(texts.format(LoginKeys.codeSentTo, ["phone": PhoneNumber.masked(normalized)]))
        }
    }

    // MARK: - 绑定

    /// 【绑定】：号码合法、6 位码齐全才发；写请求离页不取消。
    func submit() {
        guard alive, canSubmit, let normalized = normalizedPhone else {
            if alive, service.writeGated(owner) {
                notice = show("error.42901", trace6: "")
            }
            return
        }
        submitting = true
        notice = nil
        let ticket = visibleTicket
        // 发起时的表单世代与提交号码（R1-05）、验证码修订号（R2-03）：在途允许改号改码；回来时号码已换的，旧字段错误与并号结果丢弃；
        // 验证码已改的，旧验证码字段错误（20002 / 20003 及清码）丢弃
        let form = FormStamp(gen: formGenValue, phone: normalized, codeRev: codeRevValue)
        service.submit(owner, phone: normalized, code: code) { [weak self] action in
            guard let self else { return }
            submitting = false
            apply(action, ticket: ticket, phone: normalized, form: form)
        }
    }

    /// 首次提交发起时的表单（世代 + 规范化号码 + 验证码修订号）。
    internal struct FormStamp: Equatable {
        let gen: Int
        let phone: String
        let codeRev: Int
    }

    /// 此刻的表单仍是 `form` 那一份（同一世代、同一号码）；nil（确认 / 放弃，与表单无关）恒为是。
    internal func formCurrent(_ form: FormStamp?) -> Bool {
        guard let form else { return true }
        return form.gen == formGenValue && form.phone == normalizedPhone
    }

    /// 此刻的验证码仍是 `form` 提交的那一份（修订号未变，R2-03）；nil 恒为是。
    internal func codeCurrent(_ form: FormStamp?) -> Bool {
        guard let form else { return true }
        return form.codeRev == codeRevValue
    }

    /// 写请求的结局（首次提交、确认、放弃共用；共享结算已在服务里完成）：页面只在本实例存活时更新；导航、弹窗、提示、字段错误都要求
    /// **发起时**捕获的页面许可 `ticket`（R1-04，APP-13a 共性第 23 条）——许可失效的只丢弃，不暂存、不补弹（并号凭据不保留），待确认卡
    /// 按共享的本机未决记录重读。首次提交另核对表单（R1-05）。成功的出栈例外：延后到回到栈顶（APP-09 共性第 41 条）。
    internal func apply(_ action: BindPageAction, ticket: Int, phone: String?, form: FormStamp? = nil) {
        guard alive else { return }
        let sameForm = formCurrent(form)
        switch action {
        case .done:
            // 成功的出栈（APP-09 共性第 41 条）：发起时的许可失效也不丢——页面此刻已恢复就立即按完成前置退出一次，仍隐藏才延后到回到
            // 栈顶（R3-01：「成功先到」与「页面先恢复」两种顺序）；退出前重核完整身份与共享已绑；页面已离开就不再导航（G66）
            boundArrived(.prerequisiteDone)
        case let .merge(ticket: mergeTicket):
            // 换号后的旧并号结果丢弃（不在新号码的表单上弹旧号码的并号）
            if sameForm {
                let masked = phone.map(PhoneNumber.masked) ?? pending?.maskedPhone ?? ""
                present(.merge(ticket: mergeTicket, phone: masked, id: nextId()), ticket: ticket)
            }
            refreshPending()
        case let .risk(titleKey):
            present(.risk(titleKey: titleKey, id: nextId()), ticket: ticket)
        case let .field(field, textKey, clearCode):
            // 换号后的旧字段错误丢弃（20003 不清掉新号码的验证码）；同号换码后，旧码的验证码错误不显示在新码上、不清新码（R2-03）
            if sameForm, field != "code" || codeCurrent(form), permitted(ticket) {
                fieldError(field, textKey, clearCode: clearCode)
            }
        default:
            applyOther(action, ticket: ticket)
        }
    }

    /// 提示、导航、待确认、重置与静默：都按本机未决记录重读待确认卡。
    private func applyOther(_ action: BindPageAction, ticket: Int) {
        let allowed = permitted(ticket)
        switch action {
        case let .notice(textKey, trace6):
            if allowed {
                notice = show(textKey, trace6: trace6)
            }
        case let .navigate(route):
            if allowed {
                hooks.open(route)
            }
        case let .pending(noticeKey, trace6):
            if allowed {
                pendingNotice = noticeKey.map { show($0, trace6: trace6) }
            }
        case let .reset(textKey):
            // 键已结束是共享状态（卡片按未决记录重读）；清验证码与提示是页面更新，要原许可
            if allowed {
                pending = nil
                code = ""
                toast = CouliToastMessage(text(textKey))
            }
        default:
            break
        }
        refreshPending()
    }

    /// 异步结果的弹窗：只在发起时捕获的页面许可 `ticket` 仍有效时展示（R1-04，APP-13a 共性第 23 条）；许可已失效（隐藏过、被覆盖、
    /// 场景 inactive、出栈、换代）的丢弃，不暂存、不在回到页面时补弹。
    internal func present(_ next: BindDialog, ticket: Int) {
        if permitted(ticket) {
            dialog = next
        }
    }

    internal func fieldError(_ field: String, _ key: String, clearCode: Bool) {
        if field == "code" {
            codeError = text(key)
            if clearCode {
                code = ""
            }
        } else {
            phoneError = text(key)
        }
        fieldEvent = BindFieldEvent(id: nextId(), field: field)
        // 字段错误即时播报一次（焦点由页面移到错误提示，错误说明关联到输入框，输入保留；共性第 6 条）
        if visibleNow {
            hooks.announce(field == "code" ? codeError ?? "" : phoneError ?? "")
        }
    }

    // MARK: - 待确认（G07）

    /// 按本机未决记录重读待确认卡（进入、回前台、未决通知、每次写请求结束后）。
    func refreshPending() {
        guard alive else { return }
        let owner = owner
        let service = service
        Task { @MainActor [weak self] in
            let lookup = await service.pendingStatus(owner)
            guard let self, alive else { return }
            switch lookup {
            case let .record(record) where record.stateRaw == PendingKeyStore.unknown:
                pendingUnreadable = false
                pendingBusy = false
                let summary = LoginService.object(record.summary.data(using: .utf8))
                pending = BindPendingCard(
                    key: record.key, maskedPhone: summary["phone"] as? String ?? "",
                    submittedAtMillis: record.createdAtMillis
                )
            case .record:
                // 本进程仍在发送（in_flight）：按提交中显示（G63）
                pendingUnreadable = false
                pendingBusy = true
            case .unreadable:
                pendingUnreadable = true
                pendingBusy = false
            case .none:
                pendingUnreadable = false
                pendingBusy = false
                if pending != nil {
                    pending = nil
                    pendingNotice = nil
                }
            }
        }
    }

    /// 【确认上一次提交】：回调携带渲染时的卡片原键，执行时只比较（APP-09 共性第 14 条）。
    func confirmPending(key: String) {
        guard alive, let card = pending, card.key == key, !pendingBusy else { return }
        // phoneGate 禁用中：与按钮同一禁用状态（R1-03），只提示稍后再试，不发；发送前检查照留在服务里
        guard !service.writeGated(owner) else {
            pendingNotice = show(SensitiveTexts.retryLater, trace6: "")
            return
        }
        pendingBusy = true
        pendingNotice = nil
        let ticket = visibleTicket
        service.confirm(owner, key: key) { [weak self] action in
            guard let self else { return }
            pendingBusy = false
            apply(action, ticket: ticket, phone: nil)
        }
    }

    /// 【放弃上一次提交】：先弹二次确认（绑定点击时的原键）。
    func askAbandon(key: String) {
        guard alive, let card = pending, card.key == key, !pendingBusy else { return }
        guard !service.writeGated(owner) else {
            pendingNotice = show(SensitiveTexts.retryLater, trace6: "")
            return
        }
        dialog = .abandon(key: key, id: nextId())
    }

    /// 二次确认里【确定放弃】：核对弹窗实例编号与原键。
    func confirmAbandon(dialogId: Int) {
        guard alive, case let .abandon(key, id) = dialog, id == dialogId, pending?.key == key else { return }
        dialog = nil
        pendingBusy = true
        pendingNotice = nil
        let ticket = visibleTicket
        service.abandon(owner, key: key) { [weak self] action in
            guard let self else { return }
            pendingBusy = false
            apply(action, ticket: ticket, phone: nil)
        }
    }

    // MARK: - 并号确认（BindPhoneMerge）

    /// 【并入】：锁定契约没有 POST /v1/auth/merge（TODO(N-29) MERGE-SUCCESS）——不发请求、不并号、不保存会话，提示暂不可用；凭据作废。
    func confirmMerge(dialogId: Int) {
        guard alive, case let .merge(_, _, id) = dialog, id == dialogId else { return }
        dialog = nil
        let result = MergeDecision.apply(decision: MergeDecision.confirm, response: nil)
        if result.resultRaw == MergeDecision.unavailable {
            toast = CouliToastMessage(text(BindPhoneKeys.mergeUnavailable))
        }
    }

    /// 【取消】：不并号、不保存会话，留在本页，手机号与验证码保留。
    func cancelMerge(dialogId: Int) {
        guard alive, case let .merge(_, _, id) = dialog, id == dialogId else { return }
        dialog = nil
    }

    /// 关闭其他弹窗（风控【知道了】、放弃确认【再想想】）。
    func dismissDialog(dialogId: Int) {
        guard dialog?.id == dialogId else { return }
        dialog = nil
    }

    /// 风控弹窗【联系客服申诉】（统一客服出口）。
    func appeal(dialogId: Int) {
        guard alive, dialog?.id == dialogId else { return }
        dialog = nil
        hooks.contactService()
    }

    /// 并号正文（{provider_name}：本会话最近一次第三方登录的方式；不知道时用契约 fallback）。
    func mergeBody() -> String {
        let name = hooks.providerName(owner.request.generation) ?? ""
        return texts.format(BindPhoneKeys.mergeBody, ["provider_name": name])
    }

    /// 左上角返回。
    func back() {
        hooks.back(entryId)
    }
}
