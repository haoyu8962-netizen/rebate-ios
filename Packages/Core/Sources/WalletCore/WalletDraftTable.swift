import Foundation

// TODO(N-32) 待定稿，不得提审：钱包页、提现页、待确认与二次验证的草稿文案（原文出处见 WalletDraftTexts 的说明）。
extension WalletDraftTexts {
    /// 钱包页（设计稿 Wallet*；BR-TEXT-01）与问号说明（BR-TEXT-14 表 C wallet.help.*）。
    static let walletPage: [String: String] = [
        "wallet.title": "钱包",
        "wallet.back": "返回",
        "wallet.withdrawable": "可提现余额",
        "wallet.records": "提现记录",
        "wallet.withdraw": "提现",
        "wallet.frozen": "冻结中",
        "wallet.withdrawn": "已提现",
        "wallet.estimated": "预估收益",
        "wallet.received": "其中已收货 {amount}",
        "wallet.earliest_label": "最早预计",
        "wallet.earliest": "{month}结算",
        "wallet.overdue": "入账核对中",
        // G-W07（APP-09v，WalletStates ④ 设计稿措辞，BR-TEXT-14 待补键）：入账核对中时预估区右列的标签
        "wallet.settle_progress": "结算进度",
        "wallet.paused": "其中 {amount} 暂缓入账",
        // G-W06（APP-09v）：待抵扣挪成主卡下警告条，首行只写金额，次行取契约键 error.30302
        "wallet.negative": "待抵扣 {amount}",
        "wallet.estimate_note": "按联盟最新预估计算，以联盟结算金额为准",
        "wallet.draft.risk_paused": "提现已暂停",
        "wallet.draft.risk_paused_reason": "提现已暂停：{reason}",
        "wallet.risk_hint": "浏览、购物照常。点这里查看说明或申诉",
        "wallet.entry.orders": "订单",
        "wallet.entry.ledger": "余额流水",
        "wallet.entry.earnings": "收益看板",
        // 代拟：整页加载失败与网络错误（设计稿没有画钱包的错误态）
        "wallet.load_failed": "加载失败",
        "wallet.retry": "重试",
        // 代拟（APP-09 共性第 51 条）：被拦下的前置引导的手动入口
        "wallet.guide.bind_phone": "去绑定手机号",
        "wallet.guide.login": "去登录",
        "wallet.loading": "加载中",
        "wallet.network_error": "网络不可用，请检查网络后重试",
        // 代拟：保留旧摘要但不是网络原因的读取失败（5xxxx、42901、坏数据）标更新时间（03 §4.2，APP-09 共性第 38 条）
        "wallet.updated_at": "更新于 {time}",
        // 代拟（iOS I05）：钱包冒烟入口（「我的」占位页）
        "wallet.entry.me": "钱包",
        // 代拟（Android A18 同口径）：发起页上的实名查询失败条
        "wallet.close": "关闭",
        "wallet.help.estimated": "还没结算的返利和推广收益的估计值，按联盟最新预估计算，以联盟结算金额为准，结算后计入可提现余额",
        "wallet.help.pending_paused": "部分订单暂时不能结算，处理完成后继续按联盟结算入账，如有疑问请联系客服",
        "wallet.help.frozen": "已申请提现、正在审核或打款的金额，这部分暂时不能再次提现",
        "wallet.help.fee_tax": "提现时扣除的手续费与代扣的个人所得税，每次的金额以提现页显示为准",
        "wallet.help.estimated_label": "预估收益说明",
        "wallet.help.pending_paused_label": "暂缓入账说明",
        "wallet.help.frozen_label": "冻结中说明",
        "wallet.help.fee_tax_label": "预计到账说明",
        "wallet.help.estimated_title": "预估收益",
        "wallet.help.pending_paused_title": "暂缓入账",
        "wallet.help.frozen_title": "冻结中",
        "wallet.help.fee_tax_title": "预计到账",
        "wallet.help.ok": "知道了",
        "wallet.help.close": "关闭",
        // 金额隐藏（BR-TEXT-10 细则「金额隐藏」；与 APP-08 OrderDraftTexts 同名同文）
        "amount_mask.mask": "****",
        "amount_mask.hidden_spoken": "金额已隐藏",
        // 脱敏号里的「*」读作「星号」（adaptation-a11y-spec §9）
        "wallet.star_spoken": "星号",
    ]

