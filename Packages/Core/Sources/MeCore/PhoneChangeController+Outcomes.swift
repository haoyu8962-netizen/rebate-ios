import CouliNetwork
import Foundation
import WalletCore

/// 提交的结局（brief §1「结局」；三端任务书 §2.5，iOS 落点见盘点 §3 第 3 项）。共享结算（phoneGate 42901、成功的 recordBindSucceeded /
/// 清全部 token / 重取 getMe / 守卫重算、未决通知）已由 BindPhoneService 按固定身份做完，这里只改本页：
/// - 成功 → Done（实际发送的固定摘要，共性第 17 条；本机不退出、不清会话，D10-2192）；
/// - 10003 → 面板 → 原键原体重放 1 次（重放再遇 10003 只提示）；
/// - 20001（phone_invalid / fields=[phone]，含新号等于当前号，补 (d)）/ 20002 / 20003 → 字段提示、保留新号、token 不丢；
/// - 30411（不论 reason）→ error.30411.phone_change，不进并号（G08）；30414 → 同一句 + 【联系客服】（补 (b)）；
/// - 44001 → PhoneChangeNewBlocked，验证码清空；20903 → 回第 1 步、清表单与 token；10001 / 10004 / 10005 / 10007 → 引导、不自动重提；
/// - 42901 → 提示（禁用期在 phoneGate）；5xxxx / 非强更 10405 → trace6；强更 10405 只消费网络层 Effect（共性第 12 条）；
/// - 结果未知 → 按本机未决记录进待确认（不换键、不自动重发）。
/// 键的去向沿用首次绑定写法（D10-2165 ① 现状：从未结果未知的键遇非终结码由网络层删记录，下次点击新键），待 D10-2165 ① 统一。
extension PhoneChangeController {
    func applySubmit(_ arrival: PhoneBindArrival, _ submission: PhoneChangeSubmission, replayed: Bool, sameForm: Bool) {
        let result = arrival.result
        switch result {
        case .success:
            finishDone(masked: submission.maskedPhone)
            return
        case let .transportFailure(_, _, _, unknown):
            if unknown {
                // 待确认卡读出来之前【提交】保持置灰，不闪出可点的一拍（网络层另有 pendingKeyUnresolved 兜底）
                state.submitting = true
                refreshPending()
            } else if sameForm {
                state.notice = notice(MeCodes.networkKey)
            }
            return
        case let .localReject(reason):
            submitUnsent(reason, gated: arrival.gated, sameForm: sameForm)
            return
        case let .failure(raw, _, data, traceId, effect, _):
            // 表单已换代（用户已返回第 1 步）：只认会改变整页去向的结局
            guard sameForm || raw == 30414 || raw == 20903 else { return }
            submitFailure(
                NonForcedUpdate.pageCode(code: raw, effect: effect), data: data, traceId: traceId, effect: effect,
                submission: submission, replayed: replayed
            )
        default:
            return
        }
    }

