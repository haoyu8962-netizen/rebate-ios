import CouliNetwork
import Foundation
import Generated
import WalletCore

/// FlowHost：申请、确认、放弃的结局落到注销页（身份已由 SensitiveFlow 核对），以及成功之后的离页去向。
public extension DeleteAccountController {
    // MARK: - FlowHost（申请、确认、放弃的结局；身份已由流程核对）

    func onSucceeded(_ data: Any?, alreadyDone _: Bool) {
        guard alive else { return }
        state.waiver = false
        state.blocked30416 = false
        state.amount30416 = nil
        state.withdrawHint = false
        if let deletion = DeletionJson.deletion(data) {
            // 先推进进度读取的世代：在途的旧读取不能把冷静期覆盖回初始态（APP-12 第 29、35 条）
            setRead(.record(deletion))
        } else {
            loadDeletion()
        }
        ports?.deletionChanged(identity.owner)
        if identity.source == .forceUpdate {
            leaveTo(.forceUpdate)
        }
    }

    func onSettled() {
        guard alive else { return }
        loadAll(explicit: false)
    }

    func onGuide(_ route: String) {
        // 受限会话（deletion_only）只发 BR-ID-01 受限表内的操作：共用引导（绑手机号 / 实名 / 收款账号）不导航，只留结局提示（首轮评审 S3-4）
        guard alive, identity.scope == DeletionScope.full else { return }
        ports?.open(route, from: page)
    }

    func onBusinessError(_: Int) {}

    /// 注销专用的页面去向（码按原始结果读，Effect 由网络层定，页面不按码重判 10405）。
    func onOutcome(_ outcome: Outcome, result: ApiResult, phase _: String) {
        guard alive else { return }
        if outcome.actionRaw == SensitiveOutcome.abandoned {
            state.waiver = false
            return
        }
        guard case let .failure(code, msg, data, _, _, _) = result else { return }
        // G26：字典没有 error.<code> 的码（表外 3xxxx 等），记下服务端 msg 给错误条回落用
        let key = "error.\(code)"
        if DefaultTexts.text(key) == nil {
            state.serverMsg[key] = msg
        }
        switch code {
        case 30416:
            // 本次提示金额取这一次响应（缺失走兜底）；资格只在用户主动刷新后按新读取更新（共性第 10、34 条）
            state.blocked30416 = true
            state.amount30416 = DeletionJson.amountFen(data)
            state.version += 1
            loadFunds(explicit: false)
        case 30412:
            state.withdrawHint = true
        case 20903:
            state.waiver = false
        case 10007:
            // cooling：重取进度、落到冷静期态；processing：错误条只提示 error.10007（G27）
            loadDeletion()
        default:
            break
        }
    }

    // MARK: - 去向

    /// 成功之后的离页去向：页面此刻可见才执行，否则推迟到回到可见（共性第 41 条）。
    internal func leaveTo(_ exit: DeletionCancelOutcome.Navigate) {
        guard alive, exit != .none else { return }
        guard flow.visibleNow else {
            deferredExit = exit
            return
        }
        switch exit {
        case .forceUpdate:
            ports?.returnToForceUpdate(page: page)
        case .settings:
            if ports?.returnToSettings(page: page) != true {
                state.toast = notice(DeletionCancelOutcome.withdrawnKey, assertive: false)
            }
        case .none:
            break
        }
    }
}
