import CouliNetwork
import DesignSystem
import MeCore
import SwiftUI
import WalletCore

/// 注销页的待确认卡与冷静期。
extension DeleteAccountBody {
    // MARK: - 待确认

    /// 待确认警告卡（DeleteAccountPendingConfirm / Busy；alert 角色）：独立于进度 / 资金读取渲染（共性第 46 条）。
    func pendingCard(_ flowState: FlowState, _ actions: DeleteAccountActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            bodyText(texts.text("pending_confirm.title"), weight: .couliSemibold)
            bodyText(texts.text("pending_confirm.deletion.desc"))
            if let pending = flowState.pending {
                summaryRow(texts.text("deletion.pending.action_label"), texts.text("deletion.pending.action"))
                summaryRow(texts.text("deletion.pending.checked_label"), texts.text("deletion.waiver"))
                summaryRow(
                    texts.text("deletion.pending.submitted_at_label"),
                    CouliFormat.timeListPast(
                        epochMillis: pending.createdAtMillis, nowEpochMillis: controller.displayNowMillis()
                    )
                )
            } else if flowState.pendingUnreadable {
                bodyText(texts.text(SensitiveOutcome.retryLaterKey), secondary: true)
            }
            HStack(spacing: CouliSpacing.s3) {
                CouliButton(texts.text("pending_confirm.abandon"), kind: .secondary,
                            isEnabled: flowState.pendingActionsEnabled && !writeGate.blocked,
                            action: actions.askAbandon)
                    .accessibilityIdentifier("deletion.pending.abandon")
                CouliButton(texts.text("pending_confirm.deletion.action"), isLoading: flowState.pendingCardBusy,
                            isEnabled: flowState.pendingActionsEnabled && !writeGate.blocked,
                            action: actions.confirm)
                    .accessibilityIdentifier("deletion.pending.confirm")
            }
            if let notice = flowState.pendingNotice {
                errorLine(flowMessage(notice, controller.state), id: notice.id, identifier: "deletion.pending.notice",
                          assertive: notice.assertive)
            }
            bodyText(texts.text("deletion.pending.no_repeat"), secondary: true)
        }
        .padding(CouliSpacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
            .fill(CouliColor.statusWarningBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deletion.pending")
        .task(id: flowState.pendingVersion) {
            // alert 角色：进入待确认时播报一次标题与说明
            MeAnnounce.post(texts.format("deletion.pending.spoken", [
                "title": texts.text("pending_confirm.title"), "desc": texts.text("pending_confirm.deletion.desc"),
            ]), assertive: true)
        }
    }

    func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: CouliSpacing.s2) {
            bodyText(label, secondary: true)
            Spacer(minLength: CouliSpacing.s2)
            bodyText(value)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 冷静期

    @ViewBuilder
    func cooling(_ view: DeletionView, _ state: DeletionSnapshot, _ actions: DeleteAccountActions) -> some View {
        if let deletion = view.deletion {
            let now = controller.displayNowMillis()
            let deadline = CouliFormat.timeListFuture(epochMillis: deletion.coolingUntilMillis, nowEpochMillis: now)
            let applied = CouliFormat.timeListPast(epochMillis: deletion.applyAtMillis, nowEpochMillis: now)
            // 冷静期天数取服务端两个时刻的差（只用于显示，不据此判断能否撤回，G15）
            let days = max(1, (deletion.coolingUntilMillis - deletion.applyAtMillis + 43_200_000) / 86_400_000)
            card {
                bodyText(texts.text("deletion.cooling.badge"), secondary: true)
                bodyText(texts.text("deletion.cooling.title"), weight: .couliSemibold)
                    .accessibilityAddTraits(.isHeader)
                // can_cancel=false：不显示撤回与撤回截止句，时间线停在「注销处理」一步（G15，D10-2094 ②，不新造句）
                if view.showCancel {
                    bodyText(texts.format("deletion.cooling.deadline", ["cancel_deadline": deadline]))
                    bodyText(texts.text("deletion.cooling.withdraw_note"), secondary: true)
                }
            }
            .accessibilityIdentifier("deletion.cooling")
            card {
                timelineRow(texts.text("deletion.timeline.submitted"), applied, current: false)
                timelineRow(
                    texts.format("deletion.timeline.cooling", ["cooling_days": "\(days)"]),
                    texts.format("deletion.timeline.cooling_desc", ["cancel_deadline": deadline]),
                    current: view.showCancel
                )
                timelineRow(
                    texts.text("deletion.timeline.processing"),
                    texts.format("deletion.timeline.processing_desc",
                                 ["process_workdays": "\(AccountDraftTexts.processWorkdays)"]),
                    current: !view.showCancel
                )
            }
            bodyText(texts.text("deletion.cooling.readonly_note"), secondary: true)
            if view.showCancel {
                CouliButton(texts.text("deletion.cooling.withdraw"), kind: .secondary, isLoading: state.cancelling,
                            isEnabled: !state.cancelling && !cancelGate.blocked, fillsWidth: true,
                            action: actions.cancelDeletion)
                    .accessibilityIdentifier("deletion.cancel")
            }
            if let notice = state.notice {
                errorLine(notice.message(texts), id: notice.id, identifier: "deletion.notice")
            }
        }
    }

    /// 时间线一步：`current` 是当前所在的一步（冷静期中可撤回时停在「冷静期」，can_cancel=false 时停在「注销处理」）。
    func timelineRow(_ title: String, _ detail: String, current: Bool) -> some View {
        HStack(alignment: .top, spacing: CouliSpacing.s3) {
            Circle()
                .fill(current ? CouliColor.brandPrimary : CouliColor.borderSubtle)
                .frame(width: 8, height: 8)
                .padding(.top, CouliSpacing.s2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                bodyText(title, weight: current ? .couliSemibold : .regular)
                bodyText(detail, secondary: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
