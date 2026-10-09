import SwiftUI

// MARK: - Dialog / Sheet

/// 弹窗按钮。
public struct CouliDialogAction {
    public let title: String
    public let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
}

/// 居中弹窗（GUIDE §3「弹窗」、§6、§7.2；adaptation-a11y-spec §4、§8）：模态，焦点进标题，底层对读屏隐藏，
/// 关闭后焦点回到触发控件（`couliDialog(restoreFocusTo:)`）；
/// 正文放不下时只有正文滚动，标题与按钮行固定可见（320×568、200% 字号、长正文同样）。
/// 按钮行：次按钮在前、主按钮在后，放不下时整块换行、主按钮在上（wrap-reverse）。点遮罩不关闭（由调用方的按钮关闭）。
public struct CouliDialog: View {
    private let title: String
    private let message: String?
    private let content: AnyView?
    private let centeredTitle: Bool
    private let primary: CouliDialogAction
    private let secondary: CouliDialogAction?
    @AccessibilityFocusState private var titleFocused: Bool

    public init(title: String, message: String? = nil, primary: CouliDialogAction,
                secondary: CouliDialogAction? = nil) {
        self.title = title
        self.message = message
        content = nil
        centeredTitle = false
        self.primary = primary
        self.secondary = secondary
    }

    /// 自定义正文（如首启隐私弹窗的要点列表与协议链接，APP-02b）。正文同样放不下时滚动，标题与按钮行固定。
    /// - Parameter centeredTitle: 标题居中（设计稿 LaunchPrivacy、LaunchSecondNotice 等）。
    public init(
        title: String,
        centeredTitle: Bool = false,
        primary: CouliDialogAction,
        secondary: CouliDialogAction? = nil,
        @ViewBuilder content: () -> some View
    ) {
        self.title = title
        message = nil
        self.content = AnyView(content())
        self.centeredTitle = centeredTitle
        self.primary = primary
        self.secondary = secondary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s4) {
            Text(verbatim: title)
                .couliFont(.body, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .multilineTextAlignment(centeredTitle ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: centeredTitle ? .infinity : nil)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
            if let content {
                ScrollingBody {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let message {
                ScrollingBody {
                    Text(verbatim: message)
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            buttons
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(CouliSpacing.s5)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous).fill(CouliColor.backgroundSurface)
                .couliShadow(.floating)
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .task {
            // 等面板挂上无障碍树、底层隐藏生效后再把读屏焦点放到标题（adaptation-a11y-spec §4）。
            try? await Task.sleep(nanoseconds: ModalFocus.titleFocusDelayNanos)
            titleFocused = true
        }
    }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: CouliSpacing.s3) {
                if let secondary {
                    CouliButton(secondary.title, kind: .secondary, fillsWidth: true, action: secondary.action)
                        .frame(maxWidth: .infinity)
                }
                CouliButton(primary.title, kind: .primary, fillsWidth: true, action: primary.action)
                    .frame(maxWidth: .infinity)
            }
            VStack(spacing: CouliSpacing.s3) {
                CouliButton(primary.title, kind: .primary, fillsWidth: true, action: primary.action)
                if let secondary {
                    CouliButton(secondary.title, kind: .secondary, fillsWidth: true, action: secondary.action)
                }
            }
        }
    }
}

/// 正文区：放得下时按内容高；放不下时占满剩余高度并滚动（头部与操作区固定，adaptation-a11y-spec §4）。
struct ScrollingBody<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView {
                content
            }
        }
    }
}

/// 底部半屏（GUIDE §3「半屏」）：上两角圆角 24、把手、标题 → 关闭 → 正文 → 操作；模态，焦点进标题。
/// 正文放不下时只有正文滚动，头部与 `actions` 固定可见。
public struct CouliSheet<Content: View, Actions: View>: View {
    private let title: String
    private let closeLabel: String
    private let onClose: () -> Void
    private let content: Content
    private let actions: Actions
    @AccessibilityFocusState private var titleFocused: Bool

    /// - Parameter closeLabel: 关闭按钮读屏名称（字典文案）。
    public init(
        title: String,
        closeLabel: String,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.closeLabel = closeLabel
        self.onClose = onClose
        self.content = content()
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s4) {
            Capsule()
                .fill(CouliColor.borderSubtle)
                .frame(width: CouliGuideMetric.sheetHandleWidth, height: CouliGuideMetric.sheetHandleHeight)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            HStack(alignment: .top) {
                Text(verbatim: title)
                    .couliFont(.body, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Spacer(minLength: CouliSpacing.s2)
                Button(action: onClose) {
                    CouliIconView(.close)
                        .foregroundColor(CouliColor.textSecondary)
                        .couliHitTarget()
                }
                .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                .padding(-CouliSpacing.s2)
                .accessibilityLabel(Text(verbatim: closeLabel))
            }
            ScrollingBody {
                VStack(alignment: .leading, spacing: CouliSpacing.s4) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: CouliSpacing.s3) { actions }
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, CouliSpacing.s3)
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.bottom, CouliSpacing.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            TopRoundedRectangle(radius: CouliRadius.panel)
                .fill(CouliColor.backgroundSurface)
                .ignoresSafeArea(edges: .bottom)
                .couliShadow(.floating)
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .task {
            // 等面板挂上无障碍树、底层隐藏生效后再把读屏焦点放到标题（adaptation-a11y-spec §4）。
            try? await Task.sleep(nanoseconds: ModalFocus.titleFocusDelayNanos)
            titleFocused = true
        }
    }
}

