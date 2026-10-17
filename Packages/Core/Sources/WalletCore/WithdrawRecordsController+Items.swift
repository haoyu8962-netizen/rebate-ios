import CouliNetwork
import Foundation

/// 第一页提交、翻页、展开详情、复制与会话。
public extension WithdrawRecordsController {
    /// 翻页（滚到底）：按 next_cursor；新一轮第一页还没回来时不翻（共性第 20 条）。
    func loadMore() {
        let owner = state.owner
        guard let cursor = state.nextCursor, !left, !firstPagePending, !state.loadingMore, !deps.gates.read.active,
              admitMore(deps.env.check(owner))
        else { return }
        let current = round
        state.loadingMore = true
        state.moreError = nil
        let probe = deps.gates.read.probe()
        let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cursor
        let call = ApiCall(operationId: Self.listOperation, query: "cursor=\(encoded)&limit=\(Self.pageSize)")
        requests.send(deps.api, call, probe: probe, expected: owner.request) { [weak self] result in
            guard let self, !left, round == current, admitMore(deps.env.check(owner)) else { return }
            settleShared(result)
            moreArrived(result, probe: probe)
        }
    }

    /// 翻页的身份核对：暂时未知 → 翻页在途标记复位、记待补做（身份确认后再翻这一页）；已换代 → 丢弃。
    internal func admitMore(_ check: IdentityCheck) -> Bool {
        deferral.admit(check, slot: Self.moreSlot, resume: { [weak self] in self?.loadMore() }, settle: {
            state.loadingMore = false
        })
    }

    /// 下拉、【重试】与回到本页：刷新在途时不再受理（共性第 35 条）；共享限流中也按限流结算（共性第 55 条）。
    @discardableResult
    func refresh() -> Bool {
        guard !left, !firstPagePending else { return false }
        if deps.gates.read.active {
            gated()
            return false
        }
        load(refresh: true)
        // 用户刷新时身份暂时未知：请 App 立即核对一次（确认了就换上身份并补取）
        if deferral.isPending {
            deps.env.recheckIdentity()
        }
        return true
    }

    /// 整卡展开 / 收起；展开时取详情（交易流水号只在详情）。回调带渲染时的版本与身份（共性第 4、63 条）。
    func toggle(version: Int, id: String, owner: WalletOwner) {
        guard valid(version, owner), state.items.contains(where: { $0.withdrawalId == id }) else { return }
        if state.expanded.contains(id) {
            state.expanded.remove(id)
            return
        }
        state.expanded.insert(id)
        if state.details[id] == nil {
            fetchDetail(id)
        }
    }

    /// 【复制】交易流水号：只走统一写入口（先记自写 hash 并确认落盘，记不下就不写、提示失败；G27）。回调带渲染时的版本、单号与流水号。
    @discardableResult
    func copy(version: Int, id: String, text shown: String, owner: WalletOwner) -> Bool {
        guard valid(version, owner), let detail = state.details[id],
              let text = TradeNoRow.copyText(status: detail.status, channelOrderId: detail.channelOrderId),
              text == shown
        else { return false }
        let ok = deps.env.copy(text)
        state.toast = notice(ok ? "withdraw_detail.copied" : "withdraw_detail.copy_failed", assertive: !ok)
        return ok
    }

    /// FAILED + fail_action=change_payout_account 的【修改收款账号】（认识的通道才有）。
    func changeAccount(version: Int, id: String, owner: WalletOwner) {
        guard valid(version, owner), let item = state.items.first(where: { $0.withdrawalId == id }),
              WithdrawalText.of(item, slaText: nil).showChangeAccount
        else { return }
        visibility.navigated()
        deps.env.open(WalletRoutes.payoutAccount, params: [:], from: page)
    }

    /// 【联系客服】：统一客服出口接入前经 Router 打开 Help（同 APP-08 G09）。
    func contact(owner: WalletOwner) {
        guard !left, owner == state.owner, deps.env.isCurrent(owner) else { return }
        visibility.navigated()
        deps.env.contactService(from: WalletRoutes.withdrawRecords)
    }

    func consumeToast(_ id: Int) {
        if state.toast?.id == id {
            state.toast = nil
        }
    }

