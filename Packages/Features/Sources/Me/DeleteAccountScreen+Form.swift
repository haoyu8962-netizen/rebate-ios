import CouliNetwork
import DesignSystem
import MeCore
import SwiftUI
import WalletCore

/// 注销页「说明与条件确认」的各块：负余额提示、资金区、注销须知、勾选框、【申请注销】与写请求的提示。
extension DeleteAccountBody {
    func negativeBanner(_ view: DeletionView, _ actions: DeleteAccountActions) -> some View {
        // 本次 30416：{amount} 取这一次响应的 amount_fen（缺失用不带金额的兜底句）；进页：取 negative_fen（共性第 10 条）
        let text = view.negativeFen.map { texts.format("error.30416", ["amount": CouliFormat.money(fen: $0)]) }
            ?? texts.text("error.30416")
        return VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                CouliIconView(.alert, size: 20, relativeTo: .footnote)
                bodyText(text)
            }
            .foregroundColor(CouliColor.statusWarningText)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("deletion.negative")
            HStack(spacing: CouliSpacing.s3) {
                CouliButton(texts.text("deletion.contact_cs"), kind: .secondary, size: .compact,
                            action: actions.contactService)
                    .accessibilityIdentifier("deletion.contactService")
                if view.negativeFromSubmit {
                    CouliButton(texts.text("wallet.retry"), kind: .text, size: .compact,
                                isEnabled: !fundsGate.blocked, action: actions.retry)
                        .accessibilityIdentifier("deletion.refresh")
                }
            }
        }
        .padding(CouliSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
            .fill(CouliColor.statusWarningBackground))
    }

    /// 资金区（G11：只显示可提现余额、预估收益，负余额时加待抵扣；金额只经 CouliFormat）。
    func funds(_ view: DeletionView, _ state: DeletionSnapshot, _ actions: DeleteAccountActions) -> some View {
        card {
            bodyText(texts.text("deletion.funds.title"), weight: .couliSemibold)
                .accessibilityAddTraits(.isHeader)
            if let funds = state.funds {
                amountRow(texts.text("deletion.withdrawable"), funds.withdrawableFen, id: "deletion.withdrawable")
                amountRow(texts.text("deletion.estimated"), funds.estimatedFen, id: "deletion.estimated")
                if funds.negativeFen > 0 {
                    amountRow(texts.text("deletion.negative_label"), funds.negativeFen, id: "deletion.negativeFen")
                    bodyText(texts.text("deletion.negative.desc"), secondary: true)
                } else {
                    bodyText(texts.text("deletion.funds.desc"), secondary: true)
                }
                if view.showGoWithdraw {
                    CouliButton(texts.text("deletion.funds.go_withdraw"), kind: .text, size: .compact,
                                action: actions.goWithdraw)
                        .accessibilityIdentifier("deletion.goWithdraw")
                }
            } else if state.fundsFailed {
                failure(texts.text("deletion.funds_failed"), state.fundsError, retryEnabled: !fundsGate.blocked,
                        actions: actions, id: "deletion.fundsFailed")
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    func amountRow(_ label: String, _ fen: Int64, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CouliSpacing.s2) {
            bodyText(label, secondary: true)
            Spacer(minLength: CouliSpacing.s2)
            Text(verbatim: CouliFormat.money(fen: fen))
                .couliFont(.body, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .accessibilityLabel(Text(verbatim: CouliFormat.moneySpoken(fen: fen)))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    /// 注销须知六条（静态草稿；G13：不显示「查看完整《注销须知》」）。
    var noticeList: some View {
        card {
            bodyText(texts.text("deletion.notice.title"), weight: .couliSemibold)
                .accessibilityAddTraits(.isHeader)
            ForEach(1...6, id: \.self) { index in
                HStack(alignment: .top, spacing: CouliSpacing.s2) {
                    Text(verbatim: "·")
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .accessibilityHidden(true)
                    // 「7 天」「15 个工作日」不写死在句子里（BR-TEXT-13，D10-2094 ③）：按变量渲染
                    bodyText(texts.format("deletion.notice.\(index)", AccountDraftTexts.noticeVars), secondary: true)
                }
            }
        }
    }

    /// 勾选框（读「放弃未提现余额和预估收益，复选框，未选中 / 已选中」）。
    func waiverRow(_ view: DeletionView, _ state: DeletionSnapshot, _ actions: DeleteAccountActions) -> some View {
        let on = state.waiver
        let enabled = view.waiverEnabled
        return Button(action: actions.toggleWaiver) {
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                // 组件库圆形勾选（与登录、收款同一件）；首行居中对齐靠上边距
                CouliCheckGlyph(checked: on)
                    .padding(.top, 1.5)
                bodyText(texts.text("deletion.waiver"))
            }
            .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel(Text(verbatim: texts.format(
            "deletion.waiver.spoken",
            ["label": texts.text("deletion.waiver"), "role": texts.text("deletion.waiver.role")]
        )))
        .accessibilityValue(Text(verbatim: texts.text(on ? "deletion.waiver.on" : "deletion.waiver.off")))
        .accessibilityIdentifier("deletion.waiver")
    }

    func applyButton(_ view: DeletionView, _: DeletionSnapshot, _ flowState: FlowState,
                     _ actions: DeleteAccountActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            CouliButton(
                texts.text("deletion.apply"), isLoading: flowState.phase == .submitting && !flowState.awaitingIdentity,
                isEnabled: controller.applyEnabled && !writeGate.blocked, fillsWidth: true, action: actions.apply
            )
            .accessibilityFocused(applyFocused)
            .accessibilityIdentifier("deletion.apply")
            let hintKey = view.kind == .pendingConfirm ? "deletion.pending.apply_blocked" : "deletion.agree_hint"
            bodyText(texts.text(hintKey), secondary: true)
        }
    }

    /// 写请求的错误条（30412 + 【去提现】、20903、5xxxx + trace6 等）、未绑手机提示、被拦下的引导入口。
    @ViewBuilder
    func messages(_ view: DeletionView, _ state: DeletionSnapshot, _ flowState: FlowState,
                  _ actions: DeleteAccountActions) -> some View {
        // 30416 的提示由负余额提示块显示（取本次 amount_fen），不重复显示不带金额的错误条
        if let error = flowState.error, error.key != "error.30416" {
            errorLine(flowMessage(error, state), id: error.id, identifier: "deletion.error")
            if state.withdrawHint, view.showGoWithdraw {
                CouliButton(texts.text("deletion.funds.go_withdraw"), kind: .text, size: .compact,
                            action: actions.goWithdraw)
                    .accessibilityIdentifier("deletion.error.goWithdraw")
            }
        }
        if let notice = state.notice {
            errorLine(notice.message(texts), id: notice.id, identifier: "deletion.notice")
            if notice.key == DeleteAccountController.noPhoneKey, controller.identity.scope == DeletionScope.full {
                CouliButton(texts.text("deletion.go_bind_phone"), kind: .text, size: .compact,
                            action: actions.goBindPhone)
                    .accessibilityIdentifier("deletion.goBindPhone")
            }
        }
        if flowState.guideRoute != nil {
            CouliButton(texts.text("wallet.retry"), kind: .text, size: .compact, action: actions.openGuide)
                .accessibilityIdentifier("deletion.openGuide")
        }
    }
}
