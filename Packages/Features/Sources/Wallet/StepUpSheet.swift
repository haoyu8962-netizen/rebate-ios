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
        modifier(StepUpSheetPresenter(controller: controller, texts: texts, smsBlocked: smsBlocked,
                                      verifyBlocked: verifyBlocked, restoreFocus: restoreFocus))
    }
}

/// 自己观察执行器：面板开合不依赖宿主页恰好重绘（四页共用件，宿主不一定观察 `StepUpController`）。
private struct StepUpSheetPresenter: ViewModifier {
    @ObservedObject var controller: StepUpController
    let texts: WalletTexts
    let smsBlocked: Bool
    let verifyBlocked: Bool
    let restoreFocus: AccessibilityFocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
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

/// 面板正文（W63–W68，WithdrawStepUp-v2）：标题区（把手、标题、说明）与底部操作区（【验证并提交】）固定，只有中段（6 格 + 格下一行）滚动
/// （共性第 11 条）；三段最小高放不下键盘之后的实际可用高度时整块滚动（共性第 33 条）。
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
    @State private var degraded = false
    /// 中段最小高：一行 6 格 + 格下一行（随字号放大）。
    @ScaledMetric(relativeTo: .title) private var middleMinHeight: CGFloat = StepUpMetric.middleMinimum
    /// 格下一行的预留高（画板 min-height 21）。
    @ScaledMetric(relativeTo: .footnote) private var rowHeight: CGFloat = CouliTextStyle.footnote.baseSize * 1.5

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
            // 按键盘之后的实际可用高度排版（共性第 11、33 条）：标题区与底部操作区的实测高度 + 中段最小高放得下时，只有中段滚动；
            // 放不下（短视口、200% 字号、键盘弹起）切整块滚动，标题、关闭与【验证并提交】都可滚动到达。
            GeometryReader { geo in
                // 首帧 geo 为 0 不算放不下；键盘起落时半屏先吃掉键盘高度、下一拍才整体上移，中间有约 0.3 秒的假短高度。
                // 切换整块滚动要重建标题区与操作区，所以等高度稳住才切（`degraded` 只由下面的 task 写）。
                let tooShort = geo.size.height > 0
                    && headerHeight + footerHeight + middleMinHeight > geo.size.height
                // 结构固定：标题区与操作区在「固定位置」与「随中段一起滚动」之间切换，中段（6 格与输入框）始终在同一个 ScrollView 的同一槽位，
                // 键盘弹起导致切换时输入框不重建、不丢焦点。
                VStack(spacing: 0) {
                    if !degraded {
                        measured(header(state, actions), into: $headerHeight)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                if degraded {
                                    measured(header(state, actions), into: $headerHeight)
                                }
                                measured(middle(state, actions), into: $middleHeight)
                                if degraded {
                                    measured(footer(state, actions), into: $footerHeight)
                                        .accessibilityElement(children: .contain)
                                        .accessibilityIdentifier("stepUp.fallback")
                                        .walletProbe("stepUp.fallback", role: "fallback")
                                }
                            }
                        }
                        // 中段不贪高：按内容高度，放不下时随 VStack 压缩并在区内滚动；多出的空白留在操作区下方（设计稿 WithdrawStepUp）
                        .frame(maxHeight: degraded || middleHeight == 0 ? nil : middleHeight)
                        // 可用高度变了（键盘弹起、字号变化）：中段压缩时把验证码格（与格下一行）完整滚进可见区（鸿蒙 H21 同口径）
                        .onChange(of: geo.size.height) { _ in
                            withAnimation { proxy.scrollTo(Self.codeAnchor, anchor: .bottom) }
                        }
                        // 防抖后才切整块滚动，标题区插进滚动内容会把格子往下推：切换后再定位一次，格下一行不落到键盘下
                        .onChange(of: degraded) { _ in
                            withAnimation { proxy.scrollTo(Self.codeAnchor, anchor: .bottom) }
                        }
                    }
                    if !degraded {
                        measured(footer(state, actions), into: $footerHeight)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: WalletLayout.maxContentWidth)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .task(id: tooShort) {
                    guard tooShort != degraded,
                          await (try? Task.sleep(nanoseconds: StepUpMetric.settleNanos)) != nil else { return }
                    degraded = tooShort
                }
            }
            .padding(.horizontal, CouliSpacing.s4)
            .padding(.bottom, CouliSpacing.s4)
            .background(CouliColor.backgroundSurface.ignoresSafeArea())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("stepUp.sheet")
            // 挂在根上：读屏焦点在验证码框时擦除手势也走关闭出口
            .accessibilityAction(.escape, actions.close)
            // 设计稿 WithdrawStepUp 是半屏；辅助功能大字号时用整屏（内容按实测高度排版，放不下整块滚动）
            .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium])
            // 验证中输入框锁定会收起键盘；答复带错误回来时把键盘叫回，半屏不跳、用户直接重输（Android 同口径）。只动焦点。
            .onChange(of: state.error?.id) { id in
                guard id != nil else { return }
                Task { @MainActor in
                    await Task.yield()
                    codeFocused = true
                }
            }
            .task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                titleFocused = true
                codeFocused = true
            }
        }
    }

    /// 把手（纯装饰）+ 标题 + 说明（G16 不显示号码；业务摘要不做，G-W19）+ 【×】，版式同画板：标题列与 44 关闭键顶对齐。
    func header(_ state: StepUpUiState, _ actions: StepUpActions) -> some View {
        VStack(spacing: CouliSpacing.s4) {
            StepUpHandle()
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                    RecordText(texts.text("error.10003"), style: .body, weight: .couliSemibold,
                               color: CouliColor.textPrimary, probe: "stepUp.title")
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($titleFocused)
                        .accessibilityIdentifier("stepUp.title")
                    RecordText(texts.text(state.phase == .noPhone ? "step_up.no_phone" : "step_up.sent"),
                               style: .footnote, color: CouliColor.textSecondary, probe: "stepUp.sent")
                        .accessibilityIdentifier(state.phase == .noPhone ? "stepUp.noPhone" : "stepUp.sent")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: actions.close) {
                    CouliIconView(.close)
                        .foregroundColor(CouliColor.textSecondary)
                        .walletProbe("stepUp.close", role: "icon")
                        .frame(minWidth: StepUpMetric.hitTarget, minHeight: StepUpMetric.hitTarget)
                        .contentShape(Rectangle())
                        .walletProbe("stepUp.close.hit", role: "hit")
                }
                .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                .accessibilityLabel(Text(verbatim: texts.text("step_up.close")))
                .accessibilityIdentifier("stepUp.close")
            }
        }
        // 中段可滚时 VStack 会按份额压缩提议高度，文字的行高盒跟着缩、字溢出压到邻居：标题区永远按内容高
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, StepUpMetric.topInset)
        .padding(.bottom, CouliSpacing.s4)
    }

    /// 6 格 + 格下一行。底部留白在滚动区内：【重新获取】44 命中区伸出视觉行，不留就被中段滚动裁掉（Android r1 S2-1）。
    func middle(_ state: StepUpUiState, _ actions: StepUpActions) -> some View {
        let locked = state.phase == .verifying || state.phase == .noPhone
        return VStack(spacing: CouliSpacing.s3) {
            StepUpCodeCells(code: state.code, active: !locked, hasError: state.error != nil)
                .overlay {
                    // 整串一个输入框盖在格子上（读屏一个元素、短信自动填充、粘贴都走它）；数字由格子画，这里文字与光标都不可见
                    TextField("", text: Binding(get: { state.code }, set: actions.code))
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .foregroundColor(.clear)
                        .tint(.clear)
                        .opacity(StepUpMetric.inputOpacity)
                        .focused($codeFocused)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .disabled(locked)
                        .accessibilityLabel(
                            Text(verbatim: texts.format("step_up.code_spoken", ["n": "\(state.code.count)"]))
                        )
                        .accessibilityIdentifier("stepUp.code")
                }
                .contentShape(Rectangle())
                .onTapGesture { codeFocused = true }
            statusRow(state, actions)
        }
        .id(Self.codeAnchor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, StepUpMetric.hitBleed)
    }

    /// 格下一行（W67）：左错误、右倒计时 /【重新获取】/ 发码中；空时也占一行，错误出现时格子和按钮不跳。
    func statusRow(_ state: StepUpUiState, _ actions: StepUpActions) -> some View {
        StepUpStatusLayout {
            HStack(alignment: .top, spacing: CouliSpacing.s1) {
                if let error = state.error {
                    WalletErrorIcon(probe: "stepUp.error.icon")
                    RecordText(error.message(texts), style: .footnote, color: CouliColor.statusErrorText,
                               probe: "stepUp.error.text")
                        .accessibilityIdentifier("stepUp.error")
                        .task(id: error.id) { WalletAnnounce.post(error.message(texts), assertive: true) }
                }
            }
            HStack(spacing: 0) {
                if state.showsSending {
                    RecordText(texts.text("step_up.sending"), style: .footnote, color: CouliColor.textSecondary,
                               alignment: .trailing, probe: "stepUp.sending")
                } else if state.phase != .noPhone {
                    if state.resendLeftSec > 0 {
                        RecordText(texts.format("login.code.countdown", ["n": "\(state.resendLeftSec)"]),
                                   style: .footnote, color: CouliColor.textSecondary, monospacedDigits: true,
                                   alignment: .trailing, probe: "stepUp.countdown")
                            .accessibilityIdentifier("stepUp.countdown")
                    } else {
                        // 命中 44 溢出视觉行（`.frame(height:)` 不撑高这一行，§9 第 7 条）
                        WithdrawLinkButton(title: texts.text("step_up.resend"), probe: "stepUp.resend", inset: 0,
                                           isEnabled: !smsBlocked && !state.awaitingIdentity && state.phase == .ready,
                                           hitMinimum: StepUpMetric.hitTarget, ringInside: true,
                                           action: actions.resend)
                            .accessibilityIdentifier("stepUp.resend")
                            .frame(height: rowHeight)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .topLeading)
        .walletProbe("stepUp.row", role: "row")
    }

    func footer(_ state: StepUpUiState, _ actions: StepUpActions) -> some View {
        VStack(spacing: CouliSpacing.s3) {
            if state.showsRecheck {
                CouliButton(texts.text("wallet.retry"), kind: .text, action: actions.recheck)
            }
            CouliButton(
                texts.text("step_up.submit"), isLoading: state.showsVerifying,
                isEnabled: state.canVerify && !verifyBlocked, fillsWidth: true, action: actions.verify
            )
            .accessibilityIdentifier("stepUp.submit")
            .walletProbe("stepUp.submit", role: "button")
        }
        // 与中段的留白合起来是画板的 16
        .padding(.top, CouliSpacing.s4 - StepUpMetric.hitBleed)
    }
}