    /// 回到本页（从收款账号页返回、回前台）：各取一次（G30）。
    func setVisible(_ shown: Bool) {
        let was = visibility.visible
        visibility.set(shown)
        if shown, !was, !left {
            refresh()
        }
    }

    func sessionChanged(_ owner: WalletOwner) {
        guard !left else { return }
        round += 1
        requests.cancelAll()
        detailRequests = [:]
        roundDetails = [:]
        focusAwaiting = nil
        firstPagePending = false
        deferral.reset()
        state = RecordsSnapshot(version: state.version + 1, owner: owner)
        load()
    }

    func leave() {
        guard !left else { return }
        left = true
        round += 1
        requests.cancelAll()
        deferral.reset()
    }
}

extension WithdrawRecordsController {
    func valid(_ version: Int, _ owner: WalletOwner) -> Bool {
        !left && state.version == version && owner == state.owner && deps.env.isCurrent(owner)
    }

    func onFirstPage(_ list: ApiResult, listed: WithdrawalListData?, focus: FocusRead?, probe: SendProbe) {
        guard let data = listed else {
            let error = WalletErrors.of(list, probe: probe)
            if error.kind == .cancelled {
                return
            }
            failed(error.kind == .gated ? WalletError(.gated, "error.42901") : error)
            return
        }
        var focused: Withdrawal?
        if let focus, case let .success(raw, _, _) = focus.result,
           let detail = WalletJSON.withdrawalDetail(WalletJSON.parse(raw)), detail.withdrawalId == focus.id {
            focused = detail
        }
        // 定位读取与普通详情共用「同单只收最新请求」的接收规则（共性第 20、54、81 条）
        let focusLatest = focus.map { detailSeq[$0.id] == $0.request } ?? false
        if let focus, focused == nil, focusLatest {
            readFailed(focus.result, probe: probe)
        }
        if let focused, focusLatest {
            roundDetails[focused.withdrawalId] = focused
        }
        // 统一接收顺序（共性第 34、54 条）：本轮已接受的详情比这份列表新，整卡用详情。定位请求已被更新请求取代（iOS R3-01）：不回落采用
        // 它的旧响应，只用本轮已接受的详情；还没有就等最新请求结算后再置顶 / 展开（focusAwaiting）
        let front: Withdrawal? = if focusLatest {
            focused
        } else {
            focus.flatMap { roundDetails[$0.id] }
        }
        let listedItems = data.items.map { roundDetails[$0.withdrawalId] ?? $0 }
        let items = front.map { first in [first] + listedItems.filter { $0.withdrawalId != first.withdrawalId } }
            ?? listedItems
        var next = state
        next.phase = items.isEmpty ? .empty : .content
        next.items = items
        next.nextCursor = data.nextCursor
        if let front {
            next.expanded.insert(front.withdrawalId)
        }
        next.pinnedId = front?.withdrawalId
        // 刷新后旧详情作废（共性第 7 条）：只留本轮已接受的详情，其余展开项按本轮重取
        next.details = roundDetails.filter { entry in items.contains { $0.withdrawalId == entry.key } }
        next.error = nil
        next.refreshing = false
        next.loadingMore = false
        next.moreError = nil
        next.version += 1
        state = next
        for id in state.expanded where state.details[id] == nil && items.contains(where: { $0.withdrawalId == id })
            && detailRequests[id].map(requests.isActive) != true {
            fetchDetail(id)
        }
        if let focus, !focusLatest, front == nil, detailRequests[focus.id].map(requests.isActive) == true {
            focusAwaiting = focus.id
        }
    }

    func failed(_ error: WalletError) {
        serial += 1
        let message = error.notice(id: serial)
        state.refreshing = false
        state.loadingMore = false
        state.error = message
        if state.items.isEmpty {
            // 已有旧列表时刷新失败（共性第 29、30 条）：保留旧列表与它配套的游标，独立显示错误与【重试】
            state.phase = .error
            state.version += 1
        }
    }

    /// 读取错误统一处理（共性第 3 条）：30701、作废不提示；限流拦下提示 42901；其余（5xxxx 带 trace6）提示。
    func readFailed(_ result: ApiResult, probe: SendProbe) {
        if case let .failure(code, _, _, _, _, _) = result, code == 30701 {
            return
        }
        let error = WalletErrors.of(result, probe: probe)
        switch error.kind {
        case .cancelled:
            return
        case .gated:
            state.toast = notice("error.42901")
        default:
            serial += 1
            state.toast = error.notice(id: serial)
        }
    }

