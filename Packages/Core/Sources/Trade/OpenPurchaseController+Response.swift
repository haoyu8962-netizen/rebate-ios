import CouliNetwork
import Foundation
import Generated

extension OpenPurchaseController {
    func settle(_ result: ApiResult, attempt: PurchaseAttempt) {
        let late = LateResponsePolicy.decide(interrupt: interrupt == "timeout" ? LateResponsePolicy.cancel : interrupt)
        if !late.jump || !permitted(attempt) {
            // 取消、离开、后台、超时之后才到：只更新卡片（新价格、new_link_id、无返利状态），不外跳、不弹确认、不进登录 / 授权
            if case let .success(data, _, _) = result, let object = TJSON.parse(data) {
                patchCard(attempt, object)
            }
            if state.phase == .loading {
                state.phase = .idle
            }
            return
        }
        state.phase = .idle
        switch result {
        case let .success(data, traceId, _):
            onSuccess(TJSON.parse(data) ?? [:], traceId: traceId, attempt: attempt)
        case let .failure(code, _, data, traceId, effect, _):
            onFailure(code: code, data: TJSON.parse(data) ?? [:], traceId: traceId, effect: effect, attempt: attempt)
        case .transportFailure:
            // 超时、断网、没有外壳：与 8 秒超时同样处理，【重试】重放原尝试
            interrupt = "timeout"
            state.phase = .timeout
        case let .localReject(reason) where reason == LocalRejectReason.basicModeDenied:
            // 发出前隐私状态变了（撤回同意等）：按基本模式补同意
            requestConsent(for: latestCard(attempt), spm: spm)
        default:
            toast(PurchaseTextKeys.generic)
        }
    }

    func onSuccess(_ data: TradeObject, traceId: String?, attempt: PurchaseAttempt) {
        // 判断基准是尝试的原卡快照：迟到响应更新过的展示卡片不能消除改价 / 返利归零的确认（共性第 1 条，BR-PRICE-13）
        let outcome = OpenResponseAction.map(response: ["code": 0, "data": data], context: openContext(
            attempt.card, noRebateConfirmed: attempt.noRebate
        ))
        patchCard(attempt, data)
        guard let attemptId = TJSON.string(data["attempt_id"]), let plan = TJSON.object(data["jump"]) else {
            // 契约必填字段缺失：保守不外跳
            toast(PurchaseTextKeys.generic, traceId: traceId)
            return
        }
        let jump = ReadyJump(
            plan: plan, identity: PurchaseIdentity(
                attemptId: attemptId,
                linkId: outcome.replaceLinkId ?? attempt.linkId
            ),
            attempt: attempt
        )
        ready = jump
        if outcome.requoteNotice {
            toast(PurchaseTextKeys.requote)
        }
        switch outcome.actionRaw {
        case OpenActions.offShelf:
            toast(PurchaseTextKeys.offShelf)
            ready = nil
        case OpenActions.confirmPrice, OpenActions.confirmCoupon:
            showDialog(.confirmPrice(
                oldFen: outcome.oldFinalFen, newFen: outcome.newFinalFen, rebateGone: outcome.rebateGone,
                coupon: outcome.actionRaw == OpenActions.confirmCoupon
            ))
        case OpenActions.confirmRebateGone:
            // 新旧价格都带上：价格变动未达阈值（price_changed=false）但新价不同时，弹窗不能写「价格没有变化」（共性第 45 条）
            showDialog(.confirmRebateGone(priceFen: outcome.newFinalFen, oldFen: outcome.oldFinalFen))
        case OpenActions.compareNoRebate:
            showDialog(.compareNoRebate)
        default:
            proceed(jump)
        }
    }

