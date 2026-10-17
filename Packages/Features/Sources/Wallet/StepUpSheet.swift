import DesignSystem
import SwiftUI
import WalletCore

/// 二次验证面板的回调（渲染时取出面板实例编号，APP-11 第 17、28 条，APP-09 共性第 60、63 条）。
@MainActor
public struct StepUpActions {
    public let code: (String) -> Void
    public let resend: () -> Void
    public let verify: () -> Void
    public let close: () -> Void
    public let recheck: () -> Void

    public static func make(_ controller: StepUpController, _ state: StepUpUiState) -> StepUpActions {
        let instance = state.instance
        return StepUpActions(
            code: { [weak controller] text in controller?.onCodeChange(text, instance: instance) },
            resend: { [weak controller] in controller?.resend(instance: instance) },
            verify: { [weak controller] in controller?.verify(instance: instance) },
            close: { [weak controller] in controller?.close(instance: instance) },
            recheck: { [weak controller] in controller?.recheckIdentity(instance: instance) }
        )
    }
}

public extension View {
    /// 二次验证面板（WithdrawStepUp；brief §3 iOS：`.sheet` + `.interactiveDismissDisabled(true)`，点遮罩、下滑都不关闭，只有关闭键与系统
    /// 返回 / 读屏擦除走同一出口）。关闭后焦点回到触发控件（`restoreFocus`，A11yFocusStepUp）。
    func walletStepUpSheet(
        _ controller: StepUpController, texts: WalletTexts, smsBlocked: Bool, verifyBlocked: Bool,
        restoreFocus: AccessibilityFocusState<Bool>.Binding? = nil
    ) -> some View {
        sheet(isPresented: Binding(
            get: { controller.state != nil },
            set: { shown in
                if !shown, let state = controller.state {
                    StepUpActions.make(controller, state).close()
                }
            }
        ), onDismiss: {
            guard let restoreFocus else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                restoreFocus.wrappedValue = true
            }
        }, content: {
            StepUpSheetBody(controller: controller, texts: texts, smsBlocked: smsBlocked, verifyBlocked: verifyBlocked)
                .interactiveDismissDisabled(true)
        })
    }
}

/// 面板正文：标题区与底部操作区（倒计时 / 重新获取、【验证并提交】）固定，只有中段滚动（共性第 11 条）；三段最小高放不下键盘之后的实际
/// 可用高度时整块滚动（共性第 33 条）。
struct StepUpSheetBody: View {
    @ObservedObject var controller: StepUpController
    let texts: WalletTexts
    let smsBlocked: Bool
    let verifyBlocked: Bool
    @AccessibilityFocusState private var titleFocused: Bool
    @FocusState private var codeFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    static let codeAnchor = "stepUp.codeAnchor"
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var middleHeight: CGFloat = 0
    /// 中段最小高：一行验证码输入框（随字号放大）。
    @ScaledMetric(relativeTo: .title) private var middleMinHeight: CGFloat = 72

    /// 量出区块的实际高度（两种排版共用，切换后仍然有效）。
    func measured(_ content: some View, into height: Binding<CGFloat>) -> some View {
        content.background(GeometryReader { proxy in
            Color.clear
                .onAppear { height.wrappedValue = proxy.size.height }
                .onChange(of: proxy.size.height) { height.wrappedValue = $0 }
        })
    }

