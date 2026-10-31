import DesignSystem
import SwiftUI

// 二次验证半屏的页面私有件（APP-09v-d，W63–W67）。只画，不持有状态、不接回调。

enum StepUpMetric {
    /// 面板上内边距（画板 20）。
    static let topInset: CGFloat = 20
    static let handleWidth: CGFloat = 36
    static let handleHeight: CGFloat = 4
    /// 组件令牌格高 56（不取画板 52，brief §2.4）、格间距 8（Login 版 12，所以不共用）、数字 28/600（画板）。
    static let cellHeight: CGFloat = 56
    static let cellFont: CGFloat = 28
    /// 数字到格边的最小留白（每侧）；数字宽约 0.62 字号（等宽数字）。
    static let cellInset: CGFloat = 4
    static let digitWidth: CGFloat = 0.62
    static let minimumDigit: CGFloat = 12
    /// iOS 26 部分高度的半屏按 宽 − 16 ÷ 宽 整体缩小（`UIDropShadowView` 变换，约 0.96，真机同样）：逻辑 44 落到屏上只有 42。
    /// 命中区是摸得到的尺寸，按屏上 ≥ 44 留；视觉尺寸仍按令牌。
    static let hitTarget: CGFloat = 46
    /// 【重新获取】命中区伸出视觉行的量：(46 − 21) / 2 向上取整。
    static let hitBleed: CGFloat = 13
    /// 格高 + 格下间距 12 + 一行 21 + 留给命中区的 13。
    static let middleMinimum: CGFloat = 102
    /// 输入框几乎透明但仍可命中（完全透明的视图不接收点按）。
    static let inputOpacity = 0.02
    static let cellCount = 6
    /// 可用高度变化后等多久才切排版（盖住键盘起落动画）。
    static let settleNanos: UInt64 = 400_000_000
}

/// 把手（W63）：36×4 全圆角、border.subtle。纯装饰：不接手势、不进读屏树。
struct StepUpHandle: View {
    var body: some View {
        Capsule()
            .fill(CouliColor.borderSubtle)
            .frame(width: StepUpMetric.handleWidth, height: StepUpMetric.handleHeight)
            .walletProbe("stepUp.handle", role: "handle")
            .accessibilityHidden(true)
    }
}

/// 6 格（W66）：格宽按可用宽均分，格高只增不减，数字随字号放大但不超过格子容纳得下的大小。当前格 2 描边、其余 1；
/// 输入控件在调用方，这里整体不进读屏树。
struct StepUpCodeCells: View {
    let code: String
    /// 能输入时才有当前格（验证中、取不到号码时没有）。
    let active: Bool
    let hasError: Bool
    @State private var width: CGFloat = 0
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = StepUpMetric.cellFont

    private var fontSize: CGFloat {
        guard width > 0 else { return size }
        let count: CGFloat = 6
        let cell = (width - CouliSpacing.s2 * (count - 1)) / count
        return max(StepUpMetric.minimumDigit,
                   min(size, (cell - StepUpMetric.cellInset * 2) / StepUpMetric.digitWidth))
    }

    var body: some View {
        let digits = Array(code)
        let font = fontSize
        let height = max(StepUpMetric.cellHeight, font * 1.3 + StepUpMetric.cellInset * 2)
        HStack(spacing: CouliSpacing.s2) {
            ForEach(0..<StepUpMetric.cellCount, id: \.self) { index in
                let digit = index < digits.count ? String(digits[index]) : ""
                cell(digit, font: font, height: height, current: active && index == digits.count)
                    .couliTextProbe("stepUp.cell.\(index)", role: "cell", text: digit, fontSize: font,
                                    baseFontSize: StepUpMetric.cellFont)
                    // 框不变、只有数字变时测量不重报（实测），换数字换实例
                    .id(digit)
            }
        }
        .walletProbe("stepUp.cells", role: "cells")
        .accessibilityHidden(true)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { width = $0 }
        })
    }

    private func cell(_ digit: String, font: CGFloat, height: CGFloat, current: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
        return Text(verbatim: digit)
            .font(.system(size: font, weight: .couliSemibold).monospacedDigit())
            .foregroundColor(CouliColor.textPrimary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(shape.fill(CouliColor.backgroundSurface))
            .overlay(shape.strokeBorder(
                current ? CouliColor.textPrimary : (hasError ? CouliColor.statusErrorText : CouliColor.borderControl),
                lineWidth: current ? CouliFocus.width : CouliComponentMetric.controlBorderWidth
            ))
    }
}

/// 格下一行（W67）：两段放得下同一行时左贴左、右贴右；放不下（大字号 + 长错误）时错误占满整行、右段换到下一行靠右，
/// 不把错误挤成一字一行（Android r1 S2-2）。子视图恰两个：左段、右段。
struct StepUpStatusLayout: Layout {
    private struct Slots {
        var stacked = false
        var left = CGSize.zero
        var right = CGSize.zero
    }

    private func slots(_ subviews: Subviews, width: CGFloat?) -> Slots {
        guard subviews.count == 2 else { return Slots() }
        let leftIdeal = subviews[0].sizeThatFits(.unspecified)
        let rightIdeal = subviews[1].sizeThatFits(.unspecified)
        guard let width else { return Slots(left: leftIdeal, right: rightIdeal) }
        let filled = leftIdeal.width > 0 && rightIdeal.width > 0
        let need = leftIdeal.width + rightIdeal.width + (filled ? CouliSpacing.s3 : 0)
        if need <= width {
            return Slots(left: leftIdeal, right: rightIdeal)
        }
        let proposal = ProposedViewSize(width: width, height: nil)
        return Slots(stacked: filled, left: subviews[0].sizeThatFits(proposal),
                     right: subviews[1].sizeThatFits(proposal))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let slots = slots(subviews, width: proposal.width)
        let height = slots.stacked ? slots.left.height + CouliSpacing.s1 + slots.right.height
            : max(slots.left.height, slots.right.height)
        return CGSize(width: proposal.width ?? slots.left.width + slots.right.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard subviews.count == 2 else { return }
        let slots = slots(subviews, width: bounds.width)
        subviews[0].place(at: bounds.origin, proposal: .init(slots.left))
        let top = slots.stacked ? bounds.minY + slots.left.height + CouliSpacing.s1 : bounds.minY
        subviews[1].place(at: CGPoint(x: bounds.maxX - slots.right.width, y: top), proposal: .init(slots.right))
    }
}
