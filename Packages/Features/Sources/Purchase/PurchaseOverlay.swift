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
/// 比价半屏 ProductPriceCompareNoRebate、授权半屏 ProductAuthSheet、二选一 ProductAuthDeclined / ProductAuthFailed、
/// ProductAuthUnavailable、授权结果查不到、JumpTip、ProductJumpSdkFailed、错误提示（30103 / 30121 / 30151 / 30153 / 50303）与轻提示。
/// 全部模态：底层对读屏隐藏、焦点进标题；遮罩不关闭（要用户明确选择）；系统返回由发起页转成「取消 / 关闭」。
public struct PurchaseOverlay: ViewModifier {
    @ObservedObject var controller: OpenPurchaseController
    let text: PurchaseText
    @State private var toast: CouliToastMessage?
    @Environment(\.dynamicTypeSize) var dynamicTypeSize

    public init(controller: OpenPurchaseController, texts: SearchTexts) {
        self.controller = controller
        text = PurchaseText(texts: texts)
    }

    var state: PurchaseState {
        controller.state
    }

    var platform: String {
        state.platform
    }

    public func body(content: Content) -> some View {
        content
            // 半屏：关闭键、点遮罩、读屏双指擦除都等同关闭（A11yFocusAuthSheet「关闭方式」）
            .couliSheet(isPresented: state.dialog?.isSheet == true, dismissOnScrim: controller.dismissDialog) {
                sheet.frame(maxWidth: PurchaseLayout.maxContentWidth)
                    .accessibilityAction(.escape) { controller.dismissDialog() }
            }
            // 居中弹窗：遮罩不关闭（要用户明确选择）；读屏双指擦除等同【取消】
            .couliPanel(isPresented: state.dialog.map { !$0.isSheet } ?? false) {
                dialog.frame(maxWidth: PurchaseLayout.maxContentWidth)
                    .accessibilityAction(.escape) { controller.dismissDialog() }
            }
            .couliPanel(isPresented: state.phase == .loading) {
                ProgressPanel(
                    title: text.text(PurchaseKeys.opening, platform: platform),
                    cancelTitle: text.text(PurchaseKeys.openingCancel),
                    onCancel: controller.cancelLoading
                )
                .accessibilityIdentifier("purchase.opening")
                .accessibilityAction(.escape) { controller.cancelLoading() }
            }
            .couliPanel(isPresented: state.browserNotice) {
                ProgressPanel(
                    title: text.text(PurchaseKeys.browserNotice, platform: platform),
                    cancelTitle: text.text(PurchaseKeys.openingCancel),
                    onCancel: controller.cancelBrowser
                )
                .accessibilityIdentifier("purchase.browser")
                .accessibilityAction(.escape) { controller.cancelBrowser() }
            }
            .couliToast($toast)
            .onChange(of: state.toast) { value in
                guard let value else { return }
                toast = CouliToastMessage(text.withTrace(value.key, platform: platform, traceId: value.traceId))
                controller.consumeToast()
            }
    }

    // MARK: - 半屏

    @ViewBuilder private var sheet: some View {
        switch state.dialog {
        case let .authSheet(platform, busy):
            CouliSheet(
                title: text.withTrace(authTitleKey(platform), platform: platform, traceId: nil),
                closeLabel: text.text(PurchaseKeys.close),
                onClose: controller.dismissDialog
            ) {
                BulletBox(lines: authLines(platform))
            } actions: {
                CouliButton(text.text(PurchaseKeys.authGo), isLoading: busy, isEnabled: !busy, fillsWidth: true) {
                    controller.authorize()
                }
                .accessibilityIdentifier("purchase.auth.go")
            }
            .accessibilityIdentifier("purchase.authSheet")
        case let .jumpTip(platform):
            CouliSheet(
                title: text.text(PurchaseKeys.jumpTipTitle),
                closeLabel: text.text(PurchaseKeys.close),
                onClose: controller.dismissDialog
            ) {
                BulletList(lines: [text.text(PurchaseKeys.jumpTipLine1), text.text(PurchaseKeys.jumpTipLine2)])
            } actions: {
                CouliButton(text.text(PurchaseKeys.jumpTipGo, platform: platform), fillsWidth: true) {
                    controller.confirm()
                }
                .accessibilityIdentifier("purchase.jumpTip.go")
            }
            .accessibilityIdentifier("purchase.jumpTip")
        case .compareNoRebate:
            CouliSheet(
                title: text.text(PurchaseKeys.compareTitle),
                closeLabel: text.text(PurchaseKeys.close),
                onClose: controller.dismissDialog
            ) {
                Text(verbatim: text.text(PurchaseKeys.compareBody))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.explanationAvailable {
                    CouliButton(text.text(PurchaseKeys.compareExplain), kind: .text, size: .compact) {
                        controller.viewExplanation()
                    }
                    .accessibilityIdentifier("purchase.compare.explain")
                }
            } actions: {
                CouliButton(text.text(PurchaseKeys.buyNoRebate), fillsWidth: true) { controller.confirm() }
                    .accessibilityIdentifier("purchase.compare.buy")
                CouliButton(text.text(PurchaseKeys.similar), kind: .secondary, fillsWidth: true) {
                    controller.similar()
                }
                .accessibilityIdentifier("purchase.compare.similar")
            }
            .accessibilityIdentifier("purchase.compare")
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

public extension View {
    /// 盖上购买浮层（详情、搜索各一份执行器）。
    func purchaseOverlay(_ controller: OpenPurchaseController, texts: SearchTexts) -> some View {
        modifier(PurchaseOverlay(controller: controller, texts: texts))
    }
}

/// 居中弹窗卡（标题 → 正文 → 按钮竖排）：与 DS 弹窗同一外观；正文放不下时滚动，标题与按钮固定；读屏焦点进标题。
struct DialogCard<Content: View, Buttons: View>: View {
    let title: String
    var icon: CouliIcon?
    @ViewBuilder let content: Content
    @ViewBuilder let buttons: Buttons
    @AccessibilityFocusState private var titleFocused: Bool

    init(
        title: String,
        icon: CouliIcon? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder buttons: () -> Buttons
    ) {
        self.title = title
        self.icon = icon
        self.content = content()
        self.buttons = buttons()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s4) {
            HStack(alignment: .firstTextBaseline, spacing: CouliSpacing.s2) {
                if let icon {
                    CouliIconView(icon, size: CouliGuideMetric.iconMedium, relativeTo: .body)
                        .foregroundColor(icon == .alert ? CouliColor.statusErrorText : CouliColor.textPrimary)
                        .accessibilityHidden(true)
                }
                Text(verbatim: title)
                    .couliFont(.body, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
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

/// 圆点要点列表（每条单独一个读屏元素）。
struct BulletList: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: CouliSpacing.s2) {
                    Circle()
                        .fill(CouliColor.textSecondary)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text(verbatim: line)
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