    /// 提现页（设计稿 Withdraw*）、待确认（契约 pending_confirm.* 以外的几句）与二次验证面板（设计稿 WithdrawStepUp；G16）。
    static let withdrawPage: [String: String] = [
        "withdraw.title": "提现申请",
        "withdraw.amount_label": "提现金额",
        "withdraw.realname_placeholder": "完成实名后可输入",
        "withdraw.payout_label": "收款账号",
        "withdraw.irrevocable": "提交后不能自行撤销，如需撤销请联系客服",
        "withdraw.submit": "提交",
        "withdraw.submitting": "提交中…",
        // BR-TEXT-07 原文（Config texts.withdraw.sla_text 没下发时用）
        "withdraw.sla_default": "人工审核，工作日 24 小时内处理，节假日顺延",
        "withdraw.sla_text_auto": "预计几分钟内到账",
        "withdraw.sla_text": "{text}",
        "withdraw.guide.realname": "去实名认证",
        // 代拟（G28）：设计稿只画了未实名的引导态
        "withdraw.guide.payout": "去绑定收款账号",
        "withdraw.guide.labor": "去签署劳务协议",
        "withdraw.guide.help": "提现规则",
        // G-W15（APP-09v-c）：30309 引导框里的规则入口，画板措辞，去向同页底「提现规则」
        "withdraw.guide.rules": "查看提现规则",
        // BR-TEXT-14 表 C（措辞取自设计稿 WithdrawBlocked）
        "withdraw.risk_blocked.desc": "这笔提现没有提交，金额没有冻结，可提现余额不变，已填的金额保留在本页。如有疑问，可以联系客服申诉，客服核实后会帮你登记。",
        "withdraw.risk_blocked.ok": "知道了",
        "cs.appeal_entry": "联系客服申诉",
        // TODO(N-32) 设计稿 A11yAnnounce 标「待商量」
        "withdraw.submitted_spoken": "提现申请已提交，审核中",
        "withdraw.spoken.quick": "提现金额 {amount}，预计到账 {net}",
        "withdraw.spoken.amount": "提现金额 {amount}",
        "withdraw.load_failed": "加载失败",
        "pending_confirm.withdraw.records": "查看提现记录",
        "pending_confirm.withdraw.note": "结果确认前不能发起新的提现",
        "pending_confirm.withdraw.amount_label": "上一笔金额",
        "pending_confirm.payout_label": "收款账号",
        "pending_confirm.payout_account.account_label": "提交的收款账号",
        "pending_confirm.payout_account.payee_label": "收款人",
        "pending_confirm.payout_account.time_label": "提交时间",
        "pending_confirm.payout_account.note": "结果确认前不能再次更换收款账号",
        "pending_confirm.payout_account.abandon_note": "如果上一次提交已经处理完，收款账号会显示为提交的新账号；放弃不会把它改回原账号",
        "step_up.title": "为保障资金安全，请先完成短信验证",
        // 代拟（G16）：响应不返回脱敏号码
        "step_up.sent": "验证码已发送至你绑定的手机号",
        "step_up.code_label": "验证码",
        "step_up.resend_in": "{sec} 秒后重新获取",
        "step_up.resend": "重新获取",
        "step_up.submit": "验证并提交",
        "step_up.close": "关闭",
        "step_up.code_spoken": "验证码，已输入 {n} 位，共 6 位",
        // 代拟（iOS I01，同 Android A01）：本机取不到当前账号的手机号时不发码
        "step_up.no_phone": "暂时无法发送验证码，请稍后再试",
        "step_up.sending": "正在发送验证码…",
    ]
}
