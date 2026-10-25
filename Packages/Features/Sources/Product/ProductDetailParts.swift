import DesignSystem
import SwiftUI

// 商品详情页私有件（APP-06v-a）：底栏外壳与排法、【问问 AI】竖排入口、比价无返利原因行、加载骨架。

// MARK: - 底栏

/// 底栏外壳（§2.6，GUIDE §7.2「商品详情」）：白底 + 顶部 1 分隔线铺满整宽并延伸到窗口底（含安全区）；控件在 600 列内居中，
/// 内边距 上 12 / 左右 16 / 下 max(安全区, 16)（安全区本身已让出，不足 16 时补齐，不叠加）。
struct ProductBottomBarShell<Content: View>: View {
    @ViewBuilder let content: Content
    /// 页面量到的底部安全区（同一次布局里取，不在布局后再挪动底栏）。
    @Environment(\.productSafeAreaBottom) private var safeBottom

    var body: some View {
        content
            .frame(maxWidth: ProductLayout.maxContentWidth)
            .couliProbe("product.bottomBar.content", role: "column")
            .padding(.top, CouliSpacing.s3)
            .padding(.horizontal, CouliSpacing.s4)
            .padding(.bottom, max(CouliSpacing.s4 - safeBottom, 0))
            .frame(maxWidth: .infinity)
            .background(
                CouliColor.backgroundSurface
                    .overlay(alignment: .top) {
                        Rectangle().fill(CouliColor.borderSubtle).frame(height: CouliComponentMetric.controlBorderWidth)
                    }
                    .couliProbe("product.bottomBar", role: "bar")
                    .ignoresSafeArea(edges: .bottom)
            )
    }
}

extension EnvironmentValues {
    /// 页面内容区的底部安全区（ProductDetailScreen 用 GeometryReader 量到后放进环境）。
    @Entry var productSafeAreaBottom: CGFloat = 0
}

/// 底栏排法（G-D13）：入口 + 间距 8 + 主按钮单行自然宽放得下时同一行（主按钮占余宽）；放不下时改两行——上行入口左对齐、
/// 下行主按钮通栏（按钮字可折行、不省略，最小高随内容）。按测量判定，不按字号档位写死。只有一个子项时就是通栏按钮。
struct ProductBottomBarLayout: Layout {
    var spacing: CGFloat = CouliSpacing.s2

