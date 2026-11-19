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
    /// 【申请注销】的读屏焦点（由套二次验证半屏的一方持有并传入，半屏关闭后焦点回到这里，A11yFocusStepUp）；nil = 本页自己持有。
    let applyFocus: AccessibilityFocusState<Bool>.Binding?

    public init(host: MePageHost<DeleteAccountController>, texts: AccountDraftTexts = AccountDraftTexts(),
                applyFocus: AccessibilityFocusState<Bool>.Binding? = nil) {
        self.host = host
        self.texts = texts
        self.applyFocus = applyFocus
    }

    public var body: some View {
        let controller = host.controller
        DeleteAccountBody(
            controller: controller, flow: controller.flow, writeGate: controller.writeGate,
            cancelGate: controller.cancelGate, readGate: controller.readGate, fundsGate: controller.fundsGate,
            texts: texts, applyFocus: applyFocus
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
    let applyFocus: AccessibilityFocusState<Bool>.Binding?
    @State private var toast: CouliToastMessage?
    @AccessibilityFocusState private var ownApplyFocus: Bool

    /// 【申请注销】的读屏焦点：二次验证半屏与放弃确认框关闭后都回到这里。
    var applyFocused: AccessibilityFocusState<Bool>.Binding {
        applyFocus ?? $ownApplyFocus
    }

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
        .couliDialog(isPresented: flowState.abandonConfirmKey != nil, restoreFocusTo: applyFocused) {
            CouliDialog(
                title: texts.text("pending_confirm.abandon"),
                onEscape: actions.cancelAbandon,
                primary: CouliDialogAction(texts.text("pending_confirm.abandon.ok"), action: actions.abandon),
                secondary: CouliDialogAction(
                    texts.text("pending_confirm.abandon.cancel"),
                    action: actions.cancelAbandon
                )
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
}
