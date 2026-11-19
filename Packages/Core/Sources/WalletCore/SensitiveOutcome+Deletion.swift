import Foundation

/// 申请注销（APP-13a-1，op = account_deletion）在共用结局表上的专用分支。提现、改收款不经过这里。
extension SensitiveOutcome {
    /// 申请注销（APP-13a-1，requestDeletion；step-up action 同名）。
    public static let accountDeletion = "account_deletion"
    /// 申请注销得到 10007（账号已在冷静期 / 处理中，APP-13a-1 G27）：停在本页、提示 error.10007、页面重取 getDeletion；键不结束、
    /// 下次点击沿用原键（从未结果未知的键：网络层照常删除记录，页面保留原键）。
    public static let deletionLocked = "deletion_locked"

    /// 申请注销首次提交的专用结局（APP-13a §0 第 1 条、§2.3；与提现 / 收款账号不同的几类）：
    /// - 10007：停在本页、重取 getDeletion（cooling 显示冷静期、processing 只提示），键不结束（G27）；
    /// - 10010（待加验，1xxxx）：提示 error.10010，键不结束、下次沿用原键原体（三端任务书 §0 第 1 条；加验页不在本任务，TODO(N-37)）；
    /// - 10405（非终结）：键不结束、下次沿用原键（共性第 22 条）；页面只消费网络层 Effect（结局 force_update 不按码另做强更）；
    /// - 5xxxx：统一错误 + trace6，键不结束、下次沿用原键（任务书 13a-1「结果未知 / 5xxxx 不换键」）；
    /// - 表外 1xxxx（共用映射之外）：提示 error.<code>，键不结束。
    /// 其余（30412、30416、表外 3xxxx、20903、42901、40901、20001、44001）沿用共用表；表外 3xxxx 的文案键见 `businessText`（G26）。
    static func deletionSubmit(_ code: Int) -> Outcome? {
        switch code {
        case 10007:
            return Outcome(deletionLocked, ends: false, newKey: false, text: "error.10007")
        case 10010:
            return Outcome(showErrorKeyEnds, ends: false, newKey: false, text: errorKey(code))
        case forceUpdateCode:
            return Outcome(forceUpdate, ends: false, newKey: false, text: "error.10405")
        default:
            if code / 10000 == 5 {
                var outcome = Outcome(errorTrace6, ends: false, newKey: false, text: serverKey(code))
                outcome.showTrace6 = true
                return outcome
            }
            if code / 10000 == 1 {
                return Outcome(showErrorKeyEnds, ends: false, newKey: false, text: errorKey(code))
            }
            return nil
        }
    }

    /// 确认上一次注销得到 10007 / 10010：只说明账号状态，说明不了这个键有没有结果，保持待确认（APP-13a §2.3「确认」）。
    static func deletionConfirm(_ code: Int) -> Outcome? {
        guard code == 10007 || code == 10010 else { return nil }
        return Outcome(showErrorKeepPending, ends: false, newKey: false, text: errorKey(code))
    }

    /// 键结束的业务错误（3xxxx）的文案键。申请注销按 G26：一律 error.<code>，字典没有这个键时页面回落到服务端 msg（注销页按原始结果取 msg）；
    /// 提现、改收款照旧走 `businessKey`（未收录回落 error.50001，30303 按 reason），行为不变。
    static func businessText(_ op: String, _ code: Int, _ input: OutcomeInput) -> String {
        op == accountDeletion ? "error.\(code)" : businessKey(code, input)
    }
}
