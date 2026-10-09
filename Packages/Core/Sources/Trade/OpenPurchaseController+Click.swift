import CouliNetwork
import Foundation
import Generated

// MARK: - 点击与发送

extension OpenPurchaseController {
    /// 用户点了【购买】。`spm` 为按钮的 页面.模块.坑位（03 §4.7）。
    public func buy(_ card: TradeObject, spm: String?) {
        buy(card, spm: spm, userAuthRetry: false)
    }

    func buy(_ card: TradeObject, spm: String?, userAuthRetry: Bool) {
        guard !left, !busy else { return }
        guard purchasable(card, notify: true) else { return }
        guard !gate.active else { return }
        self.card = card
        self.spm = spm
        state.platform = TJSON.string(card["platform"]) ?? ""
        state.card = card
        state.notInstalled = false
        if env.basicMode() {
            requestConsent(for: card, spm: spm)
            return
        }
        startClick(card, key: keys.start(), noRebate: false, noRebateReason: nil, userAuthRetry: userAuthRetry)
    }

    /// 此刻能否为这张卡发 open（共性第 5、27、28 条）：卡片已下架（30141 / availability=off_shelf，绑定这张卡）不发；平台购买状态
    /// maintenance 提示、not_launched 静默不发（点击结果确认的 50301 优先，其次配置）。
    func purchasable(_ card: TradeObject, notify: Bool) -> Bool {
        if TJSON.string(card["availability"]) == Availability.offShelf.rawValue {
            return false
        }
        let platform = TJSON.string(card["platform"]) ?? ""
        switch env.platformStatus(platform) {
        case TradeConstants.maintenance:
            if notify {
                toast(PurchaseTextKeys.maintenance)
            }
            return false
        case TradeConstants.notLaunched:
            return false
        default:
            return true
        }
    }

    /// 基本模式：登记购买待办（没有发请求，不带键）并弹补同意；同意后 `resumeAfterConsent` 恢复一次，仍不同意由 Router 删除待办。
    func requestConsent(for card: TradeObject, spm: String?) {
        guard let linkId = TJSON.string(card["link_id"]) else {
            toast(PurchaseTextKeys.refExpired)
            return
        }
        consentCard = (card, spm)
        pending.register(pendingParams(
            card, linkId: linkId, key: nil, kind: PurchasePendingKeys.kindConsent, attempt: nil
        ))
        env.requestConsent()
    }

    /// 加载层【取消】：只挡本机外跳，之后到达的响应只更新卡片（03 §4.5）。
    public func cancelLoading() {
        guard state.phase == .loading else { return }
        interrupt = LateResponsePolicy.cancel
        revokePermit()
        keys.cancel()
        timer?.cancel()
        state.phase = .idle
    }

    /// 超时后的【重试】：完整重放原尝试（原路径、原请求体、原键，TRADE-22）；用户这一下重新发许可。
    public func retryAfterTimeout() {
        guard !left, state.phase == .timeout, let attempt = current, !gate.active else { return }
        keys.retry()
        grantPermit(attempt)
        send(attempt)
    }

    /// 超时条的关闭（放弃本次，不作废服务端键）。
    public func dismissTimeout() {
        guard state.phase == .timeout else { return }
        keys.abandon()
        revokePermit()
        state.phase = .idle
    }

    func startClick(_ card: TradeObject, key: String, noRebate: Bool, noRebateReason: String?, userAuthRetry: Bool) {
        // 没有 link_id 的卡买不了（契约 openLink 只按 link_id）：保守不发、提示失效
        guard let linkId = TJSON.string(card["link_id"]) else {
            toast(PurchaseTextKeys.refExpired)
            return
        }
        click += 1
        let platform = TJSON.string(card["platform"]) ?? ""
        let installed = ports.installed(platform)
        let attempt = PurchaseAttempt(
            click: click, card: card, linkId: linkId,
            body: openBody(installed: installed, noRebate: noRebate, reason: noRebateReason),
            key: key, noRebate: noRebate, noRebateReason: noRebateReason, installed: installed,
            userAuthRetry: userAuthRetry
        )
        self.card = card
        current = attempt
        ready = nil
        grantPermit(attempt)
        state.platform = platform
        state.card = card
        state.notInstalled = false
        send(attempt)
    }

    /// 发 open（所有入口共用）：发之前再按此刻的平台状态与这张卡的可购状态核对一次（共性第 27 条），不可买就停在这里、同步界面。
    func send(_ attempt: PurchaseAttempt) {
        guard purchasable(latestCard(attempt), notify: true) else {
            timer?.cancel()
            revokePermit()
            if state.phase != .idle {
                state.phase = .idle
            }
            return
        }
        request += 1
        let myRequest = request
        interrupt = LateResponsePolicy.none
        // 先作废旧的授权归属（查询、授权流程、待办、延迟恢复），再取消在途请求（共性第 20 条）
        invalidateAuth()
        calls.cancel(group: Self.openGroup)
        state.phase = .loading
        state.dialog = nil
        timer?.cancel()
        let timeout = timeoutMillis
        let sleep = sleep
        timer = Task { @MainActor [weak self] in
            await sleep(timeout)
            guard !Task.isCancelled, let self, current === attempt, myRequest == request, state.phase == .loading
            else { return }
            keys.timeout()
            interrupt = "timeout"
            state.phase = .timeout
        }
        let call = ApiCall(
            operationId: TradeOperations.openLink, pathParams: ["link_id": attempt.linkId], body: attempt.body,
            idempotencyKey: attempt.key
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await calls.send(call, group: Self.openGroup)
            // 等待之后复核归属：离开、再次点击、重发之后的旧响应只丢弃
            guard !left, current === attempt, myRequest == request else { return }
            timer?.cancel()
            settle(result, attempt: attempt)
        }
    }

    func openBody(installed: String, noRebate: Bool, reason: String?) -> String {
        var fields: TradeObject = ["installed": installed]
        if noRebate {
            fields["no_rebate"] = true
            if let reason {
                fields["no_rebate_reason"] = reason
            }
        }
        if let spm, spm.count <= Self.spmMax {
            fields["spm"] = spm
        }
        return TJSON.encode(fields)
    }
}
