import CouliNetwork
import Foundation

/// 结局落到页面（禁用期、token 失效、钱包刷新通知已由 `WalletSettlement` 按任务持有的固定依据结算）。
extension SensitiveFlow {
    func apply(_ outcome: Outcome, result: ApiResult, phase: String, replayed: Bool, intent: PendingIntent?) {
        if outcome.nextSubmitNewKey {
            reuseKey = nil
        }
        let message = outcomeMessage(outcome, result)
        switch outcome.actionRaw {
        case SensitiveOutcome.done, SensitiveOutcome.alreadyDone, SensitiveOutcome.abandoned:
            applyFinished(outcome, result: result, message: message)
        case SensitiveOutcome.stepUp:
            applyStepUp(phase: phase, replayed: replayed, intent: intent, message: message)
        case SensitiveOutcome.fieldError:
            serial += 1
            state.phase = .editing
            state.fieldErrors = outcome.fields
            state.fieldErrorKey = outcome.textKey
            state.fieldErrorId = serial
            state.error = nil
            refreshPending()
        case SensitiveOutcome.riskBlocked:
            applyRisk(outcome)
        case SensitiveOutcome.guide:
            applyGuide(outcome, phase: phase, message: message)
        case SensitiveOutcome.forceUpdate:
            if phase == SensitiveOutcome.submit {
                state.phase = .editing
            }
            refreshPending()
        default:
            applyRest(outcome, result: result, phase: phase, message: message)
        }
    }

    /// 结局文案（5xxxx 带 trace6：统一错误消息独立追加）。
    func outcomeMessage(_ outcome: Outcome, _ result: ApiResult) -> Notice? {
        guard let key = outcome.textKey else { return nil }
        var traceId: String?
        if case let .failure(_, _, _, trace, _, _) = result {
            traceId = trace
        }
        serial += 1
        return Notice(key, id: serial, traceId: traceId, showTrace6: outcome.showTrace6)
    }

    /// 键结束且成功或已作废：done（成功）、already_done（作废时已经处理完）、abandoned（已作废）。
    func applyFinished(_ outcome: Outcome, result: ApiResult, message: Notice?) {
        switch outcome.actionRaw {
        case SensitiveOutcome.done:
            reuseKey = nil
            state.phase = .editing
            state.error = nil
            state.pendingNotice = nil
            endPending()
            host?.onSucceeded(successData(result), alreadyDone: false)
        case SensitiveOutcome.alreadyDone:
            applyAlreadyDone(outcome, result: result, message: message)
        default:
            reuseKey = nil
            endPending()
            state.phase = .editing
            state.toast = message?.polite()
            state.error = nil
            host?.onSettled()
        }
    }

    func applyStepUp(phase: String, replayed: Bool, intent: PendingIntent?, message: Notice?) {
        if replayed {
            stepUpExhausted(phase, message)
        } else if !onScreen {
            // 页面被覆盖：不打开面板，保留原键（首次提交下次点击沿用；确认阶段保持待确认；共性第 37 条）
            stepUpDeferred(phase, message)
        } else {
            openStepUp(phase: phase, intent: intent)
        }
    }

    /// 键结束的错误条（业务错误、42901、5xxxx、40901、自动重发没成）与待确认（结果未知、cannot_confirm、abandon_busy、retry_later）。
    func applyRest(_ outcome: Outcome, result: ApiResult, phase: String, message: Notice?) {
        let ending: Set<String> = [
            SensitiveOutcome.showErrorKeyEnds, SensitiveOutcome.retryAfter, SensitiveOutcome.errorTrace6,
            SensitiveOutcome.busyRetry, SensitiveOutcome.autoResend,
        ]
        guard ending.contains(outcome.actionRaw) else {
            // pending_confirm / show_error_keep_pending / abandon_busy：进入或保持待确认（键不结束、不自动重发）
            state.phase = .pending
            state.pendingNotice = outcome.textKey == SensitiveOutcome.titleKey ? nil : message
            refreshPending()
            return
        }
        if phase != SensitiveOutcome.submit {
            endPending()
        }
        state.phase = .editing
        state.error = message ?? notice(WalletErrors.networkKey)
        if case let .failure(code, _, _, _, _, _) = result {
            host?.onBusinessError(code)
        }
        if outcome.keyEnds {
            host?.onSettled()
        }
        refreshPending()
    }

    func applyAlreadyDone(_ outcome: Outcome, result: ApiResult, message: Notice?) {
        reuseKey = nil
        endPending()
        state.phase = .editing
        if outcome.textKey == SensitiveOutcome.alreadyDoneKey {
            state.toast = message?.polite()
            host?.onSucceeded(successData(result), alreadyDone: true)
        } else {
            state.error = message
            state.toast = notice(SensitiveOutcome.alreadyDoneKey).polite()
            // 原结果是业务错误（如 30306）：与直接得到该错误同一出口（共性第 10、75 条，iOS R2-01）——先记下服务端阻断，再刷新数据
            if case let .failure(code, _, _, _, _, _) = result {
                host?.onBusinessError(code)
            }
            host?.onSettled()
        }
    }

