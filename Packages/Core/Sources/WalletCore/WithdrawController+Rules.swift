import CouliNetwork
import Foundation

/// rules 与估算（BR-WDR-04 细则；AC-S2-80 ⑩⑪⑫）。
public extension WithdrawController {
    /// 输入变化（键盘、粘贴、自动填充）：过滤（G18），立即「计算中…」，停顿 0.5 秒后带金额取 rules；不合法隐藏且不发请求。`owner` 是渲染这张
    /// 表单时的身份（共性第 59、63 条）：不是本表单当前的身份、或已不是当前会话的旧回调不写入（返回 false，调用方也不按它保存金额）。
    @discardableResult
    func onAmountChange(_ text: String, owner: WalletOwner) -> Bool {
        guard ownsForm(owner) else { return false }
        let next = WithdrawAmountInput.accept(current: state.amountText, next: text)
        if next != state.amountText {
            setAmount(next, debounce: true, owner: owner)
        }
        return true
    }

    /// 【全部提现】：只填 max_withdrawable_fen（G18 的写法）。回调带渲染时的版本与表单身份（共性第 64 条）。
    func fillAll(version: Int, owner: WalletOwner) {
        guard ownsForm(owner), let display = current(version)?.display(), let fen = display.allFen else { return }
        announcePending = true
        setAmount(WithdrawAmountInput.display(fen), debounce: false, owner: owner)
    }

    /// 快捷档位：只填服务端给的档位；与【全部提现】同样携带并核对渲染时的表单身份。
    func fillQuick(version: Int, fen: Int64, owner: WalletOwner) {
        guard ownsForm(owner), let display = current(version)?.display(), display.quick.contains(fen) else { return }
        announcePending = true
        setAmount(WithdrawAmountInput.display(fen), debounce: false, owner: owner)
    }

    /// 页内【重试】（禁用期内不发）。
    func retry() {
        guard !left, !deps.gates.read.active else { return }
        fetchRules(amount: state.inputFen, initial: true, form: flow.owner)
        fetchPayout()
    }
}

extension WithdrawController {
    /// `owner` 是本表单当前的身份，且仍是当前会话（共性第 52、59、64 条）。
    func ownsForm(_ owner: WalletOwner) -> Bool {
        !left && owner == flow.owner && deps.env.isCurrent(owner)
    }

    /// 渲染时的版本仍是当前、页面还在、已有内容，才返回快照（按钮回调用）。
    func current(_ version: Int) -> WithdrawSnapshot? {
        !left && state.version == version && state.phase == .content ? state : nil
    }

