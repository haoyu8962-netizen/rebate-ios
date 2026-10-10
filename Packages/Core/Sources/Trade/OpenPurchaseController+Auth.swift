import CouliNetwork
import Foundation

// MARK: - 授权

public extension OpenPurchaseController {
    /// AuthSheet【去授权】。`ticket`：页面渲染时捕获的弹窗票据（r3g NEW-02）；不是当前弹窗（旧回调）时什么都不做。
    func authorize(_ ticket: PurchaseDialogTicket?) {
        guard isCurrentDialog(ticket) else { return }
        guard let context = authContext, case let .authSheet(platform, busy) = state.dialog, !busy,
              !left else { return }
        // 先比较来源（iOS RC-06）：旧账号 / 旧环境的 AuthSheet 不拉起授权、不发授权请求
        guard originCurrent(context.origin) else {
            dropStaleAuth(context)
            return
        }
        state.dialog = .authSheet(platform: platform, busy: true)
        authPermit = true
        authGen += 1
        let gen = authGen
        if let authJump = TJSON.object(context.data["auth_jump"]) {
            runAuthJump(authJump, context, gen)
        } else {
            runTaobaoAuth(context, gen)
        }
    }

    /// 授权结果查不到时的【重试】：重新查询授权状态（listUnionBindings）；42901 禁用期间执行层直接拦下。
    /// `ticket`：同 `authorize(_:)`（r3g NEW-02）：旧弹窗的回调不读新弹窗、不发请求。
    func recheckAuth(_ ticket: PurchaseDialogTicket?) {
        guard isCurrentDialog(ticket) else { return }
        guard case let .authCheckFailed(_, _, _, afterBind) = state.dialog, let context = authContext, !left,
              !gate.active
        else { return }
        guard originCurrent(context.origin) else {
            dropStaleAuth(context)
            return
        }
        hideDialog()
        queryBindings(context, afterBind: afterBind)
    }

    /// 【联系客服】：统一客服出口未接入前经 Router 打开帮助中心（TODO(N-28) A03 同口径）。
    /// `ticket`：同 `authorize(_:)`（r3g NEW-02）：旧弹窗的回调不关新弹窗、不打开页面。
    func contactService(_ ticket: PurchaseDialogTicket?) {
        guard isCurrentDialog(ticket) else { return }
        hideDialog()
        env.open(route: PurchaseRoutes.help, params: [:])
    }

    /// 【看看相似商品】：同平台、原样标题打开搜索（BR-PRICE-08）。`product` 是入口所在的那张卡（详情首次进入、没点过购买也有，共性第 15 条）；
    /// 比价弹窗里不给时用本次购买的卡。
    func similar(_ product: TradeObject? = nil) {
        if state.dialog == .compareNoRebate {
            hideDialog()
            ready = nil
            revokePermit()
        }
        env.open(route: PurchaseRoutes.search, params: Self.similarParams(product ?? card))
    }

    /// 比价弹窗里的【看看相似商品】（r3g NEW-02）：票据是当前的比价弹窗才执行，旧回调零效果。
    func similar(dialog ticket: PurchaseDialogTicket?) {
        guard isCurrentDialog(ticket), state.dialog == .compareNoRebate else { return }
        similar()
    }

    /// 比价说明【查看说明】：/v1/config.help_links.price_compare（没有配置不显示入口）。
    /// `ticket`：同 `authorize(_:)`（r3g NEW-02）。
    func viewExplanation(_ ticket: PurchaseDialogTicket?) {
        guard isCurrentDialog(ticket) else { return }
        guard let link = env.helpLink(PurchaseRoutes.helpPriceCompare) else { return }
        env.open(route: link.route, params: link.params)
    }

    /// 被拦下的授权码（30101 / 30102 / 30111；AuthSheet 标题用 error.<code>）；没有为 nil。
    var pendingAuthCode: Int? {
        authContext?.code
    }

    /// 比价说明入口是否可见。
    var explanationAvailable: Bool {
        env.helpLink(PurchaseRoutes.helpPriceCompare) != nil
    }
}

