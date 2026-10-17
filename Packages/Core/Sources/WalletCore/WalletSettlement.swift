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
    /// 身份暂时未知时到达、等身份确认后结算的结果（RW-02）。
    private let held = IdentityDeferral()
    private var serial = 0
    /// 保留着的结算落在哪个禁用期上（RV-02：结算没落地前，用这个禁用期的写入口先补结算，补不上不发）。
    private var holding: [String: RetryAfterGate] = [:]

    init(env: WalletEnv, tokens: StepUpTokenCache) {
        self.env = env
        self.tokens = tokens
    }

    /// 写请求的结果：只按点击时的身份（会话已换的不动新会话的共享状态）。
    /// - `consumesToken`：本次请求带过（或原操作带过）step-up token 的可能——原操作业务成功（提交 / 确认成功，或放弃得到 completed 且原结果
    ///   成功，G17）即按 action 丢弃 token；单纯 abandoned 不算业务成功。
    func settleWrite(_ ticket: WriteTicket, _ result: ApiResult, _ outcome: Outcome?, consumesToken: Bool) {
        settle(ticket.owner, slot: "write", gate: ticket.gate) { [weak self] elapsed in
            self?.applyWrite(ticket, result, outcome, consumesToken: consumesToken, elapsed: elapsed)
        }
    }

    private func applyWrite(
        _ ticket: WriteTicket, _ result: ApiResult, _ outcome: Outcome?, consumesToken: Bool, elapsed: Int64
    ) {
        if consumesToken, case .success = result {
            tokens.onSuccess(action: ticket.action)
        }
        guard let outcome else { return }
        if let millis = outcome.disableMillis {
            Self.start(ticket.gate, millis, elapsed: elapsed)
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
        let error = WalletErrors.of(result)
        guard error.kind == .retryAfter else { return }
        let millis = error.disableMillis > 0 ? error.disableMillis : SensitiveOutcome.defaultRetryMillis
        settle(owner, slot: "retryAfter", gate: gate) { elapsed in
            Self.start(gate, millis, elapsed: elapsed)
        }
    }

    // MARK: - 身份暂时未知（FU-IOS-0712 重理后补修 RW-02）

    /// 按点击时的身份核对后结算（三态）：仍是当前 → 立即结算；暂时未知 → 由本会话级服务保留固定归属、结果与到达时刻，身份确认后
    /// （App 的会话核对，判据相同也调 `resumeAfterIdentityConfirmed`）只结算一次，禁用期按原截止（扣掉等待的时长）；已确定换代 → 丢弃。
    /// 不依赖页面是否还在。
    private func settle(
        _ owner: WalletOwner, slot: String, gate: RetryAfterGate,
        _ apply: @escaping @MainActor (_ elapsed: Int64) -> Void
    ) {
        let arrived = env.nowMillis()
        attempt(Held(owner: owner, slot: slot, gate: gate, arrived: arrived), apply)
    }

    /// 一份等身份确认的结算：点击时的身份、所在禁用期与到达时刻。
    private struct Held {
        let owner: WalletOwner
        let slot: String
        let gate: RetryAfterGate
        let arrived: Int64
    }

    private func attempt(_ item: Held, _ apply: @escaping @MainActor (Int64) -> Void) {
        serial += 1
        let key = "\(item.slot)#\(serial)"
        let check = env.check(item.owner)
        let admitted = held.admit(check, slot: key, resume: { [weak self] in
            self?.holding[key] = nil
            self?.attempt(item, apply)
        })
        if check == .unknown {
            holding[key] = item.gate
        }
        guard admitted else { return }
        apply(max(0, env.nowMillis() - item.arrived))
    }

    /// 这个禁用期上还留着没落地的结算（RV-02）。
    public func holds(_ gate: RetryAfterGate) -> Bool {
        holding.values.contains { $0 === gate }
    }

    /// 禁用期按原截止：到达时起算的时长扣掉等待身份确认的时长；已过期的不再启动。
    private static func start(_ gate: RetryAfterGate, _ millis: Int64, elapsed: Int64) {
        let remaining = millis - elapsed
        if remaining > 0 {
            gate.start(remaining)
        }
    }

    /// 身份确认之后：结算身份暂时未知时到达的结果（各自再核对一次；仍未知的继续保留）。
    public func resumeAfterIdentityConfirmed() {
        held.resume()
    }

    /// 会话换代（含未知期间世代已变）：保留的结果属于旧会话，丢弃。
    public func sessionChanged() {
        held.reset()
        holding = [:]
    }

    /// 有保留着等身份确认的结算（测试核对）。
    public var hasHeld: Bool {
        held.isPending
    }
}
