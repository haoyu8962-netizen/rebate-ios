import CouliNetwork
import Foundation

/// 点击【确认上一笔】/【确定放弃】时的那条记录（APP-09 共性第 14、16 条）：身份与原键在点击处固定，之后的读取、占用与发送都按它核对；
/// `stepUpReplayed` 是这次用户确认的 10003 重放预算（至多一次）。
final class PendingIntent {
    let owner: WalletOwner
    let account: String
    let key: String
    var stepUpReplayed = false

    init(owner: WalletOwner, account: String, key: String) {
        self.owner = owner
        self.account = account
        self.key = key
    }
}

/// 待确认：确认 / 放弃 / 按本机记录恢复。
public extension SensitiveFlow {
    /// 【确认上一笔】：原键、原请求体重发（二次验证照常）。`key` 与 `owner` 是渲染这张待确认卡时取出的不可变值（共性第 4、63 条）。
    func confirm(key: String, owner: WalletOwner) {
        guard let intent = intentFor(key: key, owner: owner) else { return }
        clearGuide()
        if gate.active {
            state.pendingNotice = notice(SensitiveOutcome.retryLaterKey)
            return
        }
        runConfirm(
            intent,
            token: deps.tokens.take(action: action, account: intent.account, nowMs: deps.env.nowMillis())
        )
    }

    /// 【放弃上一笔】：先弹二次确认（绑定点击时的键）。
    func askAbandon(key: String, owner: WalletOwner) {
        guard let pending = state.pending, pending.key == key, !pending.inFlight, owns(owner) else { return }
        if gate.active {
            state.pendingNotice = notice(SensitiveOutcome.retryLaterKey)
            return
        }
        state.abandonConfirmKey = key
    }

    func cancelAbandon() {
        state.abandonConfirmKey = nil
    }

    /// 二次确认里点【确定放弃】：调作废接口。`key`、`owner` 是渲染这个确认框时取出的值。
    func abandon(key: String, owner: WalletOwner) {
        guard state.abandonConfirmKey == key else { return }
        state.abandonConfirmKey = nil
        guard let intent = intentFor(key: key, owner: owner) else { return }
        clearGuide()
        if gate.active {
            state.pendingNotice = notice(SensitiveOutcome.retryLaterKey)
            return
        }
        let version = state.pendingVersion
        sentViewGen = visibility.generation
        markInFlight(true)
        let target = target(intent)
        let api = deps.api
        // 离页不取消已发出的作废，共享结算由任务持有的固定依据直接完成（共性第 40、66 条）
        let ticket = writeTicket(intent.owner)
        let settlement = deps.settlement
        Task { @MainActor [weak self, deps, operationId, outcomeOp] in
            let result = await api.abandonPending(operationId: operationId, target: target)
            let outcome = Self.isLocal(result) ? nil : SensitiveOutcome.of(
                op: outcomeOp, phase: SensitiveOutcome.abandon, keyEverUnknown: true,
                input: WalletErrors.abandonInput(result)
            )
            // 作废接口的 .success 即 completed 且原结果成功（WalletErrors.abandonInput）：原操作带过的 token 已被核销，按 action 丢弃
            // （共性第 70 条，G17）；abandoned 不是 .success，不算业务成功
            settlement.settleWrite(ticket, result, outcome, consumesToken: true)
            self?.afterPendingCall(result, outcome, version: version, intent: intent, abandon: true)
            deps.pending.send(PendingSettled(account: intent.account, operationId: operationId))
        }
    }

    /// 按表单身份的未决记录重建待确认状态（进入页面、冷启动、登录成功、回前台、键结束之后）。记录读不出 → 不能确认未决状态，【提交】置灰。
    /// 本进程正在发送的首次提交（submitting）不被记录的 in_flight 打断。只把本表单身份的记录放进本表单（共性第 65 条）。
    func refreshPending() {
        guard alive() else { return }
        let owner = state.owner
        guard deps.env.isCurrent(owner), let account = owner.account else { return }
        refreshSerial += 1
        let serial = refreshSerial
        let api = deps.api
        Task { @MainActor [weak self, operationId] in
            let lookup = await api.pendingStatus(operationId: operationId)
            guard let self, alive(), serial == refreshSerial, state.owner == owner, deps.env.isCurrent(owner)
            else { return }
            applyLookup(lookup, account: account)
        }
    }

    /// 用户在页面上点了引导的手动入口【去实名认证】等：页面此刻可见、会话仍是记下引导时的才打开；用过即清。
    func openGuide(owner: WalletOwner) {
        guard let route = state.guideRoute, visibleNow, owner == state.owner else { return }
        state.guideRoute = nil
        if guideOwner == state.owner, deps.env.isCurrent(state.owner) {
            host?.onGuide(route)
        }
    }

    func consumeToast(_ id: Int) {
        if state.toast?.id == id {
            state.toast = nil
        }
    }

    /// 关闭 44001 弹窗（`id` 是渲染时的弹窗实例）。
    func dismissRisk(_ id: Int) {
        if state.riskDialog?.id == id {
            state.riskDialog = nil
        }
    }

    func clearFieldErrors() {
        guard !state.fieldErrors.isEmpty || state.fieldErrorKey != nil else { return }
        state.fieldErrors = []
        state.fieldErrorKey = nil
    }
}

extension SensitiveFlow {
    /// 点击处的那条记录（身份、原键都取自本页渲染的待确认卡）；不是当前会话的、不是这张卡的键都不受理。
    func intentFor(key: String, owner: WalletOwner) -> PendingIntent? {
        guard let pending = state.pending, pending.key == key, alive(), !pending.inFlight, owns(owner),
              let account = owner.account
        else { return nil }
        return PendingIntent(owner: owner, account: account, key: key)
    }

