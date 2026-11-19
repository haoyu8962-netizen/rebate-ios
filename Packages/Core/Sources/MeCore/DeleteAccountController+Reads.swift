import Combine
import CouliNetwork
import Foundation
import Generated
import WalletCore

/// 读取：getDeletion、钱包摘要、getMe（都在受限会话表内，BR-ID-01）。同类读取只收最新一次；出栈 / 换代在同步出口作废（`leave`）。
extension DeleteAccountController {
    func loadAll(explicit: Bool) {
        loadDeletion()
        loadFunds(explicit: explicit)
        if state.phoneBound == nil {
            loadMe()
        }
    }

    /// 写请求成功带回的进度：先推进读取世代（作废在途的旧读取），再采用（APP-12 第 29、35 条）。
    func setRead(_ read: DeletionRead) {
        _ = advance(Self.getDeletion)
        state.read = read
        state.readFailed = false
        state.readError = nil
        state.version += 1
    }

    /// 作废同类在途读取并推进世代，返回这一次的序号。
    func advance(_ slot: String) -> Int {
        readFlags.removeValue(forKey: slot)?.invalidate()
        let next = (readSerials[slot] ?? 0) + 1
        readSerials[slot] = next
        return next
    }

    func loadDeletion() {
        read(Self.getDeletion, gate: deps.gates.deletionRead, gated: { [weak self] notice in
            self?.deletionFailed(notice)
        }, settle: { [weak self] result, probe in
            self?.deletionArrived(result, probe: probe)
        })
    }

    func loadFunds(explicit: Bool) {
        read(Self.walletSummary, gate: deps.gates.read, gated: { [weak self] notice in
            self?.fundsFailed(notice)
        }, settle: { [weak self] result, probe in
            self?.fundsArrived(result, probe: probe, explicit: explicit)
        })
    }

    func loadMe() {
        let gate = ports?.meReadGate ?? deps.gates.read
        read(Self.getMe, gate: gate, gated: { [weak self] notice in
            self?.meFailed(notice)
        }, settle: { [weak self] result, probe in
            self?.meArrived(result, probe: probe, gate: gate)
        })
    }

    /// 一次读调用：发出前按固定身份核对（暂时未知记待补做），禁用期内不发（按 42901 结算）；结果只在归属、序号、身份、作用域都仍有效时交给 `settle`。
    func read(
        _ operationId: String, gate: RetryAfterGate, gated: @escaping @MainActor @Sendable (Notice) -> Void,
        settle: @escaping @MainActor @Sendable (ApiResult, SendProbe) -> Void
    ) {
        guard alive else { return }
        let owner = identity.owner
        guard deferral.admit(deps.env.check(owner), slot: "read.\(operationId)", resume: { [weak self] in
            self?.read(operationId, gate: gate, gated: gated, settle: settle)
        }), scopeHolds else { return }
        if gate.active {
            gated(notice("error.42901"))
            return
        }
        let ticket = advance(operationId)
        let flag = RequestFlag()
        readFlags[operationId] = flag
        let probe = gate.probe()
        let api = deps.api
        Task { @MainActor [weak self] in
            let result = await api.send(
                ApiCall(operationId: operationId), isValid: { flag.isValid }, sendAllowed: probe.allowed,
                expected: owner.request
            )
            guard let self, flag.isValid, readSerials[operationId] == ticket else { return }
            readFlags[operationId] = nil
            arrive(operationId, owner: owner, ticket: ticket) { settle(result, probe) }
        }
    }

    /// 到达后的身份核对（暂时未知 → 留到身份确认后再采用；已换代 → 丢弃）。
    func arrive(_ slot: String, owner: WalletOwner, ticket: Int, _ adopt: @escaping @MainActor @Sendable () -> Void) {
        guard alive, readSerials[slot] == ticket else { return }
        guard deferral.admit(deps.env.check(owner), slot: "arrive.\(slot)", resume: { [weak self] in
            self?.arrive(slot, owner: owner, ticket: ticket, adopt)
        }), scopeHolds else { return }
        adopt()
    }

    /// 读取失败的统一处理（共性第 33、37 条）：本响应自己的 42901 先写共享禁用期；10405 只看网络层 Effect（WalletErrors 已按 Effect 分）；
    /// 5xxxx 统一错误 + trace6。nil = 被作废，静默。
    func failureNotice(_ result: ApiResult, probe: SendProbe, gate: RetryAfterGate) -> Notice? {
        let error = WalletErrors.of(result, probe: probe)
        switch error.kind {
        case .cancelled:
            return nil
        case .gated:
            return notice("error.42901")
        case .retryAfter:
            gate.start(error.disableMillis)
            return notice("error.42901")
        case .forceUpdate:
            return notice("error.10405")
        default:
            serial += 1
            return error.notice(id: serial)
        }
    }

