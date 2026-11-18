import CouliNetwork
import DesignSystem
import MeCore
import SwiftUI
import WalletCore

/// 注销页的按钮回调（渲染时一次取出：执行器、版本、固定身份、待确认键都是不可变的普通值，APP-09 共性第 4、63 条；会话换代后旧回调执行时
/// 只比较、不受理）。
@MainActor
public struct DeleteAccountActions {
    public let toggleWaiver: () -> Void
    public let apply: () -> Void
    public let retry: () -> Void
    public let cancelDeletion: () -> Void
    public let goWithdraw: () -> Void
    public let goBindPhone: () -> Void
    public let contactService: () -> Void
    public let confirm: () -> Void
    public let askAbandon: () -> Void
    public let abandon: () -> Void
    public let cancelAbandon: () -> Void
    public let openGuide: () -> Void

    public static func make(_ controller: DeleteAccountController, _ state: DeletionSnapshot, _ flow: FlowState)
        -> DeleteAccountActions {
        let version = state.version
        let owner = controller.identity.owner
        let pendingKey = flow.pending?.key ?? ""
        let abandonKey = flow.abandonConfirmKey ?? ""
        return DeleteAccountActions(
            toggleWaiver: { [weak controller] in controller?.toggleWaiver(version: version, owner: owner) },
            apply: { [weak controller] in controller?.apply(version: version, owner: owner) },
            retry: { [weak controller] in controller?.retry(version: version, owner: owner) },
            cancelDeletion: { [weak controller] in controller?.cancelDeletion(version: version, owner: owner) },
            goWithdraw: { [weak controller] in controller?.goWithdraw(version: version, owner: owner) },
            goBindPhone: { [weak controller] in controller?.goBindPhone(version: version, owner: owner) },
            contactService: { [weak controller] in controller?.contactService(version: version, owner: owner) },
            confirm: { [weak controller] in controller?.confirmPending(key: pendingKey, owner: owner) },
            askAbandon: { [weak controller] in controller?.askAbandon(key: pendingKey, owner: owner) },
            abandon: { [weak controller] in controller?.abandon(key: abandonKey, owner: owner) },
            cancelAbandon: { [weak controller] in controller?.cancelAbandon() },
            openGuide: { [weak controller] in controller?.openGuide(owner: owner) }
        )
    }
}

/// 注销页（DeleteAccount 路由；设计稿 DeleteAccount、DeleteAccountNegative、DeleteAccountCooling、DeleteAccountPending*）。身份或作用域变了
/// App 换上新执行器，整页按新身份重建（旧勾选、确认框、二次验证面板随旧执行器消失）。二次验证面板由 App 套上（Feature 之间不依赖，
/// 面板在 Wallet 模块）。系统导航栏（行内标题、系统返回）。
public struct DeleteAccountScreen: View {
    @ObservedObject var host: MePageHost<DeleteAccountController>
    let texts: AccountDraftTexts

    public init(host: MePageHost<DeleteAccountController>, texts: AccountDraftTexts = AccountDraftTexts()) {
        self.host = host
        self.texts = texts
    }

    public var body: some View {
        let controller = host.controller
        DeleteAccountBody(
            controller: controller, flow: controller.flow, writeGate: controller.writeGate,
            cancelGate: controller.cancelGate, readGate: controller.readGate, fundsGate: controller.fundsGate,
            texts: texts
        )
        .id(host.serial)
        .onAppear { host.onAppear() }
    }
}

struct DeleteAccountBody: View {
    @ObservedObject var controller: DeleteAccountController
    @ObservedObject var flow: SensitiveFlow
    @ObservedObject var writeGate: RetryAfterGate
    @ObservedObject var cancelGate: RetryAfterGate
    @ObservedObject var readGate: RetryAfterGate
    @ObservedObject var fundsGate: RetryAfterGate
    let texts: AccountDraftTexts
    @State private var toast: CouliToastMessage?
    @AccessibilityFocusState private var applyFocused: Bool