    /// 点击时的目标（共性第 14、15 条）：记录账号与原键、固定的网络归属；共享禁用期是发送前闸门（首次发送与管线续发前都核对）。
    func target(_ intent: PendingIntent) -> PendingTarget {
        PendingTarget(
            account: intent.account, key: intent.key, expected: intent.owner.request, sendAllowed: gate.sendAllowed
        )
    }

    func runConfirm(_ intent: PendingIntent, token: String?) {
        // 二次验证之后续发：页面、会话与账号仍是点击时的才发（共性第 14 条）
        guard alive(), deps.env.isCurrent(intent.owner) else { return }
        let version = state.pendingVersion
        sentViewGen = visibility.generation
        markInFlight(true)
        let target = target(intent)
        let api = deps.api
        let ticket = writeTicket(intent.owner)
        let settlement = deps.settlement
        Task { @MainActor [weak self, deps, operationId, outcomeOp] in
            let result = await api.confirmPending(operationId: operationId, stepUpToken: token, target: target)
            let outcome = Self.isLocal(result) ? nil : SensitiveOutcome.of(
                op: outcomeOp, phase: SensitiveOutcome.confirm, keyEverUnknown: true,
                input: WalletErrors.outcomeInput(result)
            )
            settlement.settleWrite(ticket, result, outcome, consumesToken: true)
            self?.afterPendingCall(result, outcome, version: version, intent: intent, abandon: false)
            deps.pending.send(PendingSettled(account: intent.account, operationId: operationId))
        }
    }

    /// 确认 / 放弃的结果：页面已出栈或会话已换不改页面；键已经结束（别的在途请求先回来）的只用于核对。
    func afterPendingCall(_ result: ApiResult, _ outcome: Outcome?, version: Int, intent: PendingIntent,
                          abandon: Bool) {
        guard alive(), deps.env.isCurrent(intent.owner), intent.owner == state.owner else { return }
        guard state.pendingVersion == version else {
            refreshPending()
            return
        }
        markInFlight(false)
        guard let outcome else {
            // 本地阻断（禁用期、会话已换、记录已换键）：原键保持待确认
            state.pendingNotice = notice(SensitiveOutcome.retryLaterKey)
            refreshPending()
            return
        }
        if abandon {
            apply(outcome, result: result, phase: SensitiveOutcome.abandon, replayed: true, intent: nil)
        } else {
            apply(outcome, result: result, phase: SensitiveOutcome.confirm, replayed: intent.stepUpReplayed,
                  intent: intent)
        }
    }

    func applyLookup(_ lookup: PendingLookup, account: String) {
        switch lookup {
        case .unreadable:
            state.pendingUnreadable = true
        case .none:
            reconcile(nil)
        case let .record(record):
            guard record.account == account else { return }
            reconcile(PendingView(
                key: record.key, summary: record.summary, createdAtMillis: record.createdAtMillis,
                inFlight: record.stateRaw == PendingKeyStore.inFlight
            ))
        }
        // 确认流程的二次验证所属的键已在别处结算或被替换：同步收起面板（共性第 49 条）
        if let intent = stepUpIntent, state.pending?.key != intent.key {
            stepUpIntent = nil
            stepUp.dismiss()
        }
    }

    /// 按记录重建：没有记录 → 退出待确认；本次首次提交还在发送 → 不打断；有记录 → 待确认（换了键版本加一，本进程在途的保持在途）。
    func reconcile(_ view: PendingView?) {
        var next = state
        next.pendingUnreadable = false
        guard let view else {
            if next.pending != nil {
                next.pending = nil
                next.pendingVersion += 1
                next.pendingNotice = nil
                next.abandonConfirmKey = nil
            }
            if next.phase == .pending {
                next.phase = .editing
            }
            state = next
            return
        }
        if next.phase == .submitting, view.key == reuseKey, view.inFlight {
            state = next
            return
        }
        let fresh = next.pending?.key != view.key
        var shown = view
        shown.inFlight = view.inFlight || (!fresh && localBusy)
        next.phase = .pending
        next.pending = shown
        if fresh {
            next.pendingVersion += 1
        }
        state = next
    }

    func markInFlight(_ busy: Bool) {
        localBusy = busy
        guard var pending = state.pending else { return }
        pending.inFlight = busy
        state.pending = pending
        if busy {
            state.pendingNotice = notice("error.40901").polite()
        }
    }

    func endPending() {
        state.pending = nil
        state.pendingVersion += 1
        state.pendingNotice = nil
        state.abandonConfirmKey = nil
    }

    func clearGuide() {
        if state.guideRoute != nil {
            state.guideRoute = nil
        }
    }

    /// 会话换代（App 在会话通知里同步调用）：清掉页面上的待确认与提示、收起二次验证面板，下次提交用新键；新表单的身份由发起页传入（共性第
    /// 65 条：发起页在清空表单的同一处一次性取得）；按新身份重读未决记录（旧账号的键不发、不展示，原账号再登录时恢复）。
    func sessionChanged(_ owner: WalletOwner) {
        reuseKey = nil
        lastBody = nil
        lastSummary = ""
        lastClick = nil
        stepUpIntent = nil
        guideOwner = nil
        stepUp.dismiss()
        localBusy = false
        refreshSerial += 1
        state = FlowState(pendingVersion: state.pendingVersion + 1, owner: owner)
        if owner.account != nil {
            refreshPending()
        }
    }

    func leave() {
        stepUp.dismiss()
        unsubscribe?()
        unsubscribe = nil
    }
}
