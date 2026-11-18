import CouliNetwork
import Foundation

/// 申请注销复用提现 / 收款账号同一套敏感写操作管线（APP-13a-1，任务书 §1「幂等键」「二次验证」）：每次点【申请注销】生成新键、首次发送前由
/// 网络层 PendingKeyStore 写未决记录、10003 弹二次验证面板（action=account_deletion）后沿用原键重放 1 次、结果未知进待确认、确认与放弃只由
/// 用户点击。这里只给「我的」Core（MeCore）开放构造与几个入口，结局表在 `SensitiveOutcome`（op = account_deletion）。
public extension SensitiveFlow {
    /// openapi requestDeletion（POST /v1/me/deletion，空请求体，x-step-up account_deletion，x-idempotent）。
    static let deletionOperation = "requestDeletion"
    /// step-up action（step_up_action 枚举）：令牌只按这个 action 缓存与复用，不给别的操作用。
    static let deletionAction = "account_deletion"
    /// 未决记录的展示摘要（G24：不含手机号与请求体；待确认卡按固定两句 + 提交时间显示）。
    static let deletionSummary = "deletion"

    /// 申请注销的流程（注销页执行器在构造时一次性给出固定身份；申请、确认、放弃共用 `WalletGates.deletion`）。
    static func accountDeletion(deps: WalletDeps, owner: WalletOwner, alive: @escaping () -> Bool) -> SensitiveFlow {
        SensitiveFlow(
            deps: deps, operationId: deletionOperation, action: deletionAction,
            outcomeOp: SensitiveOutcome.accountDeletion, gate: deps.gates.deletion, marksWalletDirty: false,
            alive: alive, owner: owner
        )
    }

    /// 接上发起页（成功、补办、结局去向）。
    func attach(_ host: FlowHost) {
        self.host = host
    }

    /// 【申请注销】：请求体为空（勾选只在客户端，G14），按固定身份发；`owner` 是渲染时取出的表单身份。
    func submitDeletion(owner: WalletOwner) {
        submit(body: "", summary: Self.deletionSummary, owner: owner)
    }

    /// 按本机未决记录重建待确认（进入页面、回前台、登录成功、作用域换代后）。
    func syncPending() {
        refreshPending()
    }

    /// 打开引导的手动入口（自动引导被拦下时）。
    func openGuideManually(owner: WalletOwner) {
        openGuide(owner: owner)
    }

    /// 页面离开或整页按新身份重建：收起面板、作废待补做、退订结算通知。写请求不取消（未决记录兜底）。
    func detach() {
        leave()
    }

    /// 消费一次性轻提示。
    func consumeFlowToast(_ id: Int) {
        consumeToast(id)
    }
}