    func onFailure(code: Int, data: TradeObject, traceId: String?, effect: ErrorEffect, attempt: PurchaseAttempt) {
        let outcome = OpenErrorAction.map(code: code, data: data)
        switch outcome.actionRaw {
        case OpenErrorActions.login:
            // 1xxxx：登录后沿用原键重放（BR-ID-10 细则），登记 pending_action 后进登录页
            pending.register(pendingParams(
                attempt.card, linkId: attempt.linkId, key: attempt.key, kind: PurchasePendingKeys.kindLogin,
                attempt: attempt
            ))
            env.open(route: PurchaseRoutes.login, params: [:])
        case OpenErrorActions.authSheet, OpenErrorActions.authJump:
            authRequired(code: code, data: data, attempt: attempt)
        case OpenErrorActions.notice:
            notice(code: code, outcome: outcome, traceId: outcome.showTrace6 ? traceId : nil, attempt: attempt)
        case OpenErrorActions.error:
            blocked(code: code, outcome: outcome, traceId: traceId, attempt: attempt)
        case OpenErrorActions.retryAfter:
            startBlock(effect.disableMillis ?? ErrorActionMapper.defaultRetryAfterMillis)
            toast(outcome.textKey ?? PurchaseTextKeys.rateLimited)
        case OpenErrorActions.research:
            // 30143：同平台、原样标题重新搜索（H11 同口径，TODO(N-28)）
            toast(outcome.textKey ?? PurchaseTextKeys.refExpired)
            env.open(route: PurchaseRoutes.search, params: Self.similarParams(latestCard(attempt)))
        case OpenErrorActions.refetch:
            // 30144：按这张卡的 product_key + item_ref 重取（搜索卡与详情同样），替换后等用户再点（03 §4.2，共性第 9 条）
            toast(outcome.textKey ?? PurchaseTextKeys.refExpired)
            let target = latestCard(attempt)
            env.refetchCard(target, merge: CardPatch.reload(expected: CardPatch.revision(target)))
        case OpenErrorActions.forceUpdate:
            break
        default:
            toast(outcome.textKey ?? PurchaseTextKeys.generic, traceId: outcome.showTrace6 ? traceId : nil)
        }
    }

    /// 30101 / 30102 / 30111：记下授权上下文，弹 AuthSheet 或二选一（BR-ID-18）。
    private func authRequired(code: Int, data: TradeObject, attempt: PurchaseAttempt) {
        let platform = attempt.platform
        keys.authRequired(code: code)
        authContext = AuthContext(code: code, linkId: attempt.linkId, data: data, attempt: attempt)
        // 自动弹出每平台每会话最多 2 次（BR-ID-18）；用户在二选一里主动【重试】进来的不算自动弹出、不受限（共性第 10 条）
        if attempt.userAuthRetry || counter.tryAutoPop(platform) {
            pending.register(pendingParams(
                attempt.card, linkId: attempt.linkId, key: nil, kind: PurchasePendingKeys.kindAuth, attempt: attempt
            ))
            showDialog(.authSheet(platform: platform, busy: false))
        } else {
            // 同一会话第 3 次起不再自动拉起授权，直接给二选一（BR-ID-18）；只删本页登记的待办（共性第 44 条）
            clearOwnPending()
            showDialog(.authDeclined(platform: platform, failed: false))
        }
    }

    /// 提示类：auth_unavailable 只提示；50301 按平台记下（卡片映射隐藏返利、按钮禁用，新配置到达即被覆盖，共性第 5、6 条）；
    /// 30103 / 30121 / 30151 / 30153 带按钮。
    private func notice(code: Int, outcome: OpenErrorOutcome, traceId: String?, attempt: PurchaseAttempt) {
        if code == 30101 || code == 30102 {
            showDialog(.authUnavailable(textKey: outcome.textKey))
        } else if code == 50301 {
            let status = outcome.silent ? TradeConstants.notLaunched : TradeConstants.maintenance
            env.markPlatformStatus(attempt.platform, status: status)
            if !outcome.silent {
                toast(outcome.textKey ?? PurchaseTextKeys.maintenance, traceId: traceId)
            }
        } else if outcome.offerNoRebate || outcome.offerContact {
            showDialog(.notice(
                textKey: outcome.textKey, traceId: traceId, noRebate: outcome.offerNoRebate,
                contact: outcome.offerContact, retry: false
            ))
        } else {
            toast(outcome.textKey ?? PurchaseTextKeys.generic, traceId: traceId)
        }
    }