    func applyRisk(_ outcome: Outcome) {
        let riskKey = outcome.riskMsgCode.map { "risk_msg.\($0)" }
        let title = riskKey.flatMap { deps.texts.has($0) ? $0 : nil } ?? "error.44001"
        state.phase = .editing
        // 页面被覆盖时不弹窗，只把结论留在页内错误条（共性第 37 条）
        if onScreen {
            serial += 1
            state.riskDialog = RiskDialog(titleKey: title, id: serial)
        } else {
            state.error = notice(title)
        }
        refreshPending()
    }

    func applyGuide(_ outcome: Outcome, phase: String, message: Notice?) {
        if phase == SensitiveOutcome.submit {
            state.phase = .editing
            state.error = message
        } else {
            state.pendingNotice = message
        }
        refreshPending()
        guard let route = outcome.route else { return }
        // 引导导航只在页面仍可见、可见世代未变时执行（共性第 37 条）；被拦下时保留目标、给手动入口（共性第 51 条）
        if onScreen {
            host?.onGuide(route)
        } else {
            guideOwner = state.owner
            state.guideRoute = route
        }
    }

    func successData(_ result: ApiResult) -> Any? {
        guard case let .success(data, _, _) = result else { return nil }
        return WalletJSON.parse(data)
    }

    /// 10003 的原键重放已用过一次又收到 10003（共性第 16 条）：不再弹面板、不再续发，提示 error.10003。首次提交的键结束不用；确认阶段保持待确认。
    func stepUpExhausted(_ phase: String, _ message: Notice?) {
        let text = message ?? notice("error.10003")
        if phase == SensitiveOutcome.submit {
            reuseKey = nil
            state.phase = .editing
            state.error = text
        } else {
            state.pendingNotice = text
        }
        refreshPending()
    }

    /// 页面被覆盖时收到 10003：只结算状态并保留原键，不弹面板（用户回到页面再点）。
    func stepUpDeferred(_ phase: String, _ message: Notice?) {
        let text = message ?? notice("error.10003")
        if phase == SensitiveOutcome.submit {
            state.phase = .editing
            state.error = text
        } else {
            state.pendingNotice = text
        }
        refreshPending()
    }

    /// 二次验证面板沿用打开它的提交 / 确认身份（共性第 60 条）：确认取点击时的记录身份，首次提交取点击时固定的身份。
    func openStepUp(phase: String, intent: PendingIntent?) {
        let panelOwner = intent?.owner ?? (phase == SensitiveOutcome.submit ? lastClick : nil)
        guard let panelOwner else {
            if phase == SensitiveOutcome.submit {
                reuseKey = nil
                state.phase = .editing
            }
            return
        }
        if phase == SensitiveOutcome.submit {
            state.phase = .submitting
        }
        stepUpIntent = intent
        stepUp.open(action: action, owner: panelOwner, onToken: { [weak self] token in
            self?.tokenArrived(token, phase: phase, intent: intent)
        }, onClosed: { [weak self] in
            guard let self else { return }
            stepUpIntent = nil
            // 用户关闭面板：首次提交回到编辑态，本次键结束不用（从未结果未知，下次用新键）；待确认保持待确认
            if phase == SensitiveOutcome.submit {
                reuseKey = nil
                state.phase = .editing
            }
            refreshPending()
        })
    }

    func tokenArrived(_ token: String, phase: String, intent: PendingIntent?) {
        guard alive() else { return }
        if phase == SensitiveOutcome.submit {
            guard let key = reuseKey, let body = lastBody, let click = lastClick else {
                state.phase = .editing
                return
            }
            // 共享结算还留着本操作的结果（RV-02）：补不上就不重放，原键保留、提示稍后再试
            guard sharedSettled() else {
                state.phase = .editing
                state.error = notice(SensitiveOutcome.retryLaterKey)
                return
            }
            // 原键重放沿用点击时的身份（共性第 39 条）：发送前核对，换了会话的不发
            send(
                click: click,
                payload: Submission(key: key, body: body, summary: lastSummary),
                token: token,
                replayed: true
            )
            return
        }
        guard let intent else { return }
        stepUpIntent = nil
        // 恢复前核对：本机未决记录仍是同一个键、未结束（共性第 49 条）
        guard state.pending?.key == intent.key else {
            refreshPending()
            return
        }
        // 共享结算还留着本操作的结果（RV-02，补修三）：先请 App 核对补结算；补不上不续发，原键保留在待确认卡上，提示稍后再试
        guard sharedSettled() else {
            markInFlight(false)
            state.pendingNotice = notice(SensitiveOutcome.retryLaterKey)
            return
        }
        intent.stepUpReplayed = true
        runConfirm(intent, token: token)
    }
}