/// 弹层的读屏焦点规则（adaptation-a11y-spec §4、§8）：打开时焦点进面板标题；关闭后回到打开它的触发控件。
/// 纯逻辑单独拿出来，便于单测；真正移焦点由 `ModalOverlayModifier` 做。
enum ModalFocus: Equatable {
    /// 刚打开：面板自己把焦点放到标题。
    case focusPanelTitle
    /// 刚关闭（按钮、遮罩、关闭键都走同一处）：把焦点还给触发控件。
    case restoreTrigger
    case none

    /// 打开后等面板挂上无障碍树再移焦点。
    static let titleFocusDelayNanos: UInt64 = 150_000_000
    /// 关闭动画（0.2 s）结束、底层解除 accessibilityHidden 后再还焦点。
    static let restoreDelayNanos: UInt64 = 300_000_000

    static func transition(wasPresented: Bool, isPresented: Bool) -> ModalFocus {
        switch (wasPresented, isPresented) {
        case (false, true): .focusPanelTitle
        case (true, false): .restoreTrigger
        default: .none
        }
    }
}

private struct ModalOverlayModifier<Panel: View>: ViewModifier {
    let isPresented: Bool
    let alignment: Alignment
    let dismissOnScrim: (() -> Void)?
    let restoreFocus: AccessibilityFocusState<Bool>.Binding?
    let panel: () -> Panel

    func body(content: Content) -> some View {
        ZStack(alignment: alignment) {
            content
                .accessibilityHidden(isPresented)
            if isPresented {
                CouliScrim.color
                    .ignoresSafeArea()
                    .onTapGesture { dismissOnScrim?() }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                panel()
                    // 弹窗四周留 24；半屏顶部留 24（最大高 = 可视高度 − 顶部安全区 − 24）。
                    .padding(alignment == .center ? .all : .top, CouliSpacing.s6)
                    .transition(alignment == .center ? .opacity : .move(edge: .bottom))
            }
        }
        .animation(.easeOut(duration: 0.2), value: isPresented)
        .onChange(of: isPresented) { newValue in
            guard ModalFocus.transition(wasPresented: !newValue, isPresented: newValue) == .restoreTrigger,
                  let restoreFocus
            else {
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: ModalFocus.restoreDelayNanos)
                restoreFocus.wrappedValue = true
            }
        }
    }
}

public extension View {
    /// 盖上居中弹窗（遮罩不关闭）。
    /// - Parameter restoreFocusTo: 触发控件的读屏焦点绑定（触发控件上挂 `.accessibilityFocused(_:)`）；
    ///   弹窗关闭后焦点回到该控件。打开时焦点进弹窗标题（组件自己做）。
    func couliDialog(
        isPresented: Bool,
        restoreFocusTo: AccessibilityFocusState<Bool>.Binding? = nil,
        @ViewBuilder dialog: @escaping () -> CouliDialog
    ) -> some View {
        modifier(ModalOverlayModifier(isPresented: isPresented, alignment: .center, dismissOnScrim: nil,
                                      restoreFocus: restoreFocusTo, panel: dialog))
    }

    /// 盖上居中的自定义面板（加载层「正在打开淘宝」、浏览器提示等不是标准弹窗的模态层；APP-06b）：同样模态、底层对读屏隐藏、
    /// 遮罩不关闭，关闭后焦点回到触发控件。面板自己负责把读屏焦点放到标题。
    func couliPanel(
        isPresented: Bool,
        restoreFocusTo: AccessibilityFocusState<Bool>.Binding? = nil,
        @ViewBuilder panel: @escaping () -> some View
    ) -> some View {
        modifier(ModalOverlayModifier(isPresented: isPresented, alignment: .center, dismissOnScrim: nil,
                                      restoreFocus: restoreFocusTo, panel: panel))
    }

    /// 盖上底部半屏。`dismissOnScrim` 为 nil 时点遮罩不关闭（资金与验证类，adaptation-a11y-spec §4）。
    /// - Parameter restoreFocusTo: 同 `couliDialog`；按钮、关闭键、遮罩任一方式关闭后焦点都回到触发控件。
    func couliSheet(
        isPresented: Bool,
        dismissOnScrim: (() -> Void)?,
        restoreFocusTo: AccessibilityFocusState<Bool>.Binding? = nil,
        @ViewBuilder sheet: @escaping () -> some View
    ) -> some View {
        modifier(ModalOverlayModifier(isPresented: isPresented, alignment: .bottom, dismissOnScrim: dismissOnScrim,
                                      restoreFocus: restoreFocusTo, panel: sheet))
    }
}
