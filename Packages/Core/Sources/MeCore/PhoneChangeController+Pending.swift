import CouliNetwork
import Foundation
import WalletCore

/// 待确认（brief §1「待确认」；共性第 7、24、44、47 条）：来源始终是本机未决记录（首次绑定与换号留下的 bindPhone 记录都算）；确认原键原体，
/// 得到 10003 → 面板、沿用原键（与首次绑定 G53 不同）；20003 等 2xxxx → cannot_confirm 不标红；3xxxx → 回第 2 步；放弃先二次确认，
/// abandoned → 第 1 步重新验证，completed → 按原结果；40901 → abandon_busy；在途时两个按钮都置灰。别的页面结算了同一个键，按共享通知
/// 携带的结局落地。
extension PhoneChangeController {
    /// 按本机未决记录重读（进入、写请求结果未知、别处留下未决）。
    func refreshPending() {
        guard alive else { return }
        pendingSerial += 1
        let mine = pendingSerial
        let (bind, owner) = (bind, owner)
        Task { @MainActor [weak self] in
            let lookup = await bind.pendingStatus(owner)
            guard let self, alive, mine == pendingSerial else { return }
            switch lookup {
            case let .record(record) where record.stateRaw == PendingKeyStore.unknown:
                showPending(record)
            case .none:
                // 记录已结束（别处结算后）：卡片撤下，回第 1 步重新验证
                if state.step == .pending {
                    resetToStep1()
                }
            case .record, .unreadable:
                break
            }
        }
    }

