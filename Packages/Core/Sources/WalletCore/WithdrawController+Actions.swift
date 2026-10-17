import CouliNetwork
import Foundation

/// 提交、引导、收款账号行、会话与离页。
public extension WithdrawController {
    /// 【提交】：先收起键盘；用当前合法金额生成新键（结局要求沿用的除外）提交。回调带渲染时的版本与表单身份（共性第 52、63 条）。
    func submit(version: Int, owner: WalletOwner) {
        guard let snapshot = current(version), let display = snapshot.display(), let fen = snapshot.inputFen,
              display.submitEnabled, !snapshot.serverBlocked, !snapshot.successPending
        else { return }
        state.hideKeyboardId += 1
        let body = WalletJSON.text(["amount_fen": fen])
        flow.submit(body: body, summary: body, owner: owner)
    }

    /// block_code 引导按钮（用户点了才打开前置页，不自动跳；G05）。
    func openGuide(version: Int, owner: WalletOwner) {
        guard ownsForm(owner), let route = current(version)?.guide.route else { return }
        navigate(route)
    }

    func openPayout(owner: WalletOwner) {
        guard ownsForm(owner) else { return }
        navigate(WalletRoutes.payoutAccount)
    }

    func openRecords(owner: WalletOwner) {
        guard ownsForm(owner) else { return }
        navigate(WalletRoutes.withdrawRecords)
    }

    func openRules(owner: WalletOwner) {
        guard ownsForm(owner), let target = state.helpTarget else { return }
        flow.visibility.navigated()
        deps.env.open(target.route, params: target.params, from: page)
    }

    /// 44001 弹窗的【联系客服申诉】（`id` 是渲染时的弹窗实例）：统一客服出口接入前经 Router 打开 Help（同 APP-08 G09）。
    func appeal(dialog id: Int) {
        guard flow.state.riskDialog?.id == id else { return }
        flow.dismissRisk(id)
        flow.visibility.navigated()
        deps.env.contactService(from: WalletRoutes.withdraw)
    }

    /// 读屏播报已读出（页面消费）。
    func consumeAnnounce(_ id: Int) {
        if state.announceId == id {
            state.announce = nil
        }
    }

    /// 会话换代（App 在会话通知里同步调用）：同步清空已输入的金额、估算、rules 与收款账号行，作废在途读请求；新身份由 App 在同一处一次性取得后
    /// 传入（共性第 65 条），再按新身份重取；未决记录按新账号重读。
    func sessionChanged(_ owner: WalletOwner) {
        sessionChanged(owner, restored: "")
    }

    /// 换上新身份（会话换代清空；构造时身份未确认的表单换上已确认身份时带上按它读到的金额草稿）。
    internal func sessionChanged(_ owner: WalletOwner, restored: String) {
        guard !left else { return }
        deferredSuccess = nil
        seq += 1
        appliedSeq = seq
        payoutSeq += 1
        estimateTask?.cancel()
        requests.cancelAll()
        payoutRequests.cancelAll()
        deferral.reset()
        state = WithdrawSnapshot(
            amountText: WithdrawAmountInput.accept(current: "", next: restored), version: state.version + 1
        )
        flow.sessionChanged(owner)
        start()
    }

    /// 页面出栈（同步出口）：作废读请求并取消传输；提交、确认、放弃不取消（未决记录兜底）；正常离开删除金额草稿。
    func leave() {
        guard !left else { return }
        let owner = flow.owner
        if deps.env.isCurrent(owner) {
            deps.cache?.deleteDraft(account: owner.account, loginEpoch: owner.loginEpoch)
        }
        left = true
        seq += 1
        payoutSeq += 1
        estimateTask?.cancel()
        requests.cancelAll()
        payoutRequests.cancelAll()
        deferral.reset()
        flow.leave()
    }
}

extension WithdrawController {
    func navigate(_ route: String) {
        flow.visibility.navigated()
        deps.env.open(route, params: [:], from: page)
    }

