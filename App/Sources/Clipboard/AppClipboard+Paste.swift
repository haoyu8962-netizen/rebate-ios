import Clipboard
import Combine
import Config
import CouliNetwork
import DesignSystem
import Foundation
import Login
import Privacy
import Router

/// 用户主动粘贴、parse 结果与限流（AppClipboard 的执行层）。
extension AppClipboard {
    // MARK: - 用户主动粘贴

    /// 粘贴入口此刻可用（已同意、没有限流、没有在途、没有敏感浮层）。
    var pasteEnabled: Bool {
        !blocked && !busy && deps.privacy() == .consented && overlayClear()
    }

    /// 首页卡 / SearchTyping 的系统粘贴控件被点了（UIKit 同步调接收方 paste(itemProviders:) 的那一刻）。文本由系统稍后异步交付：
    /// 这里捕获发起页、界面世代、前台轮次、隐私、会话、环境票据，返回交付回调；交付时先复核，失效即丢弃，不用交付时的当前页重新归属
    /// （共性第 28 条）。读取等待期间按忙碌置灰，作废出口同步解除。nil = 这次点击不读。
    func beginPaste(entry: String) -> PasteDelivery? {
        guard deps.privacy() == .consented, overlayClear(), !busy else { return nil }
        guard !blockActive else {
            notice(origin: currentOrigin(), key: ParseResultAction.key(ParseResultAction.rateLimited), traceId: nil)
            return nil
        }
        return startRead(entry: entry)
    }

    /// 点击与交付在同一时刻（测试与同步调用方）。
    func pasted(entry: String, text: String?) {
        beginPaste(entry: entry)?(text)
    }

    /// 点击时的票据。
    struct PasteTicket {
        let id: Int64
        let entry: String
        let origin: String
        let screen: Int64
        let manual: Int64
        let round: Int64
        let session: UInt64
        let epoch: UInt64
    }

    func startRead(entry: String) -> PasteDelivery {
        counter += 1
        let ticket = PasteTicket(
            id: counter, entry: entry, origin: currentOrigin(), screen: screenGen, manual: manualGen,
            round: watcher.round, session: deps.sessionGeneration(), epoch: deps.networkEpoch()
        )
        reading = ticket.id
        readCount += 1
        busy = true
        // 手动粘贴开始：收起已有商品提示条，所有商品粘贴入口共享这次在途保护（R2-02）
        prompt = nil
        return { [weak self] text in
            self?.delivered(ticket, text: text)
        }
    }

    /// 系统交付了文本：只认这次点击的那一次读取（作废出口已清掉的、重复交付的都丢弃），再复核点击时的票据。
    func delivered(_ ticket: PasteTicket, text: String?) {
        guard reading == ticket.id else { return }
        reading = nil
        busy = !tasks.isEmpty
        guard ticket.round == watcher.round, ticket.screen == screenGen,
              ticket.manual == manualGen, currentOrigin() == ticket.origin, overlayClear(),
              deps.privacy() == .consented, deps.sessionGeneration() == ticket.session,
              deps.networkEpoch() == ticket.epoch, !blockActive
        else { return }
        handlePaste(entry: ticket.entry, text: text, origin: ticket.origin)
    }

    func handlePaste(entry: String, text: String?, origin: String) {
        let selfWritten = text.map(ledger.contains) ?? false
        if let text, !text.isEmpty {
            // 用户主动粘贴不套 24 小时去重，但同样记下（H02 同口径）
            history.record(ClipboardText.sha256(text))
        }
        let decision = ManualPasteAction.decide(
            entry: entry, text: text, rules: rules(), shareDomains: shareDomains(), selfWritten: selfWritten
        )
        switch decision.actionRaw {
        case ManualPasteAction.openSearchTyping:
            if entry == ManualPasteAction.entryHome {
                open(Self.searchRoute, [:])
            }
        case ManualPasteAction.searchPrefill:
            show(origin, .unrecognized(ClipboardDraftTexts.text(ParseResultAction.key(ParseResultAction.unrecognized)),
                                       prefill: decision.prefill))
        case ManualPasteAction.parse:
            if let upload = decision.uploadText {
                // 整体 30132 的预填：请求前本地抽出的「」标题随本次请求绑定，不保存原文（共性第 30 条）
                manualParse(upload, title: text.flatMap(ClipboardText.quotedTitle), origin: origin)
            }
        case ManualPasteAction.invite:
            // 只有邀请内容：不上传 parse（共性第 13、15 条）。游客出确认，确认后预填登录页；已登录按 G01 静默（共性第 19 条）
            // TODO(N-30) G01：契约补 POST /v1/me/inviter 与 InviteBackfill 路由后接已登录用户的补填
            if let code = decision.code, deps.guest() {
                show(origin, .inviteConfirm(code: code))
            }
        default:
            break
        }
    }

