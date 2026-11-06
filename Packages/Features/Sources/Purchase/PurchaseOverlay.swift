import DesignSystem
import ProductSearch
import SwiftUI
import Trade

/// 大屏（最小宽度 ≥ 600pt，03 §10.4）：弹窗与半屏内容限宽并水平居中，遮罩仍盖满窗口。
enum PurchaseLayout {
    static let maxContentWidth: CGFloat = 600
}

/// 购买浮层（APP-06b）：盖在发起页（详情、搜索）之上，按执行器状态渲染——
/// 加载层 ProductBuyOpening、浏览器提示 ProductJumpBrowser、确认框 ProductPriceChanged(+RebateGone) / ProductRebateGone / 券失效、
/// 比价无返利居中弹窗 ProductPriceCompareNoRebate-v2（APP-06v G-D10）、授权半屏 ProductAuthSheet、
/// 二选一 ProductAuthDeclined / ProductAuthFailed、ProductAuthUnavailable、授权结果查不到、JumpTip、ProductJumpSdkFailed、错误提示（30103 /
/// 30121 / 30151 / 30153 / 50303）与轻提示。
/// 全部模态：底层对读屏隐藏、焦点进标题；遮罩不关闭（要用户明确选择）；系统返回由发起页转成「取消 / 关闭」。
public struct PurchaseOverlay: ViewModifier {
    @ObservedObject var controller: OpenPurchaseController
    let text: PurchaseText
    let host: PurchaseOverlayHost
    @State private var toast: CouliToastMessage?
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    /// 详情页自绘导航栏的高度（最小 44，随标题字号增高）：轻提示放在它下方约 8（画板「导航栏下约 8」，评审 r1 S2-1）。
    @ScaledMetric(relativeTo: .body) private var navTitleLine: CGFloat = 26

    /// `host` 缺省 `.search`（不画常驻说明行的一侧，显示完整的安装说明合并句，宁可多说不可少说）；App 组装处都显式传。
    public init(controller: OpenPurchaseController, texts: SearchTexts, host: PurchaseOverlayHost = .search) {
        self.controller = controller
        text = PurchaseText(texts: texts)
        self.host = host
    }

    private var toastTopInset: CGFloat {
        host == .detail ? max(CouliHitTarget.minimum, navTitleLine) : 0
    }

    var state: PurchaseState {
        controller.state
    }

    var platform: String {
        state.platform
    }

    public func body(content: Content) -> some View {
        // 渲染时一次取出全部按钮回调（r3g NEW-02）：每个回调只带这次渲染的票据，执行时不读当前状态。
        let actions = overlayActions()
        return content
            // 半屏：关闭键、点遮罩、读屏双指擦除都等同关闭（A11yFocusAuthSheet「关闭方式」）；下单须知没有关闭键（画板），
            // 另开下滑关闭（回调同关闭）
            .couliSheet(
                isPresented: state.dialog?.isSheet == true, dismissOnScrim: actions.dismiss,
                dismissal: state.dialog?.isJumpTip == true ? CouliSheetDismissal(dismissOnSwipe: true) : nil
            ) {
                sheet.frame(maxWidth: PurchaseLayout.maxContentWidth)
                    .accessibilityAction(.escape) { actions.dismiss() }
            }
            // 居中弹窗：遮罩不关闭（要用户明确选择）；读屏双指擦除等同【取消】
            .couliPanel(isPresented: state.dialog.map { !$0.isSheet } ?? false) {
                dialog.frame(maxWidth: PurchaseLayout.maxContentWidth)
                    .accessibilityAction(.escape) { actions.dismiss() }
            }
            .couliPanel(isPresented: state.phase == .loading) {
                ProgressPanel(
                    title: text.text(PurchaseKeys.opening, platform: platform),
                    cancelTitle: text.text(PurchaseKeys.openingCancel),
                    onCancel: actions.cancelLoading
                )
                .accessibilityIdentifier("purchase.opening")
                .accessibilityAction(.escape) { actions.cancelLoading() }
            }
            .couliPanel(isPresented: state.browserNotice) {
                ProgressPanel(
                    title: text.text(PurchaseKeys.browserNotice, platform: platform),
                    cancelTitle: text.text(PurchaseKeys.openingCancel),
                    onCancel: actions.cancelBrowser
                )
                .accessibilityIdentifier("purchase.browser")
                .accessibilityAction(.escape) { actions.cancelBrowser() }
            }
            .couliToast($toast, topInset: toastTopInset)
            .onChange(of: state.toast) { value in
                guard let value else { return }
                let key = host.displayKey(value.key)
                toast = CouliToastMessage(
                    text.withTrace(key, platform: platform, traceId: value.traceId),
                    icon: PurchaseToastIcon.icon(for: key)
                )
                controller.consumeToast()
            }
    }

