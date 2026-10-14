import DesignSystem
import SwiftUI
import WalletCore

/// 待确认、放弃确认、44001 弹窗的回调（渲染时一次取出：原键、身份、弹窗实例都是不可变的普通值，共性第 4、14、63 条）。
@MainActor
public struct FlowActions {
    public let confirm: () -> Void
    public let askAbandon: () -> Void
    public let abandon: () -> Void
    public let cancelAbandon: () -> Void
    public let dismissRisk: () -> Void
    public let openGuide: () -> Void

    public static func make(_ flow: SensitiveFlow, _ state: FlowState) -> FlowActions {
        let key = state.pending?.key ?? ""
        let owner = state.owner
        let confirmKey = state.abandonConfirmKey ?? ""
        let risk = state.riskDialog?.id ?? -1
        return FlowActions(
            confirm: { [weak flow] in flow?.confirm(key: key, owner: owner) },
            askAbandon: { [weak flow] in flow?.askAbandon(key: key, owner: owner) },
            abandon: { [weak flow] in flow?.abandon(key: confirmKey, owner: owner) },
            cancelAbandon: { [weak flow] in flow?.cancelAbandon() },
            dismissRisk: { [weak flow] in flow?.dismissRisk(risk) },
            openGuide: { [weak flow] in flow?.openGuide(owner: owner) }
        )
    }
}

/// 待确认卡（WithdrawPendingConfirm / PayoutAccountPendingConfirm 一族）：alert 角色、标题 + 说明 + 两个按钮（在途时都置灰）+ 卡内提示。
struct PendingCard: View {
    let texts: WalletTexts
    let pending: PendingView
    let desc: String
    let abandonTitle: String
    let confirmTitle: String
    let note: String
    let notice: Notice?
    let blocked: Bool
    let actions: FlowActions
    var extra: AnyView?
    /// 说明行右侧的链接（提现：【查看提现记录 ›】）。
    var link: Link?

    struct Link {
        let title: String
        let action: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            // 设计稿 WithdrawPendingConfirm：白卡里先是浅黄警示块（三角 + 标题 + 说明），再是明细浅底块、两个等宽按钮、说明
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                CouliIconView(.alert, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    Text(verbatim: texts.text("pending_confirm.title"))
                        .couliFont(.footnote, weight: .couliSemibold)
                    Text(verbatim: desc)
                        .couliFont(.footnote)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundColor(CouliColor.statusWarningText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(CouliSpacing.s3)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.card).fill(CouliColor.statusWarningText.opacity(0.1))
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("pending.text")
            .task(id: pending.key) {
                // 警告卡：出现时 assertive 播报一次（alert 角色）
                WalletAnnounce.post(
                    texts.text("pending_confirm.title") + PriceTerms.spokenPause + desc,
                    assertive: true
                )
            }
            if let extra {
                extra
                    .padding(CouliSpacing.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: CouliRadius.card).fill(CouliColor.backgroundMuted))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CouliSpacing.s3) {
                    abandonButton
                    confirmButton
                }
                VStack(spacing: CouliSpacing.s2) {
                    abandonButton
                    confirmButton
                }
            }
            if let notice {
                Text(verbatim: notice.message(texts))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pending.notice")
                    .task(id: notice.id) { WalletAnnounce.post(notice.message(texts), assertive: notice.assertive) }
            }
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s3, verticalSpacing: CouliSpacing.s1) {
                Text(verbatim: note)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let link {
                    CouliButton(link.title, kind: .text, size: .compact, action: link.action)
                        .fixedSize()
                        .accessibilityIdentifier("pending.records")
                        .couliFlowPushTrailing(.inlineOnly)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .couliCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pending.card")
    }

    var abandonButton: some View {
        CouliButton(abandonTitle, kind: .secondary, isEnabled: !pending.inFlight && !blocked, fillsWidth: true,
                    action: actions.askAbandon)
            .accessibilityIdentifier("pending.abandon")
    }

    var confirmButton: some View {
        CouliButton(confirmTitle, kind: .primary, isLoading: pending.inFlight, isEnabled: !blocked, fillsWidth: true,
                    action: actions.confirm)
            .accessibilityIdentifier("pending.confirm")
    }
}

/// 弹窗构造（WithdrawAbandonConfirm、WithdrawBlocked / PayoutAccountBlocked）。
@MainActor
enum FlowDialogs {
    static func abandon(_ texts: WalletTexts, detail: String, actions: FlowActions) -> CouliDialog {
        CouliDialog(
            title: texts.text("pending_confirm.abandon"),
            // 设计稿 WithdrawAbandonConfirm：主按钮是更稳妥的【再想想】，【确定放弃】为次按钮
            primary: CouliDialogAction(texts.text("pending_confirm.abandon.cancel"), action: actions.cancelAbandon),
            secondary: CouliDialogAction(texts.text("pending_confirm.abandon.ok"), action: actions.abandon)
        ) {
            Text(verbatim: texts.text("pending_confirm.abandon.confirm") + "\n" + detail)
                .couliFont(.body)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("abandon.dialog")
        }
    }

    static func risk(_ texts: WalletTexts, titleKey: String, desc: String, ok: @escaping () -> Void,
                     appeal: @escaping () -> Void) -> CouliDialog {
        CouliDialog(
            title: texts.text(titleKey),
            primary: CouliDialogAction(texts.text("cs.appeal_entry"), action: appeal),
            secondary: CouliDialogAction(texts.text("withdraw.risk_blocked.ok"), action: ok)
        ) {
            Text(verbatim: desc)
                .couliFont(.body)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("risk.dialog")
        }
    }
}

/// 被拦下的前置引导的手动入口（共性第 51 条；按钮文案复用 withdraw.guide.* 与代拟 wallet.guide.*）。
struct GuideEntry: View {
    let texts: WalletTexts
    let route: String
    let action: () -> Void

    var body: some View {
        CouliButton(texts.text(Self.titleKey(route)), kind: .secondary, size: .compact, action: action)
            .accessibilityIdentifier("flow.guide")
    }

    static func titleKey(_ route: String) -> String {
        switch route {
        case WalletRoutes.realName: "withdraw.guide.realname"
        case WalletRoutes.payoutAccount: "withdraw.guide.payout"
        case WalletRoutes.laborAgreement: "withdraw.guide.labor"
        case WalletRoutes.bindPhone: "wallet.guide.bind_phone"
        default: "wallet.guide.login"
        }
    }
}