    /// 写入金额并安排估算；`owner` 是写入这次金额的表单身份，延时估算到点时再核对，并原样交给 `fetchRules`（共性第 64 条）。
    func setAmount(_ text: String, debounce: Bool, owner: WalletOwner) {
        estimateTask?.cancel()
        // 输入一变，在途的估算就不再属于当前金额（序号前进）
        seq += 1
        let fen = WithdrawAmountInput.parse(text)
        // 是否带金额重取 rules 只看金额是否合法、输入是否允许（共性第 23 条，G29）
        let requestable = fen != nil && state.display()?.amountEditable == true
        state.amountText = text
        state.estimate = requestable ? .calculating : .hidden
        flow.clearFieldErrors()
        saveDraft(owner)
        guard requestable, let fen else { return }
        estimateTask = Task { @MainActor [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: Self.debounceNanos)
            }
            guard let self, !Task.isCancelled, !left, state.inputFen == fen else { return }
            fetchRules(amount: fen, initial: false, form: owner)
        }
    }

    /// 取 rules；带金额（估算）时整次请求绑定这张表单的身份 `form`（共性第 64 条）：发出前核对它仍是本表单身份且仍是当前会话，网络层按
    /// expected 在读取凭据前再核对，迟到响应也按它核对。不带金额的页头读取同样只用本表单的固定身份（共性第 65 条）。
    func fetchRules(amount: Int64?, initial: Bool, form: WalletOwner) {
        guard !left, form.account != nil else { return }
        guard ownsForm(form) else {
            // 带金额的读取而身份已不是本表单当前的（共性第 64 条）：不发，这次「计算中」收起
            if amount != nil, state.estimate == .calculating {
                state.estimate = .hidden
            }
            return
        }
        if deps.gates.read.active {
            readGated(amount)
            return
        }
        seq += 1
        let request = seq
        if initial, state.rules == nil {
            state.phase = .loading
            state.loadError = nil
        }
        let probe = deps.gates.read.probe()
        let call = ApiCall(operationId: Self.rulesOperation, query: amount.map { "amount_fen=\($0)" })
        requests.send(deps.api, call, probe: probe, expected: form.request) { [weak self] result in
            guard let self, !left, ownsForm(form) else { return }
            onRules(result, request: request, account: form.account, amount: amount, probe: probe)
        }
    }

    /// rules / 估算被本地限流拦下（共性第 45、56 条）：同样结算本次读取——没有页头的进加载失败态，已有页头的页内提示 42901 与【重试】；
    /// 这次估算（仍是当前金额的）隐藏，不留下没有在途请求的「计算中」。
    func readGated(_ amount: Int64?) {
        if state.rules == nil {
            state.phase = .error
            state.loadError = nextNotice("error.42901")
        } else {
            state.readError = nextNotice("error.42901")
        }
        if let amount, amount == state.inputFen, state.estimate == .calculating {
            state.estimate = .hidden
        }
    }

    func onRules(_ result: ApiResult, request: Int64, account: String?, amount: Int64?, probe: SendProbe) {
        guard case let .success(data, _, _) = result, let rules = WalletJSON.rules(WalletJSON.parse(data)) else {
            rulesFailed(result, request: request, account: account, amount: amount, probe: probe)
            return
        }
        // 页头、上限、档位只取已应用过的最新序号（AC-S2-80 ⑩⑪⑫）
        if request > appliedSeq {
            appliedSeq = request
            // 30306 阻断只由阻断之后发出、明确允许的 rules 解除（旧序号的 rules 不得恢复）
            let unblock = request > blockedAtSeq && rules.canWithdraw
            state.phase = .content
            state.rules = rules
            state.loadError = nil
            state.readError = nil
            state.serverBlocked = state.serverBlocked && !unblock
            state.version += 1
        }
        guard let amount, estimateOwned(request, account, amount) else { return }
        let line = WithdrawRulesView.estimate(rules, inputFen: amount)
        state.estimate = line == .hidden ? .hidden : .shown(line, amountFen: amount)
        if announcePending, let net = line.netFen {
            announcePending = false
            state.announce = TextLine("withdraw.spoken.quick", amounts: ["amount": amount, "net": net])
            state.announceId += 1
        }
    }

    func rulesFailed(_ result: ApiResult, request: Int64, account: String?, amount: Int64?, probe: SendProbe) {
        let error = WalletErrors.of(result, probe: probe)
        if error.kind == .cancelled {
            return
        }
        if error.kind == .gated {
            // 发送前被禁用期闸门拦下（共性第 45、62 条）：被新请求取代的不动
            if request == seq {
                readGated(amount)
            }
            return
        }
        if error.kind == .retryAfter {
            deps.gates.read.start(error.disableMillis)
        }
        serial += 1
        let notice = error.notice(id: serial)
        if request > appliedSeq {
            if state.rules == nil {
                state.phase = .error
                state.loadError = notice
            } else {
                // 已有页头时读取失败：页头不变，页内提示（42901 / 5xxxx 带 trace6）；读取失败不恢复被阻断的【提交】
                state.readError = notice
            }
        }
        if let amount, estimateOwned(request, account, amount) {
            state.estimate = .hidden
        }
    }

    /// 估算响应的归属四项（BR-WDR-04 细则）：账号按本表单固定身份比较（不读当前会话来赋值）。
    func estimateOwned(_ request: Int64, _ account: String?, _ amount: Int64) -> Bool {
        WithdrawEstimateGate.shouldApply(
            WithdrawEstimateGate.Request(account: account, pageInstance: pageInstance, seq: request, amountFen: amount),
            WithdrawEstimateGate.Current(
                account: flow.owner.account, pageInstance: pageInstance, latestSeq: seq, inputFen: state.inputFen
            )
        )
    }

    /// 金额草稿（进程回收后恢复，iOS I06）：只按本表单固定身份写，身份不是当前会话的不写；写入带清理世代。
    func saveDraft(_ owner: WalletOwner) {
        guard ownsForm(owner), let cache = deps.cache else { return }
        cache.writeDraft(account: owner.account, amount: state.amountText, ticket: cache.generation)
    }
}