    func manualParse(_ upload: String, title: String?, origin: String) {
        let gen = manualGen
        let screen = screenGen
        let session = deps.sessionGeneration()
        let epoch = deps.networkEpoch()
        publishOwner()
        let box = owner
        let stillOwned: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return gen == manualGen && screen == screenGen && watcher.inForeground && currentOrigin() == origin
                && overlayClear() && deps.privacy() == .consented && deps.sessionGeneration() == session
                && deps.networkEpoch() == epoch
        }
        counter += 1
        let key = counter
        parseCount += 1
        busy = true
        let parser = parser
        tasks[key] = Task { @MainActor [weak self] in
            // 网络线程的核对只读快照（共性第 12 条）
            let outcome = await parser.parse(upload, title: title) {
                box.owns(manual: gen, screen: screen, origin: origin)
            }
            guard let self else { return }
            tasks[key] = nil
            if tasks.isEmpty, reading == nil {
                busy = false
            }
            guard !Task.isCancelled, !outcome.dropped, stillOwned(), let action = outcome.action else { return }
            act(action, origin: origin)
        }
    }

    /// 登录页的邀请码【粘贴】（每个登录页一份；限流时置灰）。点击时绑定这个登录页实例与前台轮次，交付时复核（共性第 28 条）。
    func makeLoginInvitePaste() -> LoginInvitePaste {
        let paste = LoginInvitePaste { [weak self] in
            self?.beginLoginInvitePaste()
        }
        paste.enabled = !blocked
        invitePastes.add(paste)
        return paste
    }

    /// 登录页邀请码【粘贴】被点了：捕获此刻的登录页实例、界面世代、前台轮次、会话、环境票据（共性第 2、28 条）；交付时全部复核，
    /// 页面被覆盖过（即使返回同一登录页实例，界面世代已推进）、经过后台、隐私 / 会话 / 环境变化、出现敏感浮层都丢弃（.ignored），
    /// 不覆盖返回后填写的邀请码，也不弹迟到的「未识别到邀请码」（R2-01）。
    func beginLoginInvitePaste() -> ((String?) -> LoginInvitePasteOutcome)? {
        guard let page = path.last, page.route == Self.loginRoute, deps.privacy() == .consented, overlayClear()
        else { return nil }
        counter += 1
        let id = counter
        let screen = screenGen
        let round = watcher.round
        let session = deps.sessionGeneration()
        let epoch = deps.networkEpoch()
        loginReading = id
        return { [weak self] text in
            guard let self, loginReading == id else { return .ignored }
            loginReading = nil
            guard path.last?.id == page.id, screenGen == screen, watcher.round == round,
                  overlayClear(), deps.privacy() == .consented, deps.sessionGeneration() == session,
                  deps.networkEpoch() == epoch
            else { return .ignored }
            return loginInvitePasted(text)
        }
    }

    /// 登录验证码页邀请码行【粘贴】：只抽码（BR-INV-04）。42901 禁用期内执行层也拦（共性第 6 条），给限流提示，不误报「未识别到邀请码」。
    func loginInvitePasted(_ text: String?) -> LoginInvitePasteOutcome {
        guard deps.privacy() == .consented, path.last?.route == Self.loginRoute else { return .ignored }
        guard !blockActive else {
            return .message(ClipboardDraftTexts.text(ParseResultAction.key(ParseResultAction.rateLimited)))
        }
        let decision = ManualPasteAction.decide(entry: ManualPasteAction.entryLoginInvite, text: text, rules: rules())
        guard let code = decision.code else {
            return .message(ClipboardDraftTexts.text("clipboard.login_invite.not_found"))
        }
        return .code(code)
    }

    // MARK: - 结果

    func act(_ action: ParseAction, origin: String) {
        switch action.actionRaw {
        case ParseResultAction.openDetail:
            guard let card = action.card else { return }
            if !openDetail(card) {
                show(origin, .cardList([ParseRow(card: card, errorCode: nil, hitRaw: nil)], traceId: action.traceId))
            }
        case ParseResultAction.cardList:
            showCardList(action, origin: origin)
        case ParseResultAction.searchPrefill:
            show(origin, .unrecognized(ClipboardDraftTexts.text(action.textKey ?? ""), prefill: action.prefill))
        case ParseResultAction.retryAfter:
            block(action.disableMs ?? ErrorActionMapper.defaultRetryAfterMillis)
            notice(origin: origin, key: action.textKey, traceId: nil)
        case ParseResultAction.forceUpdate:
            enterForceUpdate(action)
        case ParseResultAction.error:
            notice(origin: origin, key: action.textKey, traceId: action.showTrace6 == false ? nil : action.traceId)
        default:
            notice(origin: origin, key: action.textKey, traceId: nil)
        }
    }

    /// 行内 10405（外层成功）：网络层没见到，执行层主动进强更（共性第 20、21 条）。整体 10405：网络层只判定、不替 parse 执行；
    /// 走到这里已在主线程复核过归属（manualParse 的 stillOwned，与这里之间没有等待），才进强更（共性第 29 条）。
    func enterForceUpdate(_ action: ParseAction) {
        if action.inline {
            deps.serverForced()
        } else if action.networkForced {
            deps.networkForced(action.minSupportedVersion)
        }
    }

    /// 多条结果：行内 42901 启动共享禁用期（成功响应没有 Retry-After，按 5 秒，A16）；行内 10405 主动进强更（共性第 20、21 条）。
    func showCardList(_ action: ParseAction, origin: String) {
        if action.rows.contains(where: { $0.card == nil && $0.errorCode == ParseResultAction.rateLimited }) {
            block(ErrorActionMapper.defaultRetryAfterMillis)
        }
        if action.inline, action.errorCode == ParseResultAction.forceUpdateCode {
            deps.serverForced()
            return
        }
        show(origin, .cardList(action.rows, traceId: action.traceId))
    }

    func show(_ origin: String, _ kind: ClipboardResult.Kind) {
        counter += 1
        result = ClipboardResult(id: counter, origin: origin, kind: kind)
    }

    func notice(origin: String, key: String?, traceId: String?) {
        show(origin, .notice(ClipboardDraftTexts.error(key, traceId: traceId)))
    }

    /// 结果仍是当前结果、发起页仍是当前页（共性第 16、18、26 条：按编号核对，不读「最新状态」去执行旧回调）。
    func current(_ id: Int64) -> ClipboardResult? {
        guard let result, result.id == id, result.origin == currentOrigin(), deps.privacy() == .consented else {
            return nil
        }
        return result
    }

    /// 结果提示被关掉（只关自己那一条，旧回调不清新结果）。
    func dismissResult(_ id: Int64) {
        if result?.id == id {
            result = nil
        }
    }

    /// 30132 的【用商品名搜索】：发起页是 SearchTyping 时填进本页搜索框；否则经 Router 打开 Search（q 预填，提取不到留空）。
    func searchByName(_ id: Int64, prefill: String?) {
        guard let result = current(id), overlayClear(), !blockActive else { return }
        self.result = nil
        let query = prefill.map { String($0.prefix(Self.searchQueryMax)) } ?? ""
        if let top = path.last, top.id.uuidString == result.origin, let fill = fills[top.id] {
            fill(query)
            return
        }
        open(Self.searchRoute, query.isEmpty ? [:] : ["q": .string(query)])
    }

    /// 邀请确认（游客）：发起页仍是当前页才预填登录页；不发请求（brief §2.7、G16）。
    func confirmInvite(_ id: Int64) {
        guard let result = current(id), case let .inviteConfirm(code) = result.kind, overlayClear(), !blockActive
        else { return }
        self.result = nil
        let session = deps.guest() ? InviteConfirmAction.sessionGuest : InviteConfirmAction.sessionPhone
        // 已登录用户 me 一律按拿不到（G01：界面不出已登录用户的邀请提示）
        guard InviteConfirmAction.decide(session: session, me: nil).actionRaw == InviteConfirmAction.prefillLogin
        else { return }
        invitePrefill.set(code)
        open(Self.loginRoute, [:])
    }

    /// 多卡弹层点一张卡或它的购买按钮：以这张卡为种子打开详情。共享限流禁用期内执行层拦下（不导航、不关弹层，共性第 31 条）。
    func openCard(_ id: Int64, card: [String: Any]) {
        guard current(id) != nil, overlayClear(), !blockActive else { return }
        result = nil
        openDetail(card)
    }

    /// 多卡弹层里一条错误行的文案（共性第 5、9 条，按码）：5xxxx 带本次 trace_id 末 6 位，其余 error.<码>。
    static func rowText(_ row: ParseRow, traceId: String?) -> String {
        let code = row.errorCode ?? ParseResultAction.unsupported
        return ClipboardDraftTexts.error(
            ParseResultAction.key(code), traceId: code >= ParseResultAction.serverErrorMin ? traceId : nil
        )
    }

    @discardableResult
    func openDetail(_ card: [String: Any]) -> Bool {
        guard let platform = card["platform"] as? String, !platform.isEmpty,
              let key = card["product_key"] as? String, !key.isEmpty
        else { return false }
        seeds.put(key, card: card)
        var params: [String: JSONValue] = ["platform": .string(platform), "product_key": .string(key)]
        if let ref = card["item_ref"] as? String, !ref.isEmpty {
            params["item_ref"] = .string(ref)
        }
        return open(Self.productDetailRoute, params)
    }

    @discardableResult
    func open(_ route: String, _ params: [String: JSONValue]) -> Bool {
        let decision = router.open(RouteRequest(route: route, values: params, from: .inApp))
        return decision.kind == .open || decision.kind == .openReadonly
    }

    // MARK: - 限流

    var blockActive: Bool {
        clock() < blockUntil
    }

    func block(_ millis: Int64) {
        blockUntil = max(blockUntil, clock() + millis)
        blocked = true
        blockTimer?.cancel()
        blockTimer = Task { @MainActor [weak self] in
            while let self, blockActive {
                let wait = max(blockUntil - clock(), 1)
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
                if Task.isCancelled {
                    return
                }
            }
            self?.blocked = false
        }
    }
}

extension AppClipboard {
    /// 结果出现时的读屏播报（R3-02，共性第 33 条）：只播当前结果，每个结果编号一次（连续两次同类结果各播一次，重绘与重新出现不重复）。
    func announceResult(_ id: Int64, text: String) {
        guard result?.id == id, announcedResult != id, !text.isEmpty else { return }
        announcedResult = id
        announcer(text)
    }
}
