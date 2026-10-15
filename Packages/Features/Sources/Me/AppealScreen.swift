import CouliNetwork
import DesignSystem
import MeCore
import SwiftUI

/// 申诉页的按钮回调（渲染时取出执行器与版本）。
@MainActor
public struct AppealActions {
    public let input: (String) -> Void
    public let submit: () -> Void
    public let again: () -> Void
    public let action: (String) -> Void
    public let retry: () -> Void
    public let contactCs: () -> Void
    public let askLogout: () -> Void
    public let confirmLogout: (Int) -> Void
    public let cancelLogout: (Int) -> Void

    public static func make(_ controller: AppealController, _ state: AppealState) -> AppealActions {
        let version = state.version
        return AppealActions(
            input: { [weak controller] text in controller?.input(text) },
            submit: { [weak controller] in controller?.submit(version: version) },
            again: { [weak controller] in controller?.again(version: version) },
            action: { [weak controller] raw in controller?.action(raw, version: version) },
            retry: { [weak controller] in controller?.load() },
            contactCs: { [weak controller] in controller?.contactCs() },
            askLogout: { [weak controller] in controller?.askLogout() },
            confirmLogout: { [weak controller] dialog in controller?.confirmLogout(dialog) },
            cancelLogout: { [weak controller] dialog in controller?.cancelLogout(dialog) }
        )
    }
}

/// 账户申诉（Appeal 路由；设计稿 Appeal、AppealFrozen、AppealProgress、AppealProgressFrozen、AppealResultLifted(Frozen)、
/// AppealResultUpheld(Frozen)）：同一页按 G15 切版式；文案组按 G10（冻结 / 封禁），「当前是否受限」只按本次 risk.state（AppealCopy）。
/// 时间线与处理时间用「YYYY-MM-DD HH:mm」（H11）；不显示任何处理时限。申诉说明不设字数上限（契约没写，只按输入框默认）。
public struct AppealScreen: View {
    @ObservedObject var controller: AppealController
    @ObservedObject var readGate: RetryAfterGate
    @ObservedObject var submitGate: RetryAfterGate
    @AccessibilityFocusState private var errorFocused: Bool
    @AccessibilityFocusState var logoutFocused: Bool
    @State private var announced = 0

    public init(controller: AppealController) {
        self.controller = controller
        readGate = controller.readGate
        submitGate = controller.submitGate
    }

    var texts: MeTexts {
        controller.deps.texts
    }

    public var body: some View {
        let state = controller.state
        let actions = AppealActions.make(controller, state)
        Group {
            switch state.phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(Text(verbatim: texts.text("me.loading")))
                    .accessibilityIdentifier("appeal.loading")
            case .error:
                ErrorState(
                    title: texts.text("me.load_failed"), message: state.loadError?.message(texts),
                    retryTitle: texts.text("me.retry"), retry: actions.retry
                )
                .disabled(readGate.blocked)
                .accessibilityIdentifier("appeal.loadError")
            case .content:
                ScrollView {
                    VStack(alignment: .leading, spacing: CouliSpacing.s4) {
                        content(state, actions)
                    }
                    .padding(CouliSpacing.s4)
                    .meContentWidth()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .meNavigation(texts.text(controller.layout == AppealView.progress ? "appeal.progress.title" : "appeal.title"))
        .navigationBarBackButtonHidden(state.logoutDialog != nil)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appeal.page")
        .couliDialog(isPresented: state.logoutDialog != nil, restoreFocusTo: $logoutFocused) {
            let dialog = state.logoutDialog ?? 0
            return CouliDialog(
                title: texts.text("settings.logout.confirm"),
                primary: CouliDialogAction(texts.text("settings.logout.confirm_ok")) { actions.confirmLogout(dialog) },
                secondary: CouliDialogAction(texts.text("settings.logout.confirm_cancel")) {
                    actions.cancelLogout(dialog)
                }
            )
        }
        .onChange(of: state.errorEvent) { event in
            // 读执行器此刻的状态（iOS 16 的 onChange 闭包捕获上一次渲染的 `state`，R2-04 同一处理）
            guard event != announced, let error = controller.state.error else { return }
            announced = event
            // 申诉提交失败 assertive 播报一次，焦点移到错误提示（brief §2.16）
            MeAnnounce.post(error.message(texts), assertive: true)
            errorFocused = true
        }
        .task { controller.load() }
    }

    @ViewBuilder
    private func content(_ state: AppealState, _ actions: AppealActions) -> some View {
        switch controller.layout {
        case AppealView.progress:
            progress(state, actions)
        case AppealView.resultLifted:
            lifted(actions)
        case AppealView.resultUpheld:
            upheld(actions)
        default:
            submit(state, actions)
        }
    }

    var frozen: Bool {
        controller.frozenLayout
    }

    var risk: [String: Any] {
        controller.state.risk ?? [:]
    }

    func time(_ value: Any?) -> String? {
        (value as? String).flatMap(MeTime.instant).map(MeTime.minuteText)
    }

    private func targetCard() -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            Text(verbatim: texts.text("appeal.target"))
                .couliFont(.body, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            MeInfoRow(label: texts.text("appeal.type"), value: texts.text("appeal.type.account"))
            if let key = AppealCopy.currentStateKey(controller.riskState) {
                MeInfoRow(label: texts.text("appeal.current_state"), value: texts.text(key), identifier: "appeal.state")
            }
            if let reason = RiskReasonText.key(category: risk["reason_category"] as? String) {
                MeInfoRow(label: texts.text("appeal.reason"), value: texts.text(reason))
            }
            if controller.riskState == "frozen", let until = (risk["frozen_until"] as? String).flatMap(MeTime.instant) {
                MeInfoRow(label: texts.text("appeal.frozen_until"),
                          value: MeTime.futureText(until, now: controller.deps.env.displayNowMillis()))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .couliCard()
    }

    private func submit(_ state: AppealState, _ actions: AppealActions) -> some View {
        let enabled = controller.submitEnabled && !submitGate.blocked
        return VStack(alignment: .leading, spacing: CouliSpacing.s4) {
            targetCard()
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                Text(verbatim: texts.text("appeal.content_label"))
                    .couliFont(.body, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                TextEditor(text: Binding(get: { state.input }, set: { actions.input($0) }))
                    .couliFont(.body)
                    .frame(minHeight: CouliSpacing.s16 * 2)
                    .padding(CouliSpacing.s2)
                    .background(
                        RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                            .stroke(state.fieldError ? CouliColor.statusWarningText : CouliColor.borderSubtle,
                                    lineWidth: 1)
                    )
                    .accessibilityLabel(Text(verbatim: texts.text("appeal.content_label")))
                    .accessibilityHint(Text(verbatim: state.error?.message(texts) ?? ""))
                    .accessibilityIdentifier("appeal.input")
                if let error = state.error {
                    Text(verbatim: error.message(texts))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.statusWarningText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityFocused($errorFocused)
                        .accessibilityIdentifier("appeal.error")
                }
            }
            Text(verbatim: texts.text(AppealCopy.submitNote(frozenLayout: frozen, state: controller.riskState)))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(CouliSpacing.s3)
                .background(RoundedRectangle(cornerRadius: CouliRadius.card).fill(CouliColor.backgroundMuted))
            CouliButton(texts.text("appeal.submit"), isLoading: state.submitting, isEnabled: enabled, fillsWidth: true,
                        action: actions.submit)
                .accessibilityIdentifier("appeal.submit")
        }
    }
}
