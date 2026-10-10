import Foundation

// MARK: - 确认与外跳

public extension OpenPurchaseController {
    /// 弹层的主按钮：改价 / 返利归零 / 券失效【继续购买】、比价【仍去购买（无返利）】、JumpTip【知道了，去X】。用户这一下重新发许可。
    /// `ticket`：页面渲染时捕获的弹窗票据（r3g NEW-02，APP-09 共性第 63 条）：不是当前弹窗（旧回调）时什么都不做——不读新方案、
    /// 不记已读、不发许可、不外跳。
    func confirm(_ ticket: PurchaseDialogTicket?) {
        guard isCurrentDialog(ticket), let dialog = state.dialog else { return }
        let jump = ready
        switch dialog {
        case .confirmPrice, .confirmRebateGone, .compareNoRebate:
            hideDialog()
            // 先校验方案、来源与尝试，再有任何副作用（发许可、续执行；iOS RC-06）
            guard let jump = validPlan(jump) else { return }
            if purchasable(latestCard(jump.attempt), notify: true) {
                grantPermit(jump.attempt)
                proceed(jump)
            }
        case let .jumpTip(platform):
            hideDialog()
            // 先校验方案（同一平台）、来源与尝试，**之后**才记已读、排队 markTipRead（iOS RC-06：换账号后确认旧弹窗零请求、缓存不变）
            guard let jump = validPlan(jump), jump.attempt.platform == platform else { return }
            // 已读请求带获取方案时固定的请求归属，网络层发送前只比较（换代零发送）
            tips.markRead(platform, expected: jump.request)
            if purchasable(latestCard(jump.attempt), notify: true) {
                grantPermit(jump.attempt)
                execute(jump)
            }
        default:
            hideDialog()
        }
    }

    /// 弹层的取消 / 关闭（按钮、关闭键、系统返回都一样；遮罩不关闭）。
    /// `ticket`：同 `confirm(_:)`（r3g NEW-02）：旧回调不关新弹窗、不清待办、不撤许可。
    func dismissDialog(_ ticket: PurchaseDialogTicket?) {
        guard isCurrentDialog(ticket) else { return }
        switch state.dialog {
        case let .confirmPrice(_, _, rebateGone, _):
            hideDialog()
            toast(rebateGone ? PurchaseTextKeys.cancelledPriceRebate : PurchaseTextKeys.cancelledPrice)
        case .confirmRebateGone, .compareNoRebate:
            hideDialog()
            toast(PurchaseTextKeys.cancelledRebate)
        case let .authSheet(platform, busy):
            // 用户关闭授权：删除待办，给二选一（BR-ID-18）
            guard !busy else { return }
            clearOwnPending(authContext?.attempt ?? current)
            showDialog(.authDeclined(platform: platform, failed: false), from: authContext?.attempt ?? current)
        case .authCheckFailed:
            // 放弃本次：删除待办（之后授权了也不自动执行）
            hideDialog()
            clearOwnPending(authContext?.attempt ?? current)
            authContext = nil
        case .none:
            break
        default:
            hideDialog()
        }
        ready = nil
        revokePermit()
    }

    /// 「将通过浏览器打开」的【取消】。`ticket`：渲染时捕获的提示编号（r3g NEW-02）；不是当前这次提示就什么都不做。
    func cancelBrowser(_ ticket: UInt64?) {
        guard let ticket, state.browserNotice, state.browserTicket == ticket else { return }
        browserDecision?.complete(false)
    }
}

extension OpenPurchaseController {
    func proceed(_ jump: ReadyJump) {
        guard let granted = permit, granted.attempt === jump.attempt else { return }
        // 查询 JumpTip 已读（可能发 getTips）之前也先比较来源（iOS RC-06）
        guard originCurrent(jump.origin) else {
            dropStalePlan()
            return
        }
        guard env.loggedIn() else {
            execute(jump)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let show = await tips.shouldShow(jump.attempt.platform, expected: jump.request)
            // 等待之后复核许可：期间进入后台、被覆盖、离开、再点了别的都不再继续（共性第 3 条）
            guard allowed(granted), ready === jump else { return }
            // 等待期间来源变了：作废旧方案（iOS RC-06）
            guard originCurrent(jump.origin) else {
                dropStalePlan()
                return
            }
            // 续执行路径外跳前也查最新平台状态与下架（共性第 32 条）
            guard purchasable(latestCard(jump.attempt), notify: true) else {
                ready = nil
                return
            }
            if show {
                showDialog(.jumpTip(platform: jump.attempt.platform))
            } else {
                execute(jump)
            }
        }
    }