    func moreArrived(_ result: ApiResult, probe: SendProbe) {
        guard case let .success(raw, _, _) = result, let data = WalletJSON.withdrawalList(WalletJSON.parse(raw)) else {
            let error = WalletErrors.of(result, probe: probe)
            state.loadingMore = false
            switch error.kind {
            case .cancelled: state.moreError = nil
            case .gated: state.moreError = notice("error.42901")
            default:
                serial += 1
                state.moreError = error.notice(id: serial)
            }
            return
        }
        let known = Set(state.items.map(\.withdrawalId))
        // 分页插入也按统一接收顺序（共性第 34、71 条，iOS R1-07）：本轮已接受的详情比这页摘要新，整卡（状态、金额、副文案、流水号）用详情，
        // 并同步 details
        let added = data.items.filter { !known.contains($0.withdrawalId) }.map { roundDetails[$0.withdrawalId] ?? $0 }
        for item in added where roundDetails[item.withdrawalId] != nil {
            state.details[item.withdrawalId] = item
        }
        state.items += added
        state.nextCursor = data.nextCursor
        state.loadingMore = false
        state.version += 1
        // 仍处于展开、缺本轮详情且没有在途详情请求的记录（刷新前已展开、刷新后的第一页不含它）：按本轮归属与每单序号重取详情，展开卡不丢
        // 交易流水号（共性第 7、78 条，iOS R2-04）
        fetchMissingDetails(added.map(\.withdrawalId))
    }

    /// `ids` 里仍展开、本轮没有详情、也没有在途详情请求的记录逐一取详情（fetchDetail 绑定本轮与每单序号）。
    func fetchMissingDetails(_ ids: [String]) {
        for id in ids where state.expanded.contains(id) && state.details[id] == nil
            && detailRequests[id].map(requests.isActive) != true {
            fetchDetail(id)
        }
    }

    func fetchDetail(_ id: String) {
        let owner = state.owner
        if deps.gates.read.active {
            // 本地限流拦下：提示 42901（卡片保持列表数据，不留加载中）
            state.toast = notice("error.42901")
            return
        }
        let current = round
        detailCounter += 1
        let request = detailCounter
        detailSeq[id] = request
        if let old = detailRequests.removeValue(forKey: id) {
            requests.cancel(old)
        }
        let probe = deps.gates.read.probe()
        let call = detailCall(id)
        let sent = requests.send(deps.api, call, probe: probe, expected: owner.request) { [weak self] result in
            guard let self, !left, round == current, detailSeq[id] == request else { return }
            detailRequests[id] = nil
            // 身份暂时未知：不采用，记待补做（身份确认后这张单仍展开且没有详情时重取）
            guard deferral.admit(deps.env.check(owner), slot: "detail#" + id, resume: { [weak self] in
                self?.fetchMissingDetails([id])
            }) else { return }
            settleShared(result)
            detailArrived(result, id: id, probe: probe)
        }
        detailRequests[id] = sent
    }

    func detailArrived(_ result: ApiResult, id: String, probe: SendProbe) {
        guard case let .success(raw, _, _) = result, let detail = WalletJSON.withdrawalDetail(WalletJSON.parse(raw)),
              detail.withdrawalId == id
        else {
            if focusAwaiting == id {
                // 取代定位请求的最新详情失败：这张单不置顶，只保留列表数据（iOS R3-01）
                focusAwaiting = nil
            }
            readFailed(result, probe: probe)
            return
        }
        roundDetails[id] = detail
        state.details[id] = detail
        state.items = state.items.map { $0.withdrawalId == id ? detail : $0 }
        if focusAwaiting == id {
            // 取代定位请求的最新详情成功：此刻才把这张单置顶并展开（iOS R3-01）
            focusAwaiting = nil
            state.items = [detail] + state.items.filter { $0.withdrawalId != id }
            state.pinnedId = id
            state.expanded.insert(id)
        }
        // 详情改了卡片内容（状态、流水号）：渲染版本前进，旧画面的回调不再生效
        state.version += 1
    }
}