extension OpenPurchaseController {
    /// 拼多多（30111）：执行授权跳转方案（不上报 link_jump）。只在前台、仍属本次授权时执行下一步（共性第 25 条：进后台、系统弹出
    /// 应用市场后不再继续）；拉起后回到前台由服务端确认（onForeground）。
    func runAuthJump(_ plan: TradeObject, _ context: AuthContext, _ gen: Int) {
        let backgrounds = backgroundCount
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await executor.execute(
                plan: plan, platform: context.platform, installed: ports.installed(context.platform), identity: nil,
                allowed: { [weak self] in
                    self.map {
                        $0.authLive(context, gen) && $0.originCurrent(context.origin) && $0.foreground && $0.authPermit
                    } ?? false
                }
            )
            guard authCurrent(context, gen) else { return }
            let launched = outcome.run.final == JumpTypes.finalOpened || outcome.run.final == JumpTypes.finalBrowser
            if launched || outcome.stopped {
                // 拉起了，或跳转途中进入后台：回来后由服务端确认（查到未授权即给二选一）。拉起的异步回调晚于回前台通知时
                // （已进过后台、此刻已在前台），立即补查（共性第 38 条）
                hideDialog()
                if foreground, backgroundCount > backgrounds {
                    queryBindings(context, afterBind: false)
                } else {
                    awaitingAuthReturn = true
                }
            } else {
                authFailed(context)
            }
        }
    }

    /// 淘宝：按 auth_methods 取本端能执行的第一种；含 30104 按 reason 的恢复（新 state、新凭证与新幂等键，共性第 18 条）。
    func runTaobaoAuth(_ context: AuthContext, _ gen: Int) {
        let flow = taobaoFlow(context, gen)
        guard flow.pick(platform: context.platform, data: context.data) != nil else {
            // 本端执行不了下发的任何授权方式（web_code 回跳未登记、百川不可用，TODO(N-28)）：按授权失败（BR-ID-17、BR-ID-18）
            authFailed(context)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await flow.run(platform: context.platform, initial: context.data)
            // 等待之后复核仍属本次授权（共性第 20 条）与固定来源（iOS RC-06）
            guard authCurrent(context, gen) else { return }
            switch outcome {
            case .bound:
                authorized(context, gen)
            case .cancelled:
                clearOwnPending(context.attempt)
                showDialog(.authDeclined(platform: context.platform, failed: false), from: context.attempt)
            case .failed:
                authFailed(context)
            case let .requestFailed(result):
                bindFailed(context, result)
            case .abandoned:
                break
            }
        }
    }

    /// 授权流程的绑定与 30104 恢复取授权地址都带授权上下文固定的请求归属（第五次修复 RC-06 残余）：alive 检查之后才换号的，网络层零发送。
    func taobaoFlow(_ context: AuthContext, _ gen: Int) -> TaobaoAuthFlow {
        TaobaoAuthFlow(
            calls: calls, group: Self.authGroup, webCode: webCode, baichuan: baichuan, keyGenerator: keyGenerator,
            expected: context.request,
            alive: { [weak self] in
                self.map { $0.authLive(context, gen) && $0.originCurrent(context.origin) } ?? false
            },
            installed: { [weak self] in self?.ports.installed($0) ?? TradeConstants.installedUnknown },
            relaunchAllowed: { [weak self] in self.map { $0.authPermit && $0.foreground } ?? false }
        )
    }

    /// 淘宝绑定（或 30104 后重新取授权地址）没有拿到结果：按码处理，限流、服务端故障不当成用户没授权（共性第 19 条）。
    func bindFailed(_ context: AuthContext, _ result: ApiResult) {
        if case let .failure(code, _, data, _, _, _) = result {
            let object = TJSON.parse(data) ?? [:]
            if code == 30151 || code == 30153 {
                clearOwnPending(context.attempt)
                let outcome = OpenErrorAction.map(code: code, data: object)
                showDialog(
                    .notice(textKey: outcome.textKey, traceId: nil, noRebate: true, contact: true, retry: false),
                    from: context.attempt
                )
                return
            }
            if code == 30101 || code == 30102, TJSON.string(object["reason"]) == TradeConstants.authUnavailable {
                clearOwnPending(context.attempt)
                showDialog(
                    .authUnavailable(textKey: OpenErrorAction.map(code: code, data: object).textKey),
                    from: context.attempt
                )
                return
            }
        }
        authCheckFailed(context, result, afterBind: true)
    }

    /// 授权状态查询 / 绑定请求失败（共性第 19、23 条）：42901 按 Retry-After（缺省 5 秒）禁用（购买按钮与【重试】置灰，执行层也拦下）；
    /// 5xxxx 显示对应错误与 trace6；断网用网络错误文案。都不清待办、不当成用户取消授权，给【重试】重新查询。其它业务码按授权失败。
    func authCheckFailed(_ context: AuthContext, _ result: ApiResult, afterBind: Bool) {
        let millis = TradeResults.disableMillis(result)
        if millis > 0 {
            startBlock(millis)
        }
        var textKey: String = PurchaseTextKeys.network
        var trace: String?
        if case let .failure(code, _, data, traceId, _, _) = result {
            let serverError = (50000...59999).contains(code)
            guard code == 42901 || serverError else {
                authFailed(context)
                return
            }
            textKey = OpenErrorAction.map(code: code, data: TJSON.parse(data) ?? [:]).textKey ?? PurchaseTextKeys
                .generic
            trace = serverError ? traceId : nil
        }
        authContext = context
        showDialog(
            .authCheckFailed(platform: context.platform, textKey: textKey, traceId: trace, afterBind: afterBind),
            from: context.attempt
        )
    }

    /// 查询授权状态（listUnionBindings）：查询成功且该平台 active → 自动执行一次 open（新键）；查询成功但没有授权 → 删除待办，给二选一
    /// （拼多多回来：未完成授权；淘宝绑定之后：授权失败）；请求失败 → `authCheckFailed`（共性第 19 条）。
    func queryBindings(_ context: AuthContext, afterBind: Bool) {
        // 发授权状态查询之前先比较来源（iOS RC-06）
        guard originCurrent(context.origin) else {
            dropStaleAuth(context)
            return
        }
        // 每次查询一个新世代：同一授权上下文的旧查询（重试之前的）也作废（共性第 20 条）
        authGen += 1
        let gen = authGen
        calls.cancel(group: Self.authGroup)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 带授权上下文固定的请求归属：查询排队期间换号由网络层比较拒绝（第五次修复 RC-06 残余）
            let result = await calls.send(
                ApiCall(operationId: TradeOperations.listUnionBindings),
                group: Self.authGroup, expected: context.request
            )
            // 返回时核对仍属当前购买尝试与本次查询：新点击之后到达的旧查询只丢弃，不清待办、不关弹窗、不自动 open。
            // 别的页面（同一份待办记录）之后登记的待办不归本页：下面的清除、消费都先核对归属（共性第 44 条）
            guard authCurrent(context, gen) else { return }
            guard case let .success(data, _, _) = result else {
                authCheckFailed(context, result, afterBind: afterBind)
                return
            }
            let items = TJSON.objects(TJSON.parse(data)?["items"])
            let active = items.contains {
                TJSON.string($0["platform"]) == context.platform && TJSON.string($0["status"]) == TradeConstants.active
            }
            if active {
                authorized(context, gen)
            } else if afterBind {
                authFailed(context)
            } else {
                clearOwnPending(context.attempt)
                showDialog(.authDeclined(platform: context.platform, failed: false), from: context.attempt)
            }
        }
    }

    /// 授权完成：前置完成即自动执行一次 open，用新键（BR-ID-10 / 22 细则）；待办已过期（> 10 分钟）就不执行，等用户再点。
    /// 关弹窗之前核对仍属当前尝试与授权世代（授权上下文置空、世代加 1，只处理一次）；本页本次尝试的授权待办此时只重新计时、不删
    /// （共性第 46 条）。真正执行前（在前台立即执行，否则等回前台）再核对：尝试与世代没变（期间没有新点击，共性第 20 条）、待办仍在
    /// 有效期内（BR-ID-10，10 分钟）且仍是本页这次尝试登记的（没被别的页面的新待办取代，共性第 44 条），通过后才消费一次；过期或被
    /// 取代即放弃（过期的由待办记录自己删除，被取代的是别人的不动）。恢复用原点击的卡（报价基准与 link_id，共性第 24 条）。
    func authorized(_ context: AuthContext, _ gen: Int) {
        guard authCurrent(context, gen) else { return }
        authContext = nil
        authGen += 1
        let resumeGen = authGen
        // 先核归属再计时：只动本页本次尝试登记的授权待办，别的页面后来登记的不动（共性第 44 条）
        let record = ownPending(context.attempt, kind: PurchasePendingKeys.kindAuth)
        if record != nil {
            pending.stepDone()
        }
        hideDialog()
        let target = latestCard(context.attempt)
        guard let record, TJSON.string(record["link_id"]) == context.linkId,
              TJSON.string(target["link_id"]) == context.linkId else { return }
        authResume = context
        whenForeground(.auth) { [weak self] in
            guard let self, authResume === context else { return }
            authResume = nil
            guard resumeStillMine(context, resumeGen) else {
                dropAuthPending(context)
                return
            }
            // 执行前再核待办：过期（peek 不再返回）或被新待办取代 → 放弃，不自动 open（共性第 46 条）
            guard let live = ownPending(context.attempt, kind: PurchasePendingKeys.kindAuth),
                  TJSON.string(live["link_id"]) == context.linkId else { return }
            pending.clear()
            // 授权后再发是新请求、新键（BR-ID-10 细则）；平台状态在 send 里再核对（共性第 27 条）
            guard purchasable(target, notify: true) else { return }
            // 沿用授权上下文（即原尝试）的固定来源与请求归属，不在执行时重新读当前会话（APP-09 共性第 65 条）
            startClick(
                target, key: keys.resendAfterAuth(), noRebate: false, noRebateReason: nil, userAuthRetry: false,
                source: context.attempt.source
            )
        }
    }

    func authFailed(_ context: AuthContext) {
        clearOwnPending(context.attempt)
        showDialog(.authDeclined(platform: context.platform, failed: true), from: context.attempt)
    }
}