    // MARK: - getDeletion

    func deletionArrived(_ result: ApiResult, probe: SendProbe) {
        guard case let .success(data, traceId, _) = result else {
            if let failure = failureNotice(result, probe: probe, gate: deps.gates.deletionRead) {
                deletionFailed(failure)
            }
            return
        }
        let read = DeletionJson.read(data)
        guard read != .bad else {
            // 坏数据（必填缺失、类型不符、不认识的 status）：按读取失败，不当成「从未申请」
            deletionFailed(notice("error.50001", traceId: traceId, trace6: true))
            return
        }
        state.read = read
        state.readFailed = false
        state.readError = nil
        state.version += 1
        // 撤回结果未知后的核对（共性第 14、33 条）：查明已撤回走撤回成功结算；仍在冷静期只留人工重试，不自动重发
        if cancelReconcile {
            cancelReconcile = false
            if let deletion = read.deletion, deletion.cancelledByUser {
                ports?.deletionChanged(identity.owner)
                cancelSucceeded(deletion)
            }
        }
    }

    /// getDeletion 失败：整页错误与【重试】，申请与撤回都不可用（不能当成从未申请，brief §0「trace6」）。
    func deletionFailed(_ failure: Notice) {
        state.readFailed = true
        state.readError = failure
        state.version += 1
    }

    // MARK: - 钱包摘要

    func fundsArrived(_ result: ApiResult, probe: SendProbe, explicit: Bool) {
        guard case let .success(data, traceId, _) = result else {
            if let failure = failureNotice(result, probe: probe, gate: deps.gates.read) {
                fundsFailed(failure)
            }
            return
        }
        guard let funds = DeletionJson.funds(WalletJSON.parse(data)) else {
            // 5xxxx / 坏数据不伪装成「余额为 0」（APP-06b 第 19 条）
            fundsFailed(notice("error.50001", traceId: traceId, trace6: true))
            return
        }
        state.funds = funds
        state.fundsFailed = false
        state.fundsError = nil
        if explicit {
            // 用户主动刷新：申请资格按这一次新读取更新（共性第 34、42 条）
            state.blocked30416 = false
            state.amount30416 = nil
        }
        state.version += 1
    }

    func fundsFailed(_ failure: Notice) {
        state.fundsFailed = true
        state.fundsError = failure
        state.version += 1
    }

    // MARK: - getMe

    func meArrived(_ result: ApiResult, probe: SendProbe, gate: RetryAfterGate) {
        guard case let .success(data, _, _) = result else {
            let failure = failureNotice(result, probe: probe, gate: gate)
            if let failure {
                meFailed(failure)
            }
            return
        }
        state.phoneBound = DeletionJson.phoneBound(WalletJSON.parse(data))
        guard submitAfterMe else { return }
        submitAfterMe = false
        continueSubmit()
    }

    func meFailed(_ failure: Notice) {
        guard submitAfterMe else { return }
        submitAfterMe = false
        state.notice = failure
    }

    /// 点【申请注销】时 phone_bound 未知、重取 getMe 查清之后：仍可申请才按同一个固定身份继续。
    func continueSubmit() {
        guard alive, applyEnabled, deps.env.isCurrent(identity.owner), scopeHolds else { return }
        switch state.phoneBound {
        case true?:
            flow.submitDeletion(owner: identity.owner)
        case false?:
            state.notice = notice(Self.noPhoneKey)
        case nil:
            state.notice = notice(WalletErrors.networkKey)
        }
    }

    // MARK: - 读闸门到期

    /// 订阅依赖的读闸门（共性第 19 条）：限流结束时把因限流失败的读取重做一次；离页（`leave`）取消订阅。
    func watchGates() {
        var gates = [deps.gates.deletionRead, deps.gates.read]
        if let me = ports?.meReadGate {
            gates.append(me)
        }
        for gate in gates {
            gate.$blocked.dropFirst().sink { [weak self] blocked in
                MainActor.assumeIsolated { self?.gateChanged(blocked: blocked) }
            }.store(in: &subscriptions)
        }
    }

    /// 读闸门变化：限流结束且页面仍在时，重做因限流失败的读取。
    func gateChanged(blocked: Bool) {
        guard !blocked, alive else { return }
        if state.readFailed {
            loadDeletion()
        }
        if state.fundsFailed {
            loadFunds(explicit: false)
        }
    }

    /// 表外码：已收录用 error.<code>，否则回落 error.50001。
    static func errorKey(_ code: Int) -> String {
        DefaultTexts.text("error.\(code)") != nil ? "error.\(code)" : "error.50001"
    }
}