    /// 收款账号读取（共性第 19、43、44 条）：进入、回流、刷新都推进序号并作废旧请求；重读开始即让旧账号行失效（读取未确认不标作当前），
    /// 本轮成功后再显示；失败显示错误与【重试】。读取绑定本表单的固定身份（共性第 65 条）。
    func fetchPayout() {
        payoutSeq += 1
        let request = payoutSeq
        payoutRequests.cancelAll()
        state.payout = nil
        let form = flow.owner
        guard !left, form.account != nil || !form.identityKnown, admitPayout(deps.env.check(form)) else { return }
        if deps.gates.read.active {
            state.payoutError = nextNotice("error.42901")
            return
        }
        let probe = deps.gates.read.probe()
        payoutRequests.send(deps.api, ApiCall(operationId: Self.payoutOperation), probe: probe,
                            expected: form.request) { [weak self] result in
            guard let self, !left, payoutSeq == request, form == flow.owner, admitPayout(deps.env.check(form)) else {
                return
            }
            onPayout(result, probe: probe)
        }
    }

    /// 收款账号行读取的身份核对：暂时未知 → 记待补取（收款账号行保持未显示）；已换代 → 丢弃。
    func admitPayout(_ check: IdentityCheck) -> Bool {
        deferral.admit(check, slot: Self.payoutOperation, resume: { [weak self] in self?.fetchPayout() })
    }

    func onPayout(_ result: ApiResult, probe: SendProbe) {
        if case let .success(data, _, _) = result, let account = WalletJSON.payoutAccount(WalletJSON.parse(data)) {
            let view = PayoutAccountView.view(account)
            state.payout = view.bound ? view : nil
            state.payoutError = nil
            return
        }
        let error = WalletErrors.of(result, probe: probe)
        if error.kind == .retryAfter {
            deps.gates.read.start(error.disableMillis)
        }
        var code: Int?
        if case let .failure(failed, _, _, _, _, _) = result {
            code = failed
        }
        // 未绑定或取不到：不显示收款账号行（待确认句用 fallback）；30304 由 rules 引导，不另提示；作废的不提示
        switch error.kind {
        case .cancelled:
            state.payoutError = nil
        case .gated:
            state.payoutError = nextNotice("error.42901")
        default:
            serial += 1
            state.payoutError = code == 30304 ? nil : error.notice(id: serial)
        }
    }

    func navigateSucceeded(_ data: Any?, alreadyDone: Bool) {
        let id = (data as? [String: Any])?[WalletRoutes.withdrawalId] as? String
        if !alreadyDone {
            state.announce = TextLine("withdraw.submitted_spoken")
            state.announceId += 1
        }
        state.successPending = false
        let owner = flow.owner
        if deps.env.isCurrent(owner) {
            deps.cache?.deleteDraft(account: owner.account, loginEpoch: owner.loginEpoch)
        }
        guard let page else { return }
        _ = deps.env.replace(
            page: page, route: WalletRoutes.withdrawRecords, params: id.map { [WalletRoutes.withdrawalId: $0] } ?? [:]
        )
    }
}

extension WithdrawController: FlowHost {
    /// 共享结算（不看页面是否还在）：钱包摘要需要刷新（G19、共性第 40、61 条）。
    /// 成功的页面反馈：「此刻可见」与「发出时的导航许可」分开判断（共性第 41 条）。发起页此刻在栈顶可见就立即进提现记录；不可见时先记下，
    /// 回到可见时消费，期间【提交】不可用。
    public func onSucceeded(_ data: Any?, alreadyDone: Bool) {
        guard flow.visibleNow else {
            deferredSuccess = (data, alreadyDone)
            state.successPending = true
            return
        }
        navigateSucceeded(data, alreadyDone: alreadyDone)
    }

    public func onSettled() {
        guard !left else { return }
        fetchRules(amount: state.inputFen, initial: false, form: flow.owner)
        fetchPayout()
    }

    public func onGuide(_ route: String) {
        guard !left else { return }
        navigate(route)
    }

    /// 键结束的 30306：本页记下服务端阻断并禁用提交（共性第 10 条）。
    public func onBusinessError(_ code: Int) {
        guard code == 30306, !left else { return }
        blockedAtSeq = seq
        state.serverBlocked = true
    }
}
