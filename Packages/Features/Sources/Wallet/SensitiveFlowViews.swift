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
    /// 写请求已结束、等身份确认时的【重试】（RW-03）。
    public let recheck: () -> Void

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
            openGuide: { [weak flow] in flow?.openGuide(owner: owner) },
            recheck: { [weak flow] in flow?.recheckIdentity() }
        )
    }
}

/// 待确认卡（WithdrawPendingConfirm / PayoutAccountPendingConfirm 一族，W56–W59）：白卡 → 警告提示块（标题 + 说明）→ 灰底明细（有才画）→
/// 两个等宽按钮（在途时都置灰）→ 忙碌状态行 / 警告提示块 → 注释与链接同行。
struct PendingCard: View {
    let texts: WalletTexts
    let pending: PendingView
    let desc: String
    let abandonTitle: String
    let confirmTitle: String
    let note: String
    let notice: Notice?
    let blocked: Bool
    /// 确认 / 放弃请求仍在途（转圈）；结果已到、待身份确认时为假（RV-04）。
    let busy: Bool
    /// 【确认上一笔】/【放弃】可用（不在途、没有待身份确认的结果）。
    let actionsEnabled: Bool
    let actions: FlowActions
    /// 【放弃】的读屏焦点绑定（「放弃上一笔」确认框关闭后焦点回到它，FU-IOS-A11Y-07）；nil 不挂。
    var abandonFocus: AccessibilityFocusState<Bool>.Binding?
    var extra: AnyView?
    /// 注释行右侧的链接（提现：【查看提现记录 ›】）。
    var link: Link?

    struct Link {
        let title: String
        let action: () -> Void
    }

    /// 在途时执行器把提示设成 `error.40901`，与状态行同一句：只画状态行、只播报一次。
    private static let busyKey = "error.40901"

    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            WalletWarningBlock(iconProbe: "pending.icon") {
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    RecordText(texts.text("pending_confirm.title"), style: .footnote, weight: .couliSemibold,
                               color: CouliColor.statusWarningText, probe: "pending.title")
                    RecordText(desc, style: .footnote, color: CouliColor.statusWarningText,
                               monospacedDigits: true, probe: "pending.desc")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .walletProbe("pending.alert", role: "alert")
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
                    .background(
                        RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                            .fill(CouliColor.backgroundMuted)
                    )
                    .walletProbe("pending.detail", role: "detail")
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
            if busy {
                busyRow
            }
            if let notice, !(busy && notice.key == Self.busyKey) {
                noticeBlock(notice)
            }
            noteRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .couliCard()
        .walletProbe("pending.card", role: "card")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pending.card")
    }

    /// 忙碌状态行（W58，role=status）：16 转圈 +「正在处理，请稍候」。
    private var busyRow: some View {
        let text = texts.text(Self.busyKey)
        return HStack(spacing: CouliSpacing.s2) {
            WalletSpinner(probe: "pending.busy.spinner")
            RecordText(text, style: .footnote, color: CouliColor.textSecondary, probe: "pending.busy.text")
        }
        .walletProbe("pending.busy", role: "status")
        .accessibilityElement(children: .combine)
        .task(id: notice?.id) {
            if let notice, notice.key == Self.busyKey {
                WalletAnnounce.post(notice.message(texts), assertive: notice.assertive)
            }
        }
    }

    /// 卡内警告提示块（W59 / G-W17：40901、retry_later、cannot_confirm）。
    private func noticeBlock(_ notice: Notice) -> some View {
        let text = notice.message(texts)
        return WalletWarningBlock(iconProbe: "pending.noticeBlock.icon") {
            RecordText(text, style: .footnote, color: CouliColor.statusWarningText, probe: "pending.noticeBlock.text")
                .accessibilityIdentifier("pending.notice")
        }
        .walletProbe("pending.noticeBlock", role: "notice")
        .task(id: notice.id) { WalletAnnounce.post(text, assertive: notice.assertive) }
    }