    /// 没有发出：phoneGate 拦下 → 限流提示；同一操作已有未决键 → 按记录进待确认；未决存储读不出 → 网络错误；其余（换会话等）静默。
    private func submitUnsent(_ reason: String, gated: Bool, sameForm: Bool) {
        if gated {
            if sameForm {
                state.notice = notice(MeCodes.rateKey)
            }
        } else if reason == LocalRejectReason.pendingKeyUnresolved {
            refreshPending()
        } else if reason == LocalRejectReason.pendingStoreFailed, sameForm {
            state.notice = notice(MeCodes.networkKey)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_parameter_count
    private func submitFailure(_ code: Int, data: Data?, traceId: String?, effect: ErrorEffect,
                               submission: PhoneChangeSubmission, replayed: Bool) {
        let object = (WalletJSON.parse(data) as? [String: Any]) ?? [:]
        switch code {
        case _ where effect.kind == .forceUpdate:
            return
        case 10003:
            if replayed {
                // 面板刚给的 token 服务端也不认：作废，下次提交不再带它
                token = nil
                state.notice = notice(effect.textKey ?? "error.10003")
            } else {
                openPanel(.submit(submission))
            }
        case 20001:
            let fields = effect.fields ?? (object["fields"] as? [Any])?.compactMap { $0 as? String } ?? []
            if fields.contains("phone") || object["reason"] as? String == "phone_invalid" || fields.isEmpty {
                state.phoneError = notice("error.20001.phone_invalid")
            } else {
                state.codeError = notice("error.20001")
            }
        case 20002:
            state.codeError = notice("error.20002")
        case 20003:
            state.newCode = ""
            state.codeError = notice("error.20003")
        case 20903:
            resetToStep1()
            state.oldError = notice("error.20903")
        case 30411:
            state.phoneError = notice(Self.phoneTakenKey)
        case 30414:
            showUnavailable()
        case 44001:
            state.newCode = ""
            state.dialog = .risk(titleKey: Self.riskTitleKey(data), id: nextId())
        case 10001, 10004, 10005, 10007:
            guide(code, effect: effect)
        case 42901:
            state.notice = notice(MeCodes.rateKey)
        case 50000...59999:
            state.notice = serverNotice(code, traceId: traceId)
        default:
            state.notice = notice(Self.businessKey(code, effect: effect))
        }
    }

    /// 前置码：引导补办（经 Router，只在设置页仍在栈顶时），清验证码、保留新号，回来不自动提交（BR-ID-10「不适用的动作」）。
    func guide(_ code: Int, effect: ErrorEffect) {
        state.newCode = ""
        if let route = effect.route, code != 10007 || effect.kind == .navigate {
            deps.env.open(route, params: [:], from: page)
        } else {
            state.notice = notice(Self.businessKey(code, effect: effect))
        }
    }

    func serverNotice(_ code: Int, traceId: String?) -> MeNotice {
        MeNotice(MeCodes.serverErrorKey(code), id: nextId(), traceId: traceId, showTrace6: true)
    }

    static func businessKey(_ code: Int, effect: ErrorEffect) -> String {
        if let key = effect.textKey, !(MeDraftTexts.raw(key) ?? "").isEmpty {
            return key
        }
        return MeCodes.codeTextKey(code) ?? MeNotice.unfinishedKey
    }

    // MARK: - 共用去向

    /// 成功（提交、确认、放弃得到 completed 0、别处结算了同一个键）：Done 显示固定摘要；流程 token 作废、面板收起。
    func finishDone(masked: String?) {
        panel.detach()
        token = nil
        stepGen += 1
        state.newPhone = ""
        resetStep2()
        oldTicker?.cancel()
        state.oldCode = ""
        state.oldError = nil
        state.oldSending = false
        state.verifying = false
        state.pending = nil
        state.pendingBusy = false
        state.pendingNotice = nil
        state.dialog = nil
        state.doneMaskedPhone = masked
        state.step = .done
        state.version += 1
    }

    /// 回第 1 步、重新验证（20903、放弃得到 abandoned、别处放弃）：清空表单与流程 token，清 StepUpTokenCache 的 phone_change。
    func resetToStep1() {
        panel.detach()
        token = nil
        wallet.tokens.on10003(action: Self.action)
        stepGen += 1
        state.newPhone = ""
        resetStep2()
        state.oldCode = ""
        state.oldError = nil
        state.oldSending = false
        state.verifying = false
        state.pending = nil
        state.pendingBusy = false
        state.pendingNotice = nil
        state.dialog = nil
        state.step = .step1
        state.version += 1
        restoreOldCountdown()
    }

    /// 键已结束（3xxxx）回第 2 步，按保留策略显示（共性第 44、47 条）：保留新号、清验证码。
    func backToStep2(phoneError: MeNotice?, notice: MeNotice?) {
        state.pending = nil
        state.pendingBusy = false
        state.pendingNotice = nil
        state.step = .step2
        resetStep2()
        state.phoneError = phoneError
        state.notice = notice
        state.version += 1
    }
}