    /// 受阻类：30141 下架绑定这张卡（共性第 5、28 条：卡片置灰，按钮立即不可点）；50303 重试 / 无返利；其余错误提示带 trace6。
    private func blocked(code: Int, outcome: OpenErrorOutcome, traceId: String?, attempt: PurchaseAttempt) {
        if code == 30141 {
            updateCard(attempt) { card in
                var out = card
                out["availability"] = Availability.offShelf.rawValue
                return out
            }
            toast(outcome.textKey ?? PurchaseTextKeys.offShelf)
        } else if code == 50303 {
            showDialog(.notice(textKey: outcome.textKey, traceId: traceId, noRebate: true, contact: false, retry: true))
        } else {
            toast(outcome.textKey ?? PurchaseTextKeys.generic, traceId: traceId)
        }
    }

    /// open 上下文：`base` 卡片的价格与返利上限（OpenResponseAction 判返利归零用）。
    func openContext(_ base: TradeObject, noRebateConfirmed: Bool = false) -> TradeObject {
        var fields: TradeObject = [
            "currentPriceFen": TJSON.fen(base["final_price_fen"]).map { NSNumber(value: $0) } ?? NSNull(),
            "currentRebateMaxFen": TJSON.fen(base["rebate_max_fen"]).map { NSNumber(value: $0) } ?? NSNull(),
        ]
        if TJSON.string(base["rebate_basis"]) == TradeConstants.amountUnknown {
            fields["amountUnknown"] = true
        }
        if noRebateConfirmed {
            fields["noRebateConfirmed"] = true
        }
        return fields
    }

    /// 尝试那张卡的最新展示版本。
    func latestCard(_ attempt: PurchaseAttempt) -> TradeObject {
        CardPatch.sameCard(card, attempt.card) ? card : attempt.card
    }

    /// 用响应更新卡片（BR-PRICE-12：无论确认还是取消）；价格 / 返利字段给不全时重取权威卡片（共性第 7、8、17、26 条）。
    func patchCard(_ attempt: PurchaseAttempt, _ data: TradeObject) {
        let before = latestCard(attempt)
        cardBeforeResponse = attempt.card
        // 同键重放得到相同结果：卡片不变（只换取价时间），不加版本、不发新补齐，进行中的补齐照常落下（共性第 33 条）
        guard CardPatch.changes(before, data) else {
            updateCard(attempt, bump: false) { CardPatch.apply($0, data) }
            return
        }
        let after = CardPatch.bump(CardPatch.apply(before, data))
        updateCard(attempt) { CardPatch.apply($0, data) }
        // 只补齐价格 / 口径字段，不整卡替换；补齐带卡片版本，旧的补齐响应不得填入新一次购买结果（共性第 17、26 条）
        if CardPatch.needsRefetch(before, data) {
            let fill = CardPatch.fill(expected: CardPatch.revision(after))
            env.refetchCard(after) { [weak self] current, fresh in
                let merged = fill(current, fresh)
                self?.adoptRefreshed(merged)
                return merged
            }
        }
    }

    /// 补齐后的卡（共性第 30 条：券失效确认框补齐后按券额给口径词）：同一张卡、版本没变时记下。
    func adoptRefreshed(_ merged: TradeObject) {
        guard CardPatch.sameCard(card, merged), CardPatch.revision(card) == CardPatch.revision(merged) else { return }
        card = merged
        if let shown = state.card, CardPatch.sameCard(shown, merged) {
            state.card = merged
        }
    }

    /// 写入购买结果（open 响应、30141 下架）：卡片版本加 1，之前发出的补齐 / 重新加载结果到达时认出卡片已更新、不覆盖。
    func updateCard(
        _ attempt: PurchaseAttempt, bump: Bool = true, _ transform: @escaping (TradeObject) -> TradeObject
    ) {
        let versioned: (TradeObject) -> TradeObject = bump ? { CardPatch.bump(transform($0)) } : transform
        if CardPatch.sameCard(card, attempt.card) {
            card = versioned(card)
            if let shown = state.card, CardPatch.sameCard(shown, card) {
                state.card = card
            }
        }
        env.updateCard(attempt.card, transform: versioned)
    }
}