    /// 注释 12 与链接同一行（W57）；放不下时链接换到下一行。
    @ViewBuilder private var noteRow: some View {
        let noteText = RecordText(note, style: .caption, color: CouliColor.textSecondary, probe: "pending.note")
        if let link {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CouliSpacing.s3) {
                    noteText
                    Spacer(minLength: 0)
                    linkButton(link)
                }
                VStack(alignment: .leading, spacing: 0) {
                    noteText
                    linkButton(link)
                }
            }
        } else {
            noteText
        }
    }

    private func linkButton(_ link: Link) -> some View {
        WithdrawLinkButton(title: link.title, probe: "pending.records", inset: 0, chevron: true, action: link.action)
            .fixedSize()
            .accessibilityIdentifier("pending.records")
    }

    var abandonButton: some View {
        CouliButton(abandonTitle, kind: .secondary, isEnabled: actionsEnabled && !blocked, fillsWidth: true,
                    labelProbeID: "pending.abandon.label", horizontalPadding: CouliSpacing.s2,
                    weight: .couliMedium, mutedWhenDisabled: true, action: actions.askAbandon)
            .walletProbe("pending.abandon", role: "button")
            .modifier(WalletFocusBinding(focus: abandonFocus))
            .accessibilityIdentifier("pending.abandon")
    }

    var confirmButton: some View {
        CouliButton(
            confirmTitle,
            kind: .primary,
            isEnabled: actionsEnabled && !blocked,
            fillsWidth: true,
            labelProbeID: "pending.confirm.label",
            horizontalPadding: CouliSpacing.s2,
            action: actions.confirm
        )
        .walletProbe("pending.confirm", role: "button")
        .accessibilityIdentifier("pending.confirm")
    }
}

/// 放弃确认弹窗里的上一笔：提现是灰底明细（标签左、值右，W61），收款账号是一句附注。
enum AbandonDetail {
    struct Row {
        let label: String
        let value: String
        let spoken: String
    }

    case rows([Row])
    case note(String)
}

/// 灰底明细块 / 附注（测量 `abandon.detail`、`abandon.detail.<n>.label` / `.value`、`abandon.note`）。
private struct AbandonDetailView: View {
    let detail: AbandonDetail

    var body: some View {
        switch detail {
        case let .rows(rows):
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    CouliFlowLayout(horizontalSpacing: CouliSpacing.s3, verticalSpacing: 0) {
                        RecordText(row.label, style: .footnote, color: CouliColor.textSecondary,
                                   probe: "abandon.detail.\(index).label")
                        RecordText(row.value, style: .footnote, color: CouliColor.textPrimary, monospacedDigits: true,
                                   probe: "abandon.detail.\(index).value")
                            .couliFlowPushTrailing(.inlineOnly)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: row.label + PriceTerms.spokenPause + row.spoken))
                }
            }
            .padding(CouliSpacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .fill(CouliColor.backgroundMuted)
            )
            .walletProbe("abandon.detail", role: "detail")
        case let .note(text):
            RecordText(text, style: .footnote, color: CouliColor.textSecondary, probe: "abandon.note")
        }
    }
}

/// 弹窗构造（W60、W61，WithdrawAbandonConfirm、WithdrawBlocked / PayoutAccountBlocked）：标题居中。主次槽位见 G-W16。
@MainActor
enum FlowDialogs {
    private static let probe = "flow.dialog"

    static func abandon(_ texts: WalletTexts, title: String, detail: AbandonDetail,
                        actions: FlowActions) -> CouliDialog {
        CouliDialog(
            title: title,
            centeredTitle: true,
            probeID: probe,
            onEscape: actions.cancelAbandon,
            // 设计稿 WithdrawAbandonConfirm：主按钮是更稳妥的【再想想】，【确定放弃】为次按钮
            primary: CouliDialogAction(texts.text("pending_confirm.abandon.cancel"), action: actions.cancelAbandon),
            secondary: CouliDialogAction(texts.text("pending_confirm.abandon.ok"), action: actions.abandon)
        ) {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                RecordText(texts.text("pending_confirm.abandon.confirm"), style: .footnote,
                           color: CouliColor.textPrimary)
                    .accessibilityIdentifier("abandon.dialog")
                AbandonDetailView(detail: detail)
            }
        }
    }

    static func risk(_ texts: WalletTexts, titleKey: String, desc: String, ok: @escaping () -> Void,
                     appeal: @escaping () -> Void) -> CouliDialog {
        CouliDialog(
            title: texts.text(titleKey),
            centeredTitle: true,
            probeID: probe,
            onEscape: ok,
            primary: CouliDialogAction(texts.text("cs.appeal_entry"), action: appeal),
            secondary: CouliDialogAction(texts.text("withdraw.risk_blocked.ok"), action: ok)
        ) {
            RecordText(desc, style: .footnote, color: CouliColor.textPrimary)
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
