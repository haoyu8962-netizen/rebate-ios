import Foundation

// MARK: - 确认与外跳

public extension OpenPurchaseController {
    /// 弹层的主按钮：改价 / 返利归零 / 券失效【继续购买】、比价【仍去购买（无返利）】、JumpTip【知道了，去X】。用户这一下重新发许可。
    func confirm() {
        guard let dialog = state.dialog else { return }
        let jump = ready
        switch dialog {
        case .confirmPrice, .confirmRebateGone, .compareNoRebate:
            hideDialog()
            if let jump, jump.attempt === current, purchasable(latestCard(jump.attempt), notify: true) {
                grantPermit(jump.attempt)
                proceed(jump)
            }
        case let .jumpTip(platform):
            hideDialog()
            tips.markRead(platform)
            if let jump, jump.attempt === current, purchasable(latestCard(jump.attempt), notify: true) {
                grantPermit(jump.attempt)
                execute(jump)
            }
        default:
            hideDialog()
        }
    }

    /// 弹层的取消 / 关闭（按钮、关闭键、系统返回都一样；遮罩不关闭）。
    func dismissDialog() {
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
            showDialog(.authDeclined(platform: platform, failed: false))
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

    /// 「将通过浏览器打开」的【取消】。
    func cancelBrowser() {
        browserDecision?.complete(false)
    }
}

extension OpenPurchaseController {
    func proceed(_ jump: ReadyJump) {
        guard let granted = permit, granted.attempt === jump.attempt else { return }
        guard env.loggedIn() else {
            execute(jump)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let show = await tips.shouldShow(jump.attempt.platform)
            // 等待之后复核许可：期间进入后台、被覆盖、离开、再点了别的都不再继续（共性第 3 条）
            guard allowed(granted), ready === jump else { return }
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
        ready = nil
        // 外跳前查最新平台状态与下架（共性第 27、32 条）
        guard purchasable(latestCard(jump.attempt), notify: true) else { return }
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
                    return allowed(granted) && purchasable(latestCard(jump.attempt), notify: false)
                },
                // 允许上报已执行步骤：只看尝试是否仍是当前、页面没离开
                mayReport: { [weak self] in self.map { !$0.left && $0.current === jump.attempt } ?? false },
                confirmBrowser: { [weak self] in await self?.confirmBrowser(granted) ?? false }
            )
            guard !left else { return }
            afterJump(jump, outcome)
        }
    }

    func confirmBrowser(_ granted: Permit) async -> Bool {
        guard allowed(granted) else { return false }
        let decision = OneShot()
        browserDecision = decision
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

    func afterJump(_ jump: ReadyJump, _ outcome: JumpOutcome) {
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
            break
        case JumpTypes.finalCopied:
            toast(PurchaseTextKeys.copied)
        case JumpTypes.finalNotInstalled:
            state.notInstalled = true
            toast(PurchaseTextKeys.notInstalledCopied)
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
