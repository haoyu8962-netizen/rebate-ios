import SwiftUI

/// 二选一的说明半屏（APP-11v HomeClipboardConsent-v3）：把手、标题 22/600 左对齐、正文 14、底部两按钮并排等宽
/// （左次按钮描边、右主按钮；放不下时上下排、主按钮在上）。没有右上关闭（画板无）；关闭语义由调用方的遮罩 / 下滑出口给。
/// 模态，打开焦点进标题；正文放不下时只有正文滚动，标题与按钮固定可见。
public struct CouliChoiceSheet: View {
    private let title: String
    private let message: String
    private let primary: CouliDialogAction
    private let secondary: CouliDialogAction
    private let primaryID: String
    private let secondaryID: String
    private let titleID: String
    @AccessibilityFocusState private var titleFocused: Bool
    /// 把读屏焦点移到标题的次数（测量桥上报用，见 `couliFocusProbe`）。
    @State private var titleFocusRequests = 0

    /// - Parameters:
    ///   - primaryID / secondaryID: 两个按钮的可访问标识（UI 测试与诊断用）。
    ///   - titleID: 标题的焦点上报编号（测量桥；空串不报）。
    public init(title: String, message: String, primary: CouliDialogAction, secondary: CouliDialogAction,
                primaryID: String = "", secondaryID: String = "", titleID: String = "") {
        self.title = title
        self.message = message
        self.primary = primary
        self.secondary = secondary
        self.primaryID = primaryID
        self.secondaryID = secondaryID
        self.titleID = titleID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s4) {
            Capsule()
                .fill(CouliColor.borderSubtle)
                .frame(width: CouliGuideMetric.sheetHandleWidth, height: CouliGuideMetric.sheetHandleHeight)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .couliFont(.title, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
                .modifier(TitleFocusProbe(id: titleID, focused: titleFocused, requests: titleFocusRequests))
            ScrollingBody {
                Text(verbatim: message)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CouliSpacing.s3) {
                    secondaryButton.frame(maxWidth: .infinity)
                    primaryButton.frame(maxWidth: .infinity)
                }
                VStack(spacing: CouliSpacing.s3) {
                    primaryButton
                    secondaryButton
                }
            }
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
            try? await Task.sleep(nanoseconds: ModalFocus.titleFocusDelayNanos)
            titleFocused = true
            titleFocusRequests += 1
        }
    }

    private var primaryButton: some View {
        CouliButton(primary.title, kind: .primary, fillsWidth: true, action: primary.action)
            .accessibilityIdentifier(primaryID)
    }

    private var secondaryButton: some View {
        CouliButton(secondary.title, kind: .secondary, fillsWidth: true, action: secondary.action)
            .accessibilityIdentifier(secondaryID)
    }
}

/// 遮罩的读屏 / 自动化出口与下滑关闭（APP-11v HomeClipboardConsent-v3）。默认都不开：遮罩对读屏隐藏、半屏不响应下滑，
/// 与既有弹层一致。`label` 给了时遮罩是一个可读、可点的「关闭」元素（同系统半屏的「关闭弹出式窗口」），`identifier` 供 UI 测试点遮罩；
/// `dismissOnSwipe` 时半屏下滑超过阈值即按遮罩同一出口关闭。
public struct CouliSheetDismissal: Sendable {
    public let label: String?
    public let identifier: String?
    public let dismissOnSwipe: Bool

    public init(label: String? = nil, identifier: String? = nil, dismissOnSwipe: Bool = false) {
        self.label = label
        self.identifier = identifier
        self.dismissOnSwipe = dismissOnSwipe
    }

    static let none = CouliSheetDismissal()
}

/// 标题焦点上报（编号为空时不加）。
private struct TitleFocusProbe: ViewModifier {
    let id: String
    let focused: Bool
    let requests: Int

    func body(content: Content) -> some View {
        if id.isEmpty {
            content
        } else {
            content.couliFocusProbe(id, focused: focused, requests: requests)
        }
    }
}