    private func oneRow(_ subviews: Subviews, width: CGFloat) -> Bool {
        guard subviews.count == 2 else { return false }
        let entry = subviews[0].sizeThatFits(.unspecified)
        let button = subviews[1].sizeThatFits(.unspecified)
        return entry.width + spacing + button.width <= width + 0.5
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let last = subviews.last else { return .zero }
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
            + spacing * CGFloat(max(subviews.count - 1, 0))
        guard subviews.count == 2 else {
            return CGSize(width: width, height: last.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
        }
        let entry = subviews[0].sizeThatFits(.unspecified)
        if oneRow(subviews, width: width) {
            let button = last.sizeThatFits(ProposedViewSize(width: width - entry.width - spacing, height: nil))
            return CGSize(width: width, height: max(entry.height, button.height))
        }
        let button = last.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: entry.height + spacing + button.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let last = subviews.last else { return }
        guard subviews.count == 2 else {
            last.place(at: bounds.origin, anchor: .topLeading,
                       proposal: ProposedViewSize(width: bounds.width, height: nil))
            return
        }
        let entry = subviews[0].sizeThatFits(.unspecified)
        if oneRow(subviews, width: bounds.width) {
            let buttonWidth = bounds.width - entry.width - spacing
            let button = last.sizeThatFits(ProposedViewSize(width: buttonWidth, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY - entry.height / 2), anchor: .topLeading,
                              proposal: ProposedViewSize(entry))
            last.place(at: CGPoint(x: bounds.minX + entry.width + spacing, y: bounds.midY - button.height / 2),
                       anchor: .topLeading, proposal: ProposedViewSize(width: buttonWidth, height: nil))
        } else {
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(entry))
            last.place(at: CGPoint(x: bounds.minX, y: bounds.minY + entry.height + spacing), anchor: .topLeading,
                       proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// 底栏左侧竖排入口（画板：图标 24 + 12 次文字，间距 2，48 × 48；命中区 ≥ 44）。
struct ProductBarEntry: View {
    let icon: CouliIcon
    let title: String
    let probeID: String
    let action: () -> Void
    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = CouliTextStyle.caption.baseSize

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                CouliIconView(icon, size: CouliSpacing.s6)
                    .foregroundColor(CouliColor.textPrimary)
                    .couliProbe(probeID + ".icon", role: "icon")
                Text(verbatim: title)
                    .couliFont(.caption)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize()
                    .couliTextProbe(probeID + ".label", role: "text", text: title, fontSize: labelSize,
                                    baseFontSize: CouliTextStyle.caption.baseSize)
            }
            .frame(minWidth: CouliSpacing.s12, minHeight: CouliSpacing.s12)
            .contentShape(Rectangle())
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
        .couliProbe(probeID, role: "hit")
    }
}

// MARK: - 比价无返利原因行

/// 比价无返利原因行（ProductPriceCompareCancelled-v2，§2.3）：在价格大卡内、返利标签的位置——灰胶囊（高 32）+ 强调色文字按钮
/// 【看看相似商品】。行高只由胶囊与按钮可见文字决定；按钮命中区（≥ 44 × 44）以可见文字为中心叠在上面、向外对称溢出，不参与排版
/// （画板 `margin: -6px 0`；评审 r1 S2-4-1：200% 下也不撑高行）。折行时行距 12，溢出的命中区压不到上一行的胶囊。
struct ProductCompareReasonRow: View {
    let reason: String
    let similarTitle: String
    let onSimilar: () -> Void

    var body: some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s3) {
            ProductStatusCapsule(reason)
                .couliProbe("product.compareReason.capsule", role: "capsule")
            Text(verbatim: similarTitle)
                .couliFont(.footnote, weight: .couliSemibold)
                .foregroundColor(CouliColor.textLink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, CouliSpacing.s2)
                .couliProbe("product.similar.label", role: "text", text: similarTitle)
                .accessibilityHidden(true)
                .overlay {
                    Button(action: onSimilar) {
                        Color.clear
                            .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.button))
                    .couliProbe("product.similar", role: "hit")
                    .accessibilityLabel(Text(verbatim: similarTitle))
                    .accessibilityIdentifier("product.similar")
                }
        }
        .couliProbe("product.compareReason", role: "compare-row")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("product.compareReason")
    }
}

// MARK: - 加载骨架

/// 加载骨架（§2.7，GUIDE §3 骨架）：按真实布局摆——头图块（同比例）+ 价格卡块（价格行 40%、返利块、标题两行 100% / 70%）
/// + 底栏按钮块；不画金额占位字，「加载中」只作读屏播报、不显示可见文字。
struct ProductDetailSkeleton: View {
    let accessibilityLabel: String

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                    RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous)
                        .fill(CouliColor.backgroundPlaceholder)
                        .aspectRatio(ProductDetailHero.aspectRatio, contentMode: .fit)
                        .couliProbe("product.skeleton.hero", role: "skeleton")
                    card
                }
                .frame(maxWidth: ProductLayout.maxContentWidth)
                .padding(.top, CouliSpacing.s2)
                .padding(.horizontal, CouliSpacing.s4)
                .padding(.bottom, CouliSpacing.s4)
                .frame(maxWidth: .infinity)
            }
            .scrollDisabled(true)
            ProductBottomBarShell {
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .fill(CouliColor.backgroundMuted)
                    .frame(height: CouliComponentMetric.buttonMinHeight)
                    .couliProbe("product.skeleton.button", role: "skeleton")
            }
        }
        .accessibilityHidden(true)
        .overlay {
            // 只作读屏播报的一项（没有可见文字）
            Color.clear
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: accessibilityLabel))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var card: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                block(width * 0.4, CouliSpacing.s10, "price")
                block(width * 0.55, CouliSpacing.s8, "rebate")
                block(width, CouliSpacing.s5, "title1")
                block(width * 0.7, CouliSpacing.s5, "title2")
            }
        }
        .frame(height: CouliSpacing.s10 + CouliSpacing.s8 + CouliSpacing.s5 * 2 + CouliSpacing.s3 * 3)
        .couliCard()
        .couliProbe("product.skeleton.card", role: "skeleton")
    }

    private func block(_ width: CGFloat, _ height: CGFloat, _ id: String) -> some View {
        SkeletonBlock(width: width, height: height)
            .couliProbe("product.skeleton." + id, role: "skeleton")
    }
}