    // MARK: - 半屏

    @ViewBuilder private var sheet: some View {
        // 渲染时捕获（r3g NEW-02）
        let actions = overlayActions()
        switch state.dialog {
        case let .authSheet(platform, busy):
            // 标题约 20/700、标题前 32 平台官方图标（内置图、不改色、读屏隐藏；G-D14）
            CouliSheet(
                title: text.withTrace(authTitleKey(platform), platform: platform, traceId: nil),
                closeLabel: text.text(PurchaseKeys.close),
                titleStyle: .prominent,
                titleLeading: PlatformIcon.hasBuiltinImage(platform)
                    ? AnyView(PlatformIcon(platformCode: platform, size: .sheet)) : nil,
                onClose: actions.dismiss
            ) {
                BulletBox(lines: authLines(platform))
            } actions: {
                CouliButton(text.text(PurchaseKeys.authGo), isLoading: busy, isEnabled: !busy, fillsWidth: true) {
                    actions.authorize()
                }
                .accessibilityIdentifier("purchase.auth.go")
            }
            .accessibilityIdentifier("purchase.authSheet")
        case let .jumpTip(platform):
            // 标题约 20/700、两行圆点正文 17、无右上关闭（画板 ProductJumpTip-v2；Android b r1 S2-5；评审 r1 S2-2）
            CouliSheet(
                title: text.text(PurchaseKeys.jumpTipTitle),
                closeLabel: text.text(PurchaseKeys.close),
                titleStyle: .prominent,
                showsClose: false,
                onClose: actions.dismiss
            ) {
                BulletList(
                    lines: [text.text(PurchaseKeys.jumpTipLine1), text.text(PurchaseKeys.jumpTipLine2)], style: .body
                )
            } actions: {
                CouliButton(text.text(PurchaseKeys.jumpTipGo, platform: platform), fillsWidth: true) {
                    actions.confirm()
                }
                .accessibilityIdentifier("purchase.jumpTip.go")
            }
            .accessibilityIdentifier("purchase.jumpTip")
        default:
            EmptyView()
        }
    }

    private func authTitleKey(_ platform: String) -> String {
        if let code = controller.pendingAuthCode {
            return "error.\(code)"
        }
        return platform == "pdd" ? "error.30111" : "error.30101"
    }

    private func authLines(_ platform: String) -> [String] {
        var lines = [
            text.text(PurchaseKeys.authReason, platform: platform),
            text.text(PurchaseKeys.authPrivacy, platform: platform),
        ]
        if platform == "taobao" {
            lines.append(text.text(PurchaseKeys.authRebindNote))
        }
        return lines
    }
}

/// 购买浮层盖在哪一页（评审 r1 S1-1 / S2-1）：
/// - `.detail`：详情页有底栏上方的常驻说明行（G-D11），淘宝口令复制提示显示「已复制淘口令」；轻提示让出自绘导航栏。
/// - `.search`：搜索页没有常驻说明行，淘宝口令复制提示仍显示原合并句「安装淘宝后下单才有返利，口令已复制」（只换显示文案，
///   提示时机不变）；轻提示位置不变。
public enum PurchaseOverlayHost: Sendable {
    case detail
    case search

    /// 这一页实际显示的文案键。
    func displayKey(_ key: String) -> String {
        if self == .search, key == PurchaseTextKeys.notInstalledTpwdCopied {
            return PurchaseTextKeys.notInstalledCopied
        }
        return key
    }
}

extension PurchaseDialog {
    var isJumpTip: Bool {
        if case .jumpTip = self {
            return true
        }
        return false
    }
}

/// 轻提示图标按文案键分类（APP-06v §2.8；提示时机与文案不变）：取消后已更新 / 复核失败 → 信息 i；维护中 → 警告三角；
/// 已复制口令 → 复制；其余（错误、跳转失败等）不画图标。
enum PurchaseToastIcon {
    static func icon(for key: String) -> CouliToastIcon {
        if key.hasPrefix("trade.cancelled.") || key == PurchaseTextKeys.requote {
            return .info
        }
        if key.hasPrefix("error.50301") {
            return .warning
        }
        if key == PurchaseTextKeys.copied || key == PurchaseTextKeys.notInstalledCopied
            || key == PurchaseTextKeys.notInstalledTpwdCopied {
            return .copy
        }
        return .none
    }
}