    var body: some View {
        let state = controller.state
        let flowState = flow.state
        let view = controller.view
        let actions = DeleteAccountActions.make(controller, state, flowState)
        ScrollView {
            VStack(alignment: .leading, spacing: CouliSpacing.s4) {
                content(view, state, flowState, actions)
            }
            .padding(CouliSpacing.s4)
            .frame(maxWidth: MeLayout.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .navigationTitle(texts.text("deletion.title"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("deletion.page")
        .couliDialog(isPresented: flowState.abandonConfirmKey != nil, restoreFocusTo: $applyFocused) {
            CouliDialog(
                title: texts.text("pending_confirm.abandon"),
                onEscape: actions.cancelAbandon,
                primary: CouliDialogAction(texts.text("pending_confirm.abandon.ok"), action: actions.abandon),
                secondary: CouliDialogAction(texts.text("pending_confirm.abandon.cancel"), action: actions.cancelAbandon)
            ) {
                VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                    bodyText(texts.text("pending_confirm.abandon.confirm"))
                    bodyText(texts.text("deletion.pending.abandon_note"), secondary: true)
                }
            }
        }
        .couliToast($toast)
        .onChange(of: state.toast) { value in
            guard let value else { return }
            toast = CouliToastMessage(value.message(texts), icon: .success)
            controller.consumeToast(value.id)
        }
        .onChange(of: flowState.toast) { value in
            guard let value else { return }
            toast = CouliToastMessage(value.message(texts), icon: .info)
            flow.consumeFlowToast(value.id)
        }
        .task { controller.start() }
    }

    // MARK: - 各状态

    @ViewBuilder
    func content(_ view: DeletionView, _ state: DeletionSnapshot, _ flowState: FlowState,
                 _ actions: DeleteAccountActions) -> some View {
        switch view.kind {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
                .accessibilityIdentifier("deletion.loading")
        case .loadFailed:
            failure(texts.text("deletion.load_failed"), state.readError, retryEnabled: !readGate.blocked,
                    actions: actions, id: "deletion.loadFailed")
        case .processing:
            card {
                bodyText(texts.text("error.10007"), weight: .couliSemibold)
                    .accessibilityIdentifier("deletion.processing")
            }
        case .cooling:
            cooling(view, state, actions)
        case .pendingConfirm:
            pendingCard(flowState, actions)
            form(view, state, flowState, actions)
        default:
            form(view, state, flowState, actions)
        }
    }

    /// 说明与条件确认（initial / negative / funds_unavailable / no_phone_step_up / 待确认下方保留的部分）。
    @ViewBuilder
    func form(_ view: DeletionView, _ state: DeletionSnapshot, _ flowState: FlowState,
              _ actions: DeleteAccountActions) -> some View {
        if view.kind == .negative {
            negativeBanner(view, actions)
        } else {
            bodyText(texts.text("deletion.top_notice"), secondary: true)
        }
        funds(view, state, actions)
        noticeList
        if view.kind != .negative {
            waiverRow(view, state, actions)
        }
        applyButton(view, state, flowState, actions)
        messages(view, state, flowState, actions)
    }

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
    @ViewBuilder
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
                    bodyText(texts.text("deletion.notice.\(index)"), secondary: true)
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
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundColor(on ? CouliColor.brandPrimary : CouliColor.borderControl)
                    .accessibilityHidden(true)
                bodyText(texts.text("deletion.waiver"))
            }
            .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel(Text(verbatim: "\(texts.text("deletion.waiver"))，\(texts.text("deletion.waiver.role"))"))
        .accessibilityValue(Text(verbatim: texts.text(on ? "deletion.waiver.on" : "deletion.waiver.off")))
        .accessibilityIdentifier("deletion.waiver")
    }

    func applyButton(_ view: DeletionView, _ state: DeletionSnapshot, _ flowState: FlowState,
                     _ actions: DeleteAccountActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            CouliButton(
                texts.text("deletion.apply"), isLoading: flowState.phase == .submitting && !flowState.awaitingIdentity,
                isEnabled: controller.applyEnabled && !writeGate.blocked, fillsWidth: true, action: actions.apply
            )
            .accessibilityFocused($applyFocused)
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
            errorLine(error.message(texts), id: error.id, identifier: "deletion.error")
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

    // MARK: - 待确认

    /// 待确认警告卡（DeleteAccountPendingConfirm / Busy；alert 角色）：独立于进度 / 资金读取渲染（共性第 46 条）。
    @ViewBuilder
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
                errorLine(notice.message(texts), id: notice.id, identifier: "deletion.pending.notice",
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
            MeAnnounce.post(texts.text("pending_confirm.title") + "，" + texts.text("pending_confirm.deletion.desc"),
                            assertive: true)
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
                if view.showCancel {
                    bodyText(texts.format("deletion.cooling.deadline", ["cancel_deadline": deadline]))
                    bodyText(texts.text("deletion.cooling.withdraw_note"), secondary: true)
                } else {
                    bodyText(texts.text("deletion.cooling.cannot_cancel"), secondary: true)
                }
            }
            .accessibilityIdentifier("deletion.cooling")
            card {
                timelineRow(texts.text("deletion.timeline.submitted"), applied)
                timelineRow(
                    texts.format("deletion.timeline.cooling", ["cooling_days": "\(days)"]),
                    texts.format("deletion.timeline.cooling_desc", ["cancel_deadline": deadline])
                )
                timelineRow(
                    texts.text("deletion.timeline.processing"),
                    texts.format("deletion.timeline.processing_desc",
                                 ["process_workdays": "\(AccountDraftTexts.processWorkdays)"])
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

    func timelineRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            bodyText(title, weight: .couliSemibold)
            bodyText(detail, secondary: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 共用件

    func failure(_ title: String, _ error: Notice?, retryEnabled: Bool, actions: DeleteAccountActions,
                 id: String) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            bodyText(title)
            if let error {
                errorLine(error.message(texts), id: error.id, identifier: id + ".error")
            }
            CouliButton(texts.text("wallet.retry"), kind: .secondary, size: .compact, isEnabled: retryEnabled,
                        action: actions.retry)
                .accessibilityIdentifier(id + ".retry")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(id)
    }

    func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            content()
        }
        .padding(CouliSpacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
            .fill(CouliColor.backgroundSurface))
    }

    func bodyText(_ text: String, secondary: Bool = false, weight: Font.Weight = .regular) -> some View {
        Text(verbatim: text)
            .couliFont(secondary ? .footnote : .body, weight: weight)
            .foregroundColor(secondary ? CouliColor.textSecondary : CouliColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 页内提示：出现时播报一次（错误 assertive，其余 polite）。
    func errorLine(_ text: String, id: Int, identifier: String, assertive: Bool = true) -> some View {
        Text(verbatim: text)
            .couliFont(.footnote)
            .foregroundColor(CouliColor.statusErrorText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
            .task(id: id) { MeAnnounce.post(text, assertive: assertive) }
    }
}