    var body: some View {
        if let state = controller.state {
            let actions = StepUpActions.make(controller, state)
            // 按键盘之后的实际可用高度排版（共性第 11、33 条）：标题区与底部操作区的实测高度 + 中段最小高（一行验证码）放得下时，只有中段滚动；
            // 放不下（短视口、200% 字号、键盘弹起）切整块滚动，标题、关闭与【验证并提交】都可滚动到达。
            GeometryReader { geo in
                let degraded = headerHeight + footerHeight + middleMinHeight + CouliSpacing.s4 * 2 > geo.size.height
                // 结构固定：标题区与操作区在「固定位置」与「随中段一起滚动」之间切换，中段（验证码输入框）始终在同一个 ScrollView 的同一槽位，
                // 键盘弹起导致切换时输入框不重建、不丢焦点。
                VStack(spacing: CouliSpacing.s4) {
                    if !degraded {
                        measured(header(actions), into: $headerHeight)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: CouliSpacing.s4) {
                                if degraded {
                                    measured(header(actions), into: $headerHeight)
                                }
                                measured(middle(state, actions), into: $middleHeight)
                                if degraded {
                                    measured(footer(state, actions), into: $footerHeight)
                                        .accessibilityElement(children: .contain)
                                        .accessibilityIdentifier("stepUp.fallback")
                                }
                            }
                        }
                        // 中段不贪高：按内容高度，放不下时随 VStack 压缩并在区内滚动；多出的空白留在操作区下方（设计稿 WithdrawStepUp）
                        .frame(maxHeight: degraded || middleHeight == 0 ? nil : middleHeight)
                        // 可用高度变了（键盘弹起、字号变化）：中段压缩时把验证码框（与错误提示）完整滚进可见区（鸿蒙 H21 同口径）
                        .onChange(of: geo.size.height) { _ in
                            withAnimation { proxy.scrollTo(Self.codeAnchor, anchor: .bottom) }
                        }
                    }
                    if !degraded {
                        measured(footer(state, actions), into: $footerHeight)
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            .padding(CouliSpacing.s4)
            .background(CouliColor.backgroundSurface.ignoresSafeArea())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("stepUp.sheet")
            // 设计稿 WithdrawStepUp 是半屏；辅助功能大字号时用整屏（内容按实测高度排版，放不下整块滚动）
            .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium])
            .task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                titleFocused = true
                codeFocused = true
            }
        }
    }

    func header(_ actions: StepUpActions) -> some View {
        HStack(alignment: .top) {
            Text(verbatim: texts.text("step_up.title"))
                .couliFont(.body, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
            Spacer(minLength: CouliSpacing.s2)
            Button(action: actions.close) {
                CouliIconView(.close)
                    .foregroundColor(CouliColor.textSecondary)
                    .couliHitTarget()
            }
            .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
            .accessibilityLabel(Text(verbatim: texts.text("step_up.close")))
            .accessibilityIdentifier("stepUp.close")
        }
        .accessibilityAction(.escape, actions.close)
    }

    func middle(_ state: StepUpUiState, _ actions: StepUpActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            Text(verbatim: texts.text(state.phase == .noPhone ? "step_up.no_phone" : "step_up.sent"))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(state.phase == .noPhone ? "stepUp.noPhone" : "stepUp.sent")
            TextField(texts.text("step_up.code_label"), text: Binding(get: { state.code }, set: actions.code))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .couliFont(.title, monospacedDigits: true)
                .focused($codeFocused)
                .padding(CouliSpacing.s3)
                .frame(minHeight: CouliHitTarget.minimum)
                .background(RoundedRectangle(cornerRadius: CouliRadius.button).stroke(CouliColor.borderControl))
                .disabled(state.phase == .verifying || state.phase == .noPhone)
                .accessibilityLabel(Text(verbatim: texts.format("step_up.code_spoken", ["n": "\(state.code.count)"])))
                .accessibilityIdentifier("stepUp.code")
                .id(Self.codeAnchor)
            if let error = state.error {
                Text(verbatim: error.message(texts))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.statusErrorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("stepUp.error")
                    .task(id: error.id) { WalletAnnounce.post(error.message(texts), assertive: true) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func footer(_ state: StepUpUiState, _ actions: StepUpActions) -> some View {
        VStack(spacing: CouliSpacing.s3) {
            if state.showsRecheck {
                CouliButton(texts.text("wallet.retry"), kind: .text, action: actions.recheck)
            }
            if state.showsSending {
                Text(verbatim: texts.text("step_up.sending"))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
            } else if state.phase != .noPhone {
                if state.resendLeftSec > 0 {
                    // 设计稿：倒计时靠右
                    Text(verbatim: texts.format("step_up.resend_in", ["sec": "\(state.resendLeftSec)"]))
                        .couliFont(.footnote, monospacedDigits: true)
                        .foregroundColor(CouliColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityIdentifier("stepUp.countdown")
                } else {
                    CouliButton(texts.text("step_up.resend"), kind: .text, size: .compact,
                                isEnabled: !smsBlocked && !state.awaitingIdentity && state.phase == .ready,
                                action: actions.resend)
                        .accessibilityIdentifier("stepUp.resend")
                }
            }
            CouliButton(
                texts.text("step_up.submit"), isLoading: state.showsVerifying,
                isEnabled: state.canVerify && !verifyBlocked, fillsWidth: true, action: actions.verify
            )
            .accessibilityIdentifier("stepUp.submit")
        }
    }
}