public extension View {
    /// 盖上购买浮层（详情、搜索各一份执行器）。
    func purchaseOverlay(_ controller: OpenPurchaseController, texts: SearchTexts,
                         host: PurchaseOverlayHost) -> some View {
        modifier(PurchaseOverlay(controller: controller, texts: texts, host: host))
    }
}

/// 右上关闭（比价无返利确认，ProductPriceCompareNoRebate-v2）：读屏名 + 回调。
struct DialogClose {
    let label: String
    let action: () -> Void
}

/// 居中弹窗卡（标题 → 正文 → 按钮竖排）：与 DS 弹窗同一外观；正文放不下时滚动，标题与按钮固定；读屏焦点进标题。
/// - `iconColor`：标题前图标颜色（缺省：警告三角错误色、其余主文字色；30153 类用警告色、50303 的 i 用次文字色，APP-06v）。
/// - `close`：右上关闭（缺省无）。有关闭时标题在两侧等宽留白间居中，关闭视觉 24、命中 44 向外溢出到弹窗内边距，读屏顺序在标题之后。
struct DialogCard<Content: View, Buttons: View>: View {
    let title: String
    var icon: CouliIcon?
    var iconColor: Color?
    var close: DialogClose?
    @ViewBuilder let content: Content
    @ViewBuilder let buttons: Buttons
    @AccessibilityFocusState private var titleFocused: Bool

    init(
        title: String,
        icon: CouliIcon? = nil,
        iconColor: Color? = nil,
        close: DialogClose? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder buttons: () -> Buttons
    ) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
        self.close = close
        self.content = content()
        self.buttons = buttons()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s4) {
            if let close {
                closableTitle(close)
            } else {
                titleRow
            }
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: CouliSpacing.s3) { content }
                ScrollView {
                    VStack(alignment: .leading, spacing: CouliSpacing.s3) { content }
                }
            }
            VStack(spacing: CouliSpacing.s3) { buttons }
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
            try? await Task.sleep(nanoseconds: 150_000_000)
            titleFocused = true
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: CouliSpacing.s2) {
            if let icon {
                CouliIconView(icon, size: CouliComponentMetric.iconMedium, relativeTo: .body)
                    .foregroundColor(iconColor ??
                        (icon == .alert ? CouliColor.statusErrorText : CouliColor.textPrimary))
                    .accessibilityHidden(true)
            }
            titleText
        }
    }

    private var titleText: some View {
        Text(verbatim: title)
            .couliFont(.body, weight: .couliSemibold)
            .foregroundColor(CouliColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($titleFocused)
    }

    /// 标题居中、右上关闭：左右各留关闭的视觉宽，关闭按钮命中 44 向外溢出（不撑高标题行）。
    private func closableTitle(_ close: DialogClose) -> some View {
        titleText
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, CouliComponentMetric.iconMedium + CouliSpacing.s2)
            .overlay(alignment: .topTrailing) {
                Button(action: close.action) {
                    CouliIconView(.close)
                        .foregroundColor(CouliColor.textSecondary)
                        .couliHitTarget()
                }
                .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                .padding(-CouliSpacing.s2)
                .accessibilityLabel(Text(verbatim: close.label))
                .accessibilityIdentifier("purchase.dialog.close")
            }
    }
}

/// 价格对照的一行（之前 / 现在）。
struct PriceRow: View {
    let label: String
    let amount: String
    let spoken: String
    let emphasized: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: label)
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
            Spacer(minLength: CouliSpacing.s2)
            Text(verbatim: amount)
                .couliFont(emphasized ? .body : .footnote, weight: emphasized ? .couliSemibold : .regular)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label + " " + spoken))
    }
}

/// 灰底要点框（ProductAuthSheet）。
struct BulletBox: View {
    let lines: [String]

    var body: some View {
        BulletList(lines: lines)
            .padding(CouliSpacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous).fill(CouliColor.backgroundMuted)
            )
    }
}

/// 圆点要点列表（每条单独一个读屏元素）。`style`：授权说明 14（缺省）、下单须知 17。
struct BulletList: View {
    let lines: [String]
    var style: CouliTextStyle = .footnote

    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: CouliSpacing.s2) {
                    Circle()
                        .fill(CouliColor.textSecondary)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text(verbatim: line)
                        .couliFont(style)
                        .foregroundColor(CouliColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
