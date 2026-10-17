import CouliNetwork
import DesignSystem
import SwiftUI
import WalletCore

/// 收款账号页的回调（渲染时取出版本、账号身份与表单身份，共性第 25、59、63 条）。
@MainActor
public struct PayoutActions {
    public let change: () -> Void
    public let method: (String) -> Void
    public let logon: (String) -> Void
    public let card: (String) -> Void
    public let bank: (String) -> Void
    public let payee: (String) -> Void
    public let save: () -> Void
    public let retry: () -> Void
    public let appeal: () -> Void
    public let openGuide: () -> Void

    public static func make(_ controller: PayoutAccountController, _ snapshot: PayoutSnapshot, risk: Int?)
        -> PayoutActions {
        let owner = controller.owner
        let version = snapshot.version
        let shown = snapshot.account ?? .unbound
        let dialog = risk ?? -1
        return PayoutActions(
            change: { [weak controller] in controller?.change(version: version, shown: shown, owner: owner) },
            method: { [weak controller] in controller?.chooseMethod($0, owner: owner) },
            logon: { [weak controller] in controller?.onLogonChange($0, owner: owner) },
            card: { [weak controller] in controller?.onCardChange($0, owner: owner) },
            bank: { [weak controller] in controller?.onBankChange($0, owner: owner) },
            payee: { [weak controller] in controller?.onPayeeChange($0, owner: owner) },
            save: { [weak controller] in controller?.save(owner: owner) },
            retry: { [weak controller] in controller?.retry() },
            appeal: { [weak controller] in controller?.appeal(dialog: dialog) },
            openGuide: { [weak controller] in controller?.openGuide(owner: owner) }
        )
    }
}

/// 收款账号（PayoutAccount 路由；设计稿
/// PayoutAccount、PayoutAccountBank、PayoutAccountBound、PayoutAccountBoundBank、PayoutAccountBlocked、
/// PayoutAccountPending*）。不显示微信零钱（排除项）。
public struct PayoutAccountScreen: View {
    @ObservedObject var controller: PayoutAccountController
    @ObservedObject var flow: SensitiveFlow
    @ObservedObject var stepUp: StepUpController
    @ObservedObject var readGate: RetryAfterGate
    @ObservedObject var gate: RetryAfterGate
    @ObservedObject var smsGate: RetryAfterGate
    @ObservedObject var verifyGate: RetryAfterGate
    @ObservedObject var context: WalletPageContext
    @State var toast: CouliToastMessage?
    @AccessibilityFocusState var saveFocused: Bool
    @AccessibilityFocusState var errorFocused: Bool
    /// 字段错误的定位（共性第 24、74 条，iOS R1-11）：首个错误字段的错误提示是焦点与滚动目标，视图出现后按事件编号定位、播报一次。
    @AccessibilityFocusState var focusedField: String?
    @State var errorCue = FieldErrorCue()
    @State var scrollRequest: FieldScrollRequest?

    public init(controller: PayoutAccountController, gates: WalletGates, context: WalletPageContext) {
        self.controller = controller
        flow = controller.flow
        stepUp = controller.flow.stepUp
        readGate = gates.read
        gate = gates.payout
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
        let actions = PayoutActions.make(controller, snapshot, risk: flowState.riskDialog?.id)
        let flowActions = FlowActions.make(flow, flowState)
        WalletPageScaffold(
            title: texts.text("payout.title"), backLabel: texts.text("wallet.back"), onBack: context.onBack,
            identifier: "payout.page"
        ) {
            content(snapshot, flowState, actions, flowActions)
        } bottom: {
            if snapshot.editing, snapshot.phase == .content, flowState.pending == nil {
                saveBar(flowState, actions)
            }
        }
        .couliDialog(isPresented: flowState.abandonConfirmKey != nil) {
            FlowDialogs.abandon(
                texts, detail: texts.text("pending_confirm.payout_account.abandon_note"), actions: flowActions
            )
        }
        .couliDialog(isPresented: flowState.riskDialog != nil, restoreFocusTo: $saveFocused) {
            FlowDialogs.risk(texts, titleKey: flowState.riskDialog?.titleKey ?? "error.44001",
                             desc: texts.text("payout.blocked.desc"), ok: flowActions.dismissRisk,
                             appeal: actions.appeal)
        }
        .walletStepUpSheet(stepUp, texts: texts, smsBlocked: smsGate.blocked, verifyBlocked: verifyGate.blocked,
                           restoreFocus: $saveFocused)
        .couliToast($toast)
        .onChange(of: flowState.toast) { value in
            guard let value else { return }
            toast = value.toast(texts)
            flow.consumeToast(value.id)
        }
        .onChange(of: snapshot.toast) { value in
            guard let value else { return }
            toast = value.toast(texts)
            controller.consumeToast(value.id)
        }
        .onChange(of: flowState.fieldErrorId) { id in
            let fields = controller.flow.state.fieldErrors
            guard !fields.isEmpty else {
                errorFocused = true
                return
            }
            errorCue.arm(event: "F\(id)", errors: fields,
                         order: FieldErrorCue.payoutOrder(method: controller.state.form.method))
        }
        .onChange(of: snapshot.localErrorId) { id in
            errorCue.arm(event: "L\(id)", errors: controller.state.localErrors,
                         order: FieldErrorCue.payoutOrder(method: controller.state.form.method))
        }
        .task { controller.start() }
    }