    private func showPending(_ record: PendingKeyRecord) {
        guard state.pending?.key != record.key || state.step != .pending else { return }
        let summary = (WalletJSON.parse(record.summary.data(using: .utf8)) as? [String: Any]) ?? [:]
        let phone = (summary["phone"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        panel.detach()
        resetStep2()
        state.dialog = nil
        state.pending = PhoneChangePendingCard(
            key: record.key, maskedPhone: phone, submittedAtMillis: record.createdAtMillis
        )
        state.pendingBusy = false
        state.pendingNotice = nil
        state.step = .pending
        state.version += 1
        // 待确认卡出现：alert（assertive，T14）
        state.announce = notice("pending_confirm.title")
    }

    // MARK: - 确认

    /// 【确认上一次提交】（渲染时的卡片原键）。
    public func confirmPending(version: Int) {
        guard accepts(version), state.step == .pending, let card = state.pending, !state.pendingBusy, !panel.showing
        else { return }
        guard !bind.writeGated(owner) else {
            state.pendingNotice = notice(PhoneChangeTexts.retryLater)
            return
        }
        state.pendingBusy = true
        state.pendingNotice = nil
        confirm(key: card.key, token: currentToken(), replayed: false)
    }

    func confirm(key: String, token: String?, replayed: Bool) {
        bind.confirmChange(owner, key: key, stepUpToken: token) { [weak self] arrival in
            self?.confirmArrived(arrival, key: key, replayed: replayed)
        }
    }

    private func confirmArrived(_ arrival: PhoneBindArrival, key: String, replayed: Bool) {
        if arrival.notified {
            ownSettling = true
        }
        guard alive, state.step == .pending, let card = state.pending, card.key == key else { return }
        state.pendingBusy = false
        switch arrival.result {
        case .success:
            finishDone(masked: card.maskedPhone)
        case .abandoned:
            resetToStep1()
        case let .failure(raw, _, data, traceId, effect, _):
            guard effect.kind != .forceUpdate else { return }
            let code = NonForcedUpdate.pageCode(code: raw, effect: effect)
            if code == 10003 {
                if replayed {
                    state.pendingNotice = notice(PhoneChangeTexts.retryLater)
                } else {
                    openPanel(.confirm(key: key))
                }
                return
            }
            settledFailure(code, data: data, traceId: traceId, effect: effect)
        case .localReject:
            state.pendingNotice = arrival.gated ? notice(PhoneChangeTexts.retryLater) : nil
        default:
            state.pendingNotice = notice(PhoneChangeTexts.retryLater)
        }
    }

    /// 确认 / 放弃得到的业务码（放弃时是 completed 的原结果或作废接口自己的码）。
    private func settledFailure(_ code: Int, data _: Data?, traceId: String?, effect: ErrorEffect,
                                abandoning: Bool = false) {
        switch code {
        case 40901 where abandoning:
            state.pendingNotice = notice(PhoneChangeTexts.abandonBusy)
        case 30411:
            backToStep2(phoneError: notice(Self.phoneTakenKey), notice: nil)
        case 30414:
            backToStep2(phoneError: nil, notice: nil)
            showUnavailable()
        case 20903:
            resetToStep1()
            state.oldError = notice("error.20903")
        case 10001, 10004, 10005, 10007:
            guide(code, effect: effect)
            state.pendingNotice = notice(PhoneChangeTexts.retryLater)
        case 30000...39999:
            backToStep2(phoneError: nil, notice: notice(Self.businessKey(code, effect: effect)))
        case 50000...59999:
            state.pendingNotice = MeNotice(
                PhoneChangeTexts.retryLater, id: nextId(), traceId: traceId, showTrace6: traceId != nil
            )
        case 20000...29999 where !abandoning:
            state.pendingNotice = notice(PhoneChangeTexts.cannotConfirm)
        default:
            // 40901、42901（禁用期在 phoneGate）、44001、10405 等：保持待确认，稍后再试
            state.pendingNotice = notice(PhoneChangeTexts.retryLater)
        }
    }

    // MARK: - 放弃

    /// 【放弃上一次提交】：先弹二次确认（绑定原键）。
    public func askAbandon(version: Int) {
        guard accepts(version), state.step == .pending, let card = state.pending, !state.pendingBusy, !panel.showing
        else { return }
        guard !bind.writeGated(owner) else {
            state.pendingNotice = notice(PhoneChangeTexts.retryLater)
            return
        }
        state.dialog = .abandon(key: card.key, id: nextId())
    }

    /// 二次确认【确定放弃】：只认正显示的这一个确认框，用过即作废。
    public func confirmAbandon(_ dialog: PhoneChangeDialog, version: Int) {
        guard accepts(version), state.dialog == dialog, case let .abandon(key, _) = dialog,
              state.pending?.key == key, !state.pendingBusy
        else { return }
        state.dialog = nil
        state.pendingBusy = true
        state.pendingNotice = nil
        bind.abandonChange(owner, key: key) { [weak self] arrival in
            self?.abandonArrived(arrival, key: key)
        }
    }

    private func abandonArrived(_ arrival: PhoneBindArrival, key: String) {
        if arrival.notified {
            ownSettling = true
        }
        guard alive, state.step == .pending, let card = state.pending, card.key == key else { return }
        state.pendingBusy = false
        switch arrival.result {
        case .abandoned:
            resetToStep1()
        case .success:
            // completed 且原结果成功（G17）：按成功（共享结算已做）
            finishDone(masked: card.maskedPhone)
        case let .failure(raw, _, data, traceId, effect, _):
            // 强更 10405：只消费网络层 Effect，记录保留、不当作已放弃（共性第 12 条）
            guard effect.kind != .forceUpdate else { return }
            settledFailure(
                NonForcedUpdate.pageCode(code: raw, effect: effect), data: data, traceId: traceId, effect: effect,
                abandoning: true
            )
        case .localReject:
            state.pendingNotice = arrival.gated ? notice(PhoneChangeTexts.retryLater) : nil
        default:
            state.pendingNotice = notice(PhoneChangeTexts.retryLater)
        }
    }

    // MARK: - 别处结算（共性第 18、24、47 条）

    /// 共享未决通知：本页自己的写请求随后那条跳过；别处结算了待确认的那个键 → 按结局落地；别处留下未决 → 按记录进待确认。
    func settledElsewhere(_ event: PhoneBindSettled) {
        if ownSettling {
            ownSettling = false
            return
        }
        guard alive, event.account == owner.account else { return }
        if state.step == .pending {
            pendingSettledElsewhere(event.kind)
        } else if event.kind == .pending, !state.submitting {
            refreshPending()
        }
    }

    /// 正在待确认时别处结算了（同一操作同一账号只有一条未决记录，即这张卡的键）。
    private func pendingSettledElsewhere(_ kind: PhoneBindSettledKind) {
        switch kind {
        case .done:
            finishDone(masked: state.pending?.maskedPhone)
        case .abandoned:
            resetToStep1()
        case .ended:
            backToStep2(phoneError: nil, notice: notice(PhoneChangeTexts.endedElsewhere))
        case .pending, .other:
            break
        }
    }
}

/// 待确认相关的文案键（契约已有的直接取；`endedElsewhere` 是 AccountDraftTexts 草稿，TODO(N-37)）。
enum PhoneChangeTexts {
    static let retryLater = "pending_confirm.retry_later"
    static let cannotConfirm = "pending_confirm.cannot_confirm"
    static let abandonBusy = "pending_confirm.abandon_busy"
    static let endedElsewhere = "phone_change.pending.ended"
}
