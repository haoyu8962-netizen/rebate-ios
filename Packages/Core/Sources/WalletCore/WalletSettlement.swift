import CouliNetwork
import Foundation

/// 一次写请求（提交 / 确认 / 放弃）的固定结算依据：点击时的身份、step-up action、共享禁用期，以及成功后是否通知钱包刷新。任务在发出时
/// 一次性取得并持有它，结果回来直接按它结算（APP-09 共性第 66 条）。
@MainActor
struct WriteTicket {
    let owner: WalletOwner
    let action: String
    let gate: RetryAfterGate
    /// 提现：原操作成功时通知（按会话归属）仍存在的钱包页刷新（共性第 53、58、61 条）；收款账号不需要。
    let marksWalletDirty: Bool
}

/// 写请求与发码的共享结算（APP-09 共性第 27、40、53、58、61、66、70 条；iOS R1-04、R1-05、R1-06）：会话级服务，随 `WalletDeps`（App 建一份、
/// 各页共用）存在。刷新通知、共享限流与 step-up token 清理都在这里按任务持有的固定身份完成，不依赖页面执行器、面板是否还在——页面出栈、
/// 面板关闭并释放之后迟到的成功或 42901 照常结算；页面自己的界面更新另经弱引用，不在这里。
@MainActor
public final class WalletSettlement {
    private unowned let env: WalletEnv
    private let tokens: StepUpTokenCache

    init(env: WalletEnv, tokens: StepUpTokenCache) {
        self.env = env
        self.tokens = tokens
    }

    /// 写请求的结果：只按点击时的身份（会话已换的不动新会话的共享状态）。
    /// - `consumesToken`：本次请求带过（或原操作带过）step-up token 的可能——原操作业务成功（提交 / 确认成功，或放弃得到 completed 且原结果
    ///   成功，G17）即按 action 丢弃 token；单纯 abandoned 不算业务成功。
    func settleWrite(_ ticket: WriteTicket, _ result: ApiResult, _ outcome: Outcome?, consumesToken: Bool) {
        guard env.isCurrent(ticket.owner) else { return }
        if consumesToken, case .success = result {
            tokens.onSuccess(action: ticket.action)
        }
        guard let outcome else { return }
        if let millis = outcome.disableMillis {
            ticket.gate.start(millis)
        }
        switch outcome.actionRaw {
        case SensitiveOutcome.stepUp:
            tokens.on10003(action: ticket.action)
        case SensitiveOutcome.done:
            succeeded(ticket)
        case SensitiveOutcome.alreadyDone where outcome.textKey == SensitiveOutcome.alreadyDoneKey:
            succeeded(ticket)
        default:
            break
        }
    }

    private func succeeded(_ ticket: WriteTicket) {
        if ticket.marksWalletDirty {
            env.markWalletDirty(ticket.owner)
        }
    }

    /// 读 / 发码 / 验证请求的 42901：按发起时的身份写入对应的共享禁用期（面板、页面是否还在都写；共性第 27、40 条）。
    func settleRetryAfter(_ result: ApiResult, gate: RetryAfterGate, owner: WalletOwner) {
        guard env.isCurrent(owner) else { return }
        let error = WalletErrors.of(result)
        if error.kind == .retryAfter {
            gate.start(error.disableMillis > 0 ? error.disableMillis : SensitiveOutcome.defaultRetryMillis)
        }
    }
}