    func execute(_ jump: ReadyJump) {
        guard let granted = permit, granted.attempt === jump.attempt, allowed(granted) else { return }
        // 方案的来源已不是当前：不执行旧方案（iOS RC-06）
        guard originCurrent(jump.origin) else {
            dropStalePlan()
            return
        }
        ready = nil
        // 外跳前查最新平台状态与下架（共性第 27、32 条）
        guard purchasable(latestCard(jump.attempt), notify: true) else { return }
        // 来源是获取这份方案时固定的那一份：完成事件原样带着它交付（持有者只比较），不在外跳或完成时重新取
        let origin = jump.origin
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await executor.execute(
                plan: jump.plan,
                platform: jump.attempt.platform,
                installed: jump.attempt.installed,
                identity: jump.identity,
                // 允许开始下一步：许可有效、在前台，且最新平台状态 / 下架仍可购（共性第 40 条）
                allowed: { [weak self] in
                    guard let self else { return false }
                    return allowed(granted) && originCurrent(origin)
                        && purchasable(latestCard(jump.attempt), notify: false)
                },
                // 允许上报已执行步骤：尝试仍是当前、页面没离开，且来源仍是获取方案时固定的那一份——外跳结果等待期间换号、
                // 切环境就丢弃这条埋点，不记到新账号名下（r3g NEW-06）
                mayReport: { [weak self] in
                    self.map { !$0.left && $0.current === jump.attempt && $0.originCurrent(origin) } ?? false
                },
                confirmBrowser: { [weak self] in await self?.confirmBrowser(granted) ?? false }
            )
            guard !left else { return }
            afterJump(jump, outcome, origin: origin)
        }
    }

    /// 确认分支的统一前置（iOS RC-06）：方案还在；来源仍是获取方案时固定的那一份（不是则作废旧方案、提示重新点购买）；尝试仍是当前的。
    /// 全部通过才返回方案；调用方在此之前不得有任何副作用（已读缓存、请求排队、许可、外跳）。
    func validPlan(_ jump: ReadyJump?) -> ReadyJump? {
        guard let jump else { return nil }
        guard originCurrent(jump.origin) else {
            dropStalePlan()
            return nil
        }
        guard jump.attempt === current else { return nil }
        return jump
    }

    /// 来源仍是当前（只比较；没接持有者时两边都是 nil）。
    func originCurrent(_ origin: String?) -> Bool {
        jumpOrigin?() == origin
    }

    /// 作废来源已变的旧方案：撤销许可，提示重新点购买取新方案（与方案过期同一提示，iOS RC-06）。
    func dropStalePlan() {
        ready = nil
        revokePermit()
        toast(PurchaseTextKeys.jumpExpired)
    }

    func confirmBrowser(_ granted: Permit) async -> Bool {
        guard allowed(granted) else { return false }
        let decision = OneShot()
        browserDecision = decision
        dialogSerial &+= 1
        state.browserTicket = dialogSerial
        state.browserNotice = true
        let wait = browserNoticeMillis
        let sleep = sleep
        Task { @MainActor in
            await sleep(wait)
            decision.complete(true)
        }
        let result = await decision.wait()
        if browserDecision === decision {
            browserDecision = nil
        }
        state.browserNotice = false
        return result && allowed(granted)
    }

    func afterJump(_ jump: ReadyJump, _ outcome: JumpOutcome, origin: String? = nil) {
        if outcome.cancelled || outcome.stopped {
            return
        }
        if outcome.expired {
            // 方案过了 expire_at：不外跳，提示重新点购买取新方案（共性第 12 条）
            toast(PurchaseTextKeys.jumpExpired)
            return
        }
        switch outcome.run.final {
        case JumpTypes.finalOpened, JumpTypes.finalBrowser:
            onJumpedOut?(jump.attempt.platform, origin)
        case JumpTypes.finalCopied:
            toast(PurchaseTextKeys.copied)
            onJumpedOut?(jump.attempt.platform, origin)
        case JumpTypes.finalNotInstalled:
            // 明确未安装但口令已复制：安装提示照旧，同时算成功外跳（BR-ATTR-21；APP-08 共性第 33 条），回前台后拉待跟单卡
            state.notInstalled = true
            toast(PurchaseTextKeys.notInstalledCopied)
            onJumpedOut?(jump.attempt.platform, origin)
        default:
            let onlySdk = outcome.run.executed.allSatisfy { $0 == JumpTypes.sdk }
            if outcome.sdkUnavailable, onlySdk {
                // 淘宝 sdk 步骤不可用且没有可执行的后续步骤：提示、不外跳（BR-ATTR-27 淘宝行）
                showDialog(.sdkFailed)
            } else if jump.attempt.installed == TradeConstants.installedFalse {
                // 明确未安装、全部路径失败：安装提示（BR-ATTR-27 ②）；unknown 的失败不能当未安装（共性第 13 条）
                state.notInstalled = true
            } else {
                // 通用跳转失败，按钮照常可再点
                toast(PurchaseTextKeys.jumpFailed)
            }
        }
    }
}