// MARK: - 登录 / 同意恢复、生命周期

public extension OpenPurchaseController {
    /// 登录完成后（会话由游客变为已登录时 App 调）：本页登记的购买待办仍有效 → 删除并自动重放一次原尝试（原路径、原请求体、原键：
    /// 10001 不写幂等记录，BR-ID-10 细则）。外跳类动作恢复执行仍视为用户点击触发；页面不在前台（登录页还盖着）时等回到前台再执行。
    func resumeAfterLogin() {
        guard !left else { return }
        guard foreground else {
            deferred[.login] = { [weak self] in self?.resumeAfterLogin() }
            return
        }
        guard !busy, env.loggedIn(), let attempt = current,
              let record = ownPending(attempt, kind: PurchasePendingKeys.kindLogin),
              TJSON.string(record["link_id"]) == attempt.linkId,
              TJSON.string(record["idempotency_key"]) == attempt.key
        else { return }
        pending.clear()
        click += 1
        let replay = attempt.replay(click: click)
        current = replay
        ready = nil
        grantPermit(replay)
        send(replay)
    }

    /// 补同意完成（隐私变为已同意时 App 调）：本页登记的购买待办仍有效 → 删除并按原点击的那张卡执行一次购买（还没发过请求，新键；
    /// 报价基准与 link_id 都是原点击的，共性第 24 条）；不在前台时等回到前台。仍不同意时 Router 删除待办，这里什么都不做。
    func resumeAfterConsent() {
        guard !left else { return }
        guard foreground else {
            deferred[.consent] = { [weak self] in self?.resumeAfterConsent() }
            return
        }
        guard let consent = consentCard, let record = ownPending(kind: PurchasePendingKeys.kindConsent),
              TJSON.string(record["link_id"]) == TJSON.string(consent.card["link_id"])
        else { return }
        pending.clear()
        consentCard = nil
        guard !env.basicMode() else { return }
        buy(consent.card, spm: consent.spm)
    }

