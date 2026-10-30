import CouliNetwork
import DesignSystem
import SwiftUI
import UIKit
import WalletCore

/// 提现页的按钮与输入回调（渲染时一次取出：版本、身份、档位金额都是不可变的普通值，共性第 4、59、63、64 条）。
@MainActor
public struct WithdrawActions {
    public let amount: (String) -> Void
    public let fillAll: () -> Void
    public let quick: (Int64) -> Void
    public let submit: () -> Void
    public let guide: () -> Void
    public let payout: () -> Void
    public let records: () -> Void
    public let rules: () -> Void
    public let retry: () -> Void
    public let appeal: () -> Void

    public static func make(_ controller: WithdrawController, _ snapshot: WithdrawSnapshot, risk: Int?)
        -> WithdrawActions {
        let version = snapshot.version
        let owner = controller.owner
        let dialog = risk ?? -1
        return WithdrawActions(
            amount: { [weak controller] text in controller?.onAmountChange(text, owner: owner) },
            fillAll: { [weak controller] in controller?.fillAll(version: version, owner: owner) },
            quick: { [weak controller] fen in controller?.fillQuick(version: version, fen: fen, owner: owner) },
            submit: { [weak controller] in controller?.submit(version: version, owner: owner) },
            guide: { [weak controller] in controller?.openGuide(version: version, owner: owner) },
            payout: { [weak controller] in controller?.openPayout(owner: owner) },
            records: { [weak controller] in controller?.openRecords(owner: owner) },
            rules: { [weak controller] in controller?.openRules(owner: owner) },
            retry: { [weak controller] in controller?.retry() },
            appeal: { [weak controller] in controller?.appeal(dialog: dialog) }
        )
    }
}

/// 提现申请（Withdraw 路由；设计稿
/// Withdraw、WithdrawRealName、WithdrawCalculating、WithdrawNoteNet、WithdrawStepUp、WithdrawSubmitting、
/// WithdrawBlocked、WithdrawPending*、WithdrawAbandon*、AdaptKeyboardWithdraw、AdaptLargeTextWithdraw、AdaptNarrowWithdraw）。
public struct WithdrawScreen: View {
    @ObservedObject var controller: WithdrawController
    @ObservedObject var flow: SensitiveFlow
    @ObservedObject var stepUp: StepUpController
    @ObservedObject var readGate: RetryAfterGate
    @ObservedObject var gate: RetryAfterGate
    @ObservedObject var smsGate: RetryAfterGate
    @ObservedObject var verifyGate: RetryAfterGate
    @ObservedObject var context: WalletPageContext
    @State var toast: CouliToastMessage?
    @State var feeHelp = false
    /// 改金额后不再显示的金额类提交错误（事件编号），见 `amountError`。
    @State var staleAmountErrorId: Int?
    /// 金额框下的错误已经播报到哪个事件。
    @State var spokenFieldError: Int?
    @AccessibilityFocusState var submitFocused: Bool
    @AccessibilityFocusState var fieldErrorFocused: Bool

    public init(controller: WithdrawController, gates: WalletGates, context: WalletPageContext) {
        self.controller = controller
        flow = controller.flow
        stepUp = controller.flow.stepUp
        readGate = gates.read
        gate = gates.withdraw
        smsGate = gates.sms
        verifyGate = gates.verify
        self.context = context
    }

    var texts: WalletTexts {
        context.texts
    }

