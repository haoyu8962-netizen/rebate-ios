import CouliNetwork
import Foundation
import WalletCore

/// 撤回注销（cancelDeletion）的一次结果：码（nil = 没有统一外壳）、trace、成功带回的进度。
struct CancelReply {
    let code: Int?
    let traceId: String?
    let deletion: Deletion?

    /// 结果 → 撤回结局表的输入；nil = 不交结局表（本地拒绝、会话已清、确需强更的 10405 已由网络层进强更分流，页面不按码重判，共性第 12、37 条）。
    static func of(_ result: ApiResult) -> CancelReply? {
        switch result {
        case let .success(data, _, _):
            return CancelReply(code: 0, traceId: nil, deletion: DeletionJson.deletion(WalletJSON.parse(data)))
        case let .failure(raw, _, _, trace, effect, _):
            guard effect.kind != .forceUpdate else { return nil }
            return CancelReply(code: NonForcedUpdate.pageCode(code: raw, effect: effect), traceId: trace, deletion: nil)
        case .transportFailure:
            return CancelReply(code: nil, traceId: nil, deletion: nil)
        default:
            return nil
        }
    }
}

/// 撤回注销。
extension DeleteAccountController {
    /// 【撤回注销】（只在 can_cancel=true 时显示，G15）：不弹确认框（G16），按钮进「提交中…」；不写未决记录、不自动重发。
    /// 写请求离开页面不取消：共享禁用期与强更标签按固定身份结算（共性第 45、48、49 条），页面更新另核对页面是否还在。
    public func cancelDeletion(version: Int, owner: WalletOwner) {
        guard owns(version, owner), view.showCancel, !state.cancelling else { return }
        let gate = deps.gates.deletionCancel
        if gate.active {
            state.notice = notice("error.42901")
            return
        }
        state.cancelling = true
        state.notice = nil
        let probe = gate.probe()
        let api = deps.api
        let identity = identity
        let deps = deps
        let portsRef = ports
        Task { @MainActor [weak self] in
            let result = await api.send(
                ApiCall(operationId: Self.cancelOperation), isValid: { true }, sendAllowed: probe.allowed,
                expected: identity.owner.request
            )
            // 会话级结算：发起时的完整身份（含作用域）仍是此刻的才写共享禁用期、通知强更页标签（共性第 49 条）
            if deps.env.isCurrent(identity.owner),
               DeletionScope.normalized(portsRef?.sessionScope()) == identity.scope {
                let millis = WalletErrors.disableMillis(result)
                if millis > 0 {
                    gate.start(millis)
                }
                if case .success = result {
                    portsRef?.deletionChanged(identity.owner)
                }
            }
            self?.cancelArrived(result, probe: probe)
        }
    }

    func cancelArrived(_ result: ApiResult, probe: SendProbe) {
        guard alive, deferral.admit(deps.env.check(identity.owner), slot: "cancel", resume: { [weak self] in
            self?.cancelArrived(result, probe: probe)
        }), scopeHolds else { return }
        state.cancelling = false
        guard let reply = CancelReply.of(result) else {
            if case .localReject = result {
                state.notice = notice(probe.gated(result) ? "error.42901" : WalletErrors.networkKey)
            }
            return
        }
        let outcome = DeletionCancelOutcome.of(
            code: reply.code, source: identity.source, serverKey: SensitiveOutcome.serverKey, errorKey: Self.errorKey
        )
        switch outcome.next {
        case .cancelled:
            cancelSucceeded(reply.deletion)
        case .stay:
            state.notice = notice(outcome.textKey, traceId: reply.traceId, trace6: outcome.showTrace6)
            if outcome.reconcile {
                cancelReconcile = true
            }
            if outcome.refetch {
                loadDeletion()
            }
        }
    }

    /// 撤回成功的结算（直接成功、或结果未知后核对查明已撤回）：推进读取世代、清勾选与 30416 标记，按来源去向（G18）。
    func cancelSucceeded(_ deletion: Deletion?) {
        // 核对查明已撤回时清掉「暂时没有收到结果」提示，与直接成功同一结局（首轮评审 S2-1）
        state.notice = nil
        state.waiver = false
        state.blocked30416 = false
        state.amount30416 = nil
        if let deletion {
            setRead(.record(deletion))
        } else {
            loadDeletion()
        }
        loadFunds(explicit: false)
        let navigate = DeletionCancelOutcome.of(
            code: 0, source: identity.source, serverKey: SensitiveOutcome.serverKey, errorKey: Self.errorKey
        ).navigate
        if navigate == .none {
            state.toast = notice(DeletionCancelOutcome.withdrawnKey, assertive: false)
        } else {
            leaveTo(navigate)
        }
    }
}