    /// 回到前台（发起页可见且 App 在前台）：先执行等前台的自动动作（登录、补同意、授权后的恢复）；拼多多授权跳转之后由服务端确认
    /// （listUnionBindings）：确认已授权 → 自动执行一次 open（新键）；查询成功但未授权 → 删除待办，给二选一（BR-ID-22 细则）；
    /// 查询失败（42901、5xxxx、传输失败）→ `authCheckFailed`（共性第 19 条）。登录页关闭回来仍是游客（用户放弃登录）：删除本页登记的
    /// 登录待办，之后在别处登录也不会替它外跳（TODO(N-28) I 段）。
    func onForeground() {
        guard !left else { return }
        foreground = true
        // 按类型逐槽执行（共性第 48 条）：授权恢复、登录恢复、补同意恢复各自核对待办类型、归属与尝试，不互相覆盖
        for kind in DeferredResume.allCases {
            if let action = deferred.removeValue(forKey: kind) {
                action()
            }
        }
        if !env.loggedIn(), let attempt = current,
           let record = ownPending(attempt, kind: PurchasePendingKeys.kindLogin),
           TJSON.string(record["link_id"]) == attempt.linkId {
            pending.clear()
        }
        guard awaitingAuthReturn else { return }
        awaitingAuthReturn = false
        guard let context = authContext else { return }
        queryBindings(context, afterBind: false)
    }

    /// 发起页被盖住或 App 进入后台：作废续执行许可；在途响应之后只更新卡片（03 §4.5，共性第 3 条）。
    func onBackground() {
        guard foreground else { return }
        foreground = false
        backgroundCount += 1
        authPermit = false
        revokePermit()
        if state.phase == .loading {
            interrupt = LateResponsePolicy.background
            timer?.cancel()
            state.phase = .idle
        }
        browserDecision?.complete(false)
    }

    /// 页面出栈（同步出口）：作废在途请求并取消传输；本页登记的购买待办删除（不能再自动执行）。
    func leave() {
        guard !left else { return }
        left = true
        interrupt = LateResponsePolicy.leave
        revokePermit()
        deferred.removeAll()
        timer?.cancel()
        gate.cancelTimer()
        browserDecision?.complete(false)
        authGen += 1
        calls.cancel()
        // 只删本页登记的（别的页面的待办不动，共性第 44 条）
        clearOwnPending()
    }
}
