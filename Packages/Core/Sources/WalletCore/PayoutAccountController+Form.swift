import CouliNetwork
import Foundation

/// 表单输入、保存、成功后的出栈与会话。
public extension PayoutAccountController {
    /// 【更换收款账号】：`version` 与 `shown` 是构建这张卡时捕获的渲染版本与账号身份，点击时都仍匹配才受理（共性第 25 条）。
    func change(version: Int, shown: PayoutAccountDisplay, owner: WalletOwner) {
        guard ownsForm(owner), state.version == version, let account = state.account, account == shown,
              state.loadError == nil, !account.bound || account.known
        else { return }
        state.editing = true
    }

    /// 表单的输入与选择回调都带渲染这张表单时的身份（共性第 59、63 条）：会话已换后到达的旧回调不写入——旧账号填的卡号、姓名不得进换代后的表单。
    func chooseMethod(_ method: String, owner: WalletOwner) {
        guard method == WalletJSON.alipay || method == WalletJSON.bankCard, ownsForm(owner) else { return }
        state.form.method = method
        state.localErrors = []
        flow.clearFieldErrors()
    }

    func onLogonChange(_ text: String, owner: WalletOwner) {
        edit(owner) { $0.alipayLogonId = PayoutAccountForm.clip(text, max: PayoutAccountForm.logonMax) }
    }

    func onCardChange(_ text: String, owner: WalletOwner) {
        edit(owner) { $0.cardNo = PayoutAccountForm.acceptCardNo(current: $0.cardNo, next: text) }
    }

    func onBankChange(_ text: String, owner: WalletOwner) {
        edit(owner) { $0.bankName = PayoutAccountForm.clip(text, max: PayoutAccountForm.nameMax) }
    }

    func onPayeeChange(_ text: String, owner: WalletOwner) {
        edit(owner) { $0.payeeName = PayoutAccountForm.clip(text, max: PayoutAccountForm.nameMax) }
    }

    /// 【保存】：只去首尾空白（G13）；字段不合格就地提示、不发请求；否则新键提交（首次绑定也要二次验证）。`owner` 是渲染这张表单时的身份。
    func save(owner: WalletOwner) {
        guard ownsForm(owner), flow.state.canSubmit else { return }
        let result = PayoutAccountForm.build(state.form)
        guard let body = result.body else {
            state.localErrors = result.fieldErrors
            state.localErrorId += 1
            return
        }
        let summary = PayoutPendingSummary.encode(PayoutPendingSummary.summarize(state.form, texts: deps.texts))
        flow.submit(body: WalletJSON.text(body), summary: summary, owner: owner)
    }

    /// 44001 弹窗的【联系客服申诉】。
    func appeal(dialog id: Int) {
        guard flow.state.riskDialog?.id == id else { return }
        flow.dismissRisk(id)
        flow.visibility.navigated()
        deps.env.contactService(from: WalletRoutes.payoutAccount)
    }

    /// 被拦下的引导的手动入口（共性第 51 条）：页面此刻可见、会话仍是记下时的才打开；已填内容保留。
    func openGuide(owner: WalletOwner) {
        guard let route = state.guideRoute, ownsForm(owner), flow.visibleNow else { return }
        state.guideRoute = nil
        if guideOwner == flow.owner {
            navigate(route)
        }
    }

    func consumeToast(_ id: Int) {
        if state.toast?.id == id {
            state.toast = nil
        }
    }

    /// 会话换代：同步清空已填内容（含姓名、卡号、登录号）与已显示的账号，作废在途请求；新身份由 App 传入，再按新身份重取。
    func sessionChanged(_ owner: WalletOwner) {
        guard !left else { return }
        seq += 1
        deferredSaved = nil
        guideOwner = nil
        requests.cancelAll()
        state = PayoutSnapshot(version: state.version + 1)
        flow.sessionChanged(owner)
        start()
    }

    /// 页面出栈（同步出口）：作废读请求、清空内存中的完整输入；保存、确认、放弃不取消（未决记录兜底）。
    func leave() {
        guard !left else { return }
        left = true
        seq += 1
        requests.cancelAll()
        flow.leave()
        state.form = PayoutForm()
    }
}

extension PayoutAccountController {
    func edit(_ owner: WalletOwner, _ change: (inout PayoutForm) -> Void) {
        guard ownsForm(owner) else { return }
        change(&state.form)
        state.localErrors = []
    }

    func afterSaved(_ alreadyDone: Bool) {
        guard !alreadyDone, let page else { return }
        if !deps.env.payoutSaved(page: page) {
            // 停在本页：轻提示「收款账号已保存」
            serial += 1
            state.toast = Notice("payout.saved", id: serial, assertive: false)
        }
    }
}

extension PayoutAccountController: FlowHost {
    public func onSucceeded(_ data: Any?, alreadyDone: Bool) {
        let saved = WalletJSON.payoutAccount(data).map(PayoutAccountView.view).flatMap { $0.bound ? $0 : nil }
        // 保存成功推进账号读取世代（共性第 43 条）：保存之前发起的读取一律作废并取消，旧响应不得把新账号覆盖回去
        seq += 1
        requests.cancelAll()
        // 清空表单与内存中的完整输入（写成功的结算一次性恢复页面状态，APP-12 第 35 条）
        state.form = PayoutForm()
        state.editing = false
        state.account = saved ?? state.account
        state.localErrors = []
        if saved != nil {
            state.loadError = nil
            state.phase = .content
        }
        state.version += 1
        if saved == nil {
            load()
        }
        // 出栈回发起页是导航：页面此刻不在栈顶可见时留到回到可见再做（共性第 37、41 条）
        guard flow.visibleNow else {
            deferredSaved = alreadyDone
            return
        }
        afterSaved(alreadyDone)
    }

    public func onSettled() {
        if !left {
            load()
        }
    }

    public func onGuide(_ route: String) {
        // 收款账号页自己的错误（30307 等）留在本页显示，不重复压入同名页面
        guard !left, route != WalletRoutes.payoutAccount else { return }
        navigate(route)
    }

    public func onBusinessError(_: Int) {}
}