    public var body: some View {
        let snapshot = controller.state
        let flowState = flow.state
        let actions = WithdrawActions.make(controller, snapshot, risk: flowState.riskDialog?.id)
        let flowActions = FlowActions.make(flow, flowState)
        WalletPageScaffold(
            title: texts.text("withdraw.title"), backLabel: texts.text("wallet.back"), onBack: context.onBack,
            identifier: "withdraw.page"
        ) {
            content(snapshot, flowState, actions, flowActions)
        } bottom: {
            VStack(spacing: 0) {
                OpenErrorCard(context: context)
                if snapshot.phase == .content {
                    submitBar(snapshot, flowState, actions)
                }
            }
        }
        .couliDialog(isPresented: flowState.abandonConfirmKey != nil) {
            FlowDialogs.abandon(texts, title: texts.text("pending_confirm.withdraw.abandon"),
                                detail: pendingDetail(flowState, snapshot), actions: flowActions)
        }
        .couliDialog(isPresented: flowState.riskDialog != nil, restoreFocusTo: $submitFocused) {
            FlowDialogs.risk(texts, titleKey: flowState.riskDialog?.titleKey ?? "error.44001",
                             desc: texts.text("withdraw.risk_blocked.desc"), ok: flowActions.dismissRisk,
                             appeal: actions.appeal)
        }
        .couliSheet(isPresented: feeHelp, dismissOnScrim: { feeHelp = false }, sheet: { feeSheet })
        .walletStepUpSheet(stepUp, texts: texts, smsBlocked: smsGate.blocked, verifyBlocked: verifyGate.blocked,
                           restoreFocus: $submitFocused)
        .couliToast($toast)
        .onChange(of: flowState.toast) { value in
            guard let value else { return }
            toast = value.toast(texts)
            flow.consumeToast(value.id)
        }
        // 读执行器此刻的状态：iOS 16 的 onChange 闭包捕获的是上一次渲染的 `snapshot`（首次播报会丢、之后读出上一条，APP-12 R3-01 同类）
        .onChange(of: snapshot.announceId) { _ in announce(controller.state) }
        .onChange(of: snapshot.hideKeyboardId) { _ in
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .onChange(of: flowState.fieldErrorId) { _ in fieldErrorFocused = true }
        // 同上，读执行器此刻的错误
        .onChange(of: snapshot.amountText) { _ in staleAmountErrorId = flow.state.error?.id }
        .task { controller.start() }
    }

    func announce(_ snapshot: WithdrawSnapshot) {
        guard let line = snapshot.announce else { return }
        WalletAnnounce.post(line.render(texts, money: WalletMoney.spoken), assertive: false)
        controller.consumeAnnounce(snapshot.announceId)
    }

    @ViewBuilder func content(_ snapshot: WithdrawSnapshot, _ flowState: FlowState, _ actions: WithdrawActions,
                              _ flowActions: FlowActions) -> some View {
        switch snapshot.phase {
        case .loading, .error:
            // 待确认卡与写操作的结局（错误条、手动补办入口）独立于 rules 的读取状态（APP-09 共性第 2、67、76 条，iOS R1-03、R2-02）：
            // 加载中、读取失败时也在页首显示；确认与放弃只看各自的禁用期与在途状态；读取失败只影响 rules 的内容
            if flowState.pending != nil || flowState.error != nil || flowState.guideRoute != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                        if let pending = flowState.pending {
                            pendingCard(pending, snapshot, flowState, actions, flowActions)
                        }
                        writeNotices(flowState, flowActions)
                        readStatus(snapshot, actions)
                            .frame(minHeight: 240)
                    }
                    .padding(.top, CouliSpacing.s2)
                    .padding(.horizontal, CouliSpacing.s4)
                    .frame(maxWidth: WalletLayout.maxContentWidth)
                    .frame(maxWidth: .infinity)
                }
            } else {
                readStatus(snapshot, actions)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .content:
            ScrollView {
                VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                    if let pending = flowState.pending {
                        pendingCard(pending, snapshot, flowState, actions, flowActions)
                    }
                    notices(snapshot, flowState, actions, flowActions)
                    if let display = snapshot.display(slaDefault: texts) {
                        header(display)
                        amountCard(snapshot, display, flowState, actions)
                        infoCard(snapshot, display, actions)
                    }
                }
                .padding(.top, CouliSpacing.s2)
                .padding(.horizontal, CouliSpacing.s4)
                .frame(maxWidth: WalletLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// rules 的加载中 / 读取失败（只占自己的区域）。
    @ViewBuilder func readStatus(_ snapshot: WithdrawSnapshot, _ actions: WithdrawActions) -> some View {
        if snapshot.phase == .error {
            ErrorState(
                title: texts.text("withdraw.load_failed"), message: snapshot.loadError?.message(texts),
                retryTitle: texts.text("wallet.retry"), retry: actions.retry
            )
            .disabled(readGate.blocked)
            .walletProbe("withdraw.error", role: "error")
            .accessibilityIdentifier("withdraw.error")
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .walletProbe("withdraw.loading", role: "loading")
                .accessibilityLabel(Text(verbatim: texts.text("wallet.loading")))
                .accessibilityIdentifier("withdraw.loading")
        }
    }
}