    @ViewBuilder func content(_ snapshot: PayoutSnapshot, _ flowState: FlowState, _ actions: PayoutActions,
                              _ flowActions: FlowActions) -> some View {
        switch snapshot.phase {
        case .loading, .error:
            // 待确认卡与写操作的结局（错误条、手动补办入口）独立于收款账号的读取状态（APP-09 共性第 2、67、76 条，iOS R1-03、R2-02）：
            // 读取失败只影响账号内容，确认与放弃照常，确认 / 放弃得到的明确结局照常显示
            if flowState.pending != nil || flowState.error != nil || flowState.guideRoute != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                        if let pending = flowState.pending {
                            payoutPending(pending, flowState, flowActions)
                        }
                        writeNotices(flowState, flowActions)
                        readStatus(snapshot, actions)
                            .frame(minHeight: 240)
                    }
                    .padding(CouliSpacing.s4)
                    .frame(maxWidth: WalletLayout.maxContentWidth)
                    .frame(maxWidth: .infinity)
                }
            } else {
                readStatus(snapshot, actions)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .content:
            ScrollViewReader { proxy in
                contentScroll(snapshot, flowState, actions, flowActions)
                    .onChange(of: scrollRequest) { request in
                        guard let request else { return }
                        withAnimation { proxy.scrollTo(request.anchor, anchor: .center) }
                    }
            }
        }
    }

    func contentScroll(_ snapshot: PayoutSnapshot, _ flowState: FlowState, _ actions: PayoutActions,
                       _ flowActions: FlowActions) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                if let pending = flowState.pending {
                    payoutPending(pending, flowState, flowActions)
                }
                pageNotices(snapshot, flowState, actions, flowActions)
                if let account = snapshot.account, account.bound {
                    boundCard(account, snapshot, flowState, actions)
                }
                // 待确认时只显示待确认卡与当前账号（设计稿 PayoutAccountPendingConfirm），表单收起、已填内容保留
                if snapshot.editing, flowState.pending == nil {
                    formCard(snapshot, flowState, actions)
                }
            }
            .padding(CouliSpacing.s4)
            .frame(maxWidth: WalletLayout.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// 收款账号的加载中 / 读取失败（只占自己的区域）。
    @ViewBuilder func readStatus(_ snapshot: PayoutSnapshot, _ actions: PayoutActions) -> some View {
        if snapshot.phase == .error {
            VStack(spacing: CouliSpacing.s3) {
                ErrorState(
                    title: texts.text("payout.load_failed"), message: snapshot.loadError?.message(texts),
                    retryTitle: texts.text("wallet.retry"), retry: actions.retry
                )
                .disabled(readGate.blocked)
                if let route = snapshot.guideRoute {
                    GuideEntry(texts: texts, route: route, action: actions.openGuide)
                }
            }
            .accessibilityIdentifier("payout.error")
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text(verbatim: texts.text("wallet.loading")))
                .accessibilityIdentifier("payout.loading")
        }
    }
}
