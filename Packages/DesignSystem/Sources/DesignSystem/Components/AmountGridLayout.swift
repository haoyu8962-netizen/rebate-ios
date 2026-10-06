import SwiftUI

// 金额文字（分段排版、独立金额小字）与数字格两列布局（AmountGrid、WalletHeroCard、HeroAmountRow 共用）。

/// 独立的金额小字（如「其中 ¥4.56 暂缓入账」）：显示走 `AmountNote.display(hidden:)`，读屏走
/// `AmountNote.spoken(hidden:)`（隐藏时读「其中 金额已隐藏 暂缓入账」），不让含金额的文字绕过隐藏与读屏通道。
public struct AmountNoteText: View {
    private let note: AmountNote
    private let hidden: Bool
    private let style: CouliTextStyle
    private let weight: Font.Weight

    public init(_ note: AmountNote, hidden: Bool, style: CouliTextStyle = .footnote, weight: Font.Weight = .regular) {
        self.note = note
        self.hidden = hidden
        self.style = style
        self.weight = weight
    }

    public var body: some View {
        Text(verbatim: note.display(hidden: hidden))
            .couliFont(style, weight: weight, monospacedDigits: true)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Text(verbatim: note.spoken(hidden: hidden)))
    }
}

/// 金额文字：按不可拆分段排（区间只在破折号处折行）；单段比可用宽度还宽时段内折行（不截断、不缩字号）。
struct AmountText: View {
    let parts: [String]
    let style: CouliTextStyle
    let weight: Font.Weight

    init(_ value: AmountValue, hidden: Bool, style: CouliTextStyle, weight: Font.Weight) {
        parts = value.displayParts(hidden: hidden)
        self.style = style
        self.weight = weight
    }

    var body: some View {
        CouliFlowLayout(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                BreakableText(part, style: style, weight: weight)
            }
        }
    }

    /// 隐形探针：各段叠放，宽度 = 最宽一段的自然宽度（数字格判断两列放不放得下）。
    static func widestPartProbe(_ parts: [String], style: CouliTextStyle) -> some View {
        ZStack {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(verbatim: part)
                    .couliFont(style, weight: .couliBold, monospacedDigits: true)
                    .fixedSize()
            }
        }
        .hidden()
        .accessibilityHidden(true)
    }
}

/// 数字格子视图的角色：格本身，或量宽探针。
enum AmountGridRole: LayoutValueKey {
    case cell(stackFirst: Bool)
    case probe(cell: Int)

    static let defaultValue = AmountGridRole.cell(stackFirst: false)
}

/// 数字格布局：每列宽度放得下该列最宽的不可拆分金额段时等宽两列并排（格内自行折行，区间在破折号处折），
/// 否则上下排、返利格在上（adaptation-a11y-spec §2 第 7 条与第三轮数字格规则）。
struct AmountGridLayout: Layout {
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat
    let forceStacked: Bool

    private struct Parts {
        var cells: [LayoutSubview] = []
        var stackFirst: [Bool] = []
        var probes: [LayoutSubview] = []

        var stackedCells: [LayoutSubview] {
            cells.indices.filter { stackFirst[$0] }.map { cells[$0] }
                + cells.indices.filter { !stackFirst[$0] }.map { cells[$0] }
        }
    }

    private func split(_ subviews: Subviews) -> Parts {
        var parts = Parts()
        for subview in subviews {
            switch subview[AmountGridRole.self] {
            case let .cell(first):
                parts.cells.append(subview)
                parts.stackFirst.append(first)
            case .probe:
                parts.probes.append(subview)
            }
        }
        return parts
    }

    static func columnWidth(_ width: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        (width - spacing * CGFloat(max(count - 1, 0))) / CGFloat(max(count, 1))
    }

    /// 并排条件：未强制上下排，且每格最宽的不可拆分段放得进一列（0.5pt 容差同 CouliFlowLayout）。
    static func fitsSideBySide(columnWidth: CGFloat, widestParts: [CGFloat], forceStacked: Bool) -> Bool {
        !forceStacked && widestParts.allSatisfy { $0 <= columnWidth + 0.5 }
    }

    private func sideBySide(_ width: CGFloat?, _ parts: Parts) -> Bool {
        guard let width, width.isFinite else {
            return !forceStacked
        }
        return Self.fitsSideBySide(
            columnWidth: Self.columnWidth(width, count: parts.cells.count, spacing: columnSpacing),
            widestParts: parts.probes.map { $0.sizeThatFits(.unspecified).width },
            forceStacked: forceStacked
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let parts = split(subviews)
        guard !parts.cells.isEmpty else {
            return .zero
        }
        let count = CGFloat(parts.cells.count)
        if sideBySide(proposal.width, parts) {
            guard let width = proposal.width, width.isFinite else {
                let sizes = parts.cells.map { $0.sizeThatFits(.unspecified) }
                let widest = sizes.map(\.width).max() ?? 0
                return CGSize(
                    width: widest * count + columnSpacing * (count - 1),
                    height: sizes.map(\.height).max() ?? 0
                )
            }
            let column = ProposedViewSize(
                width: Self.columnWidth(width, count: parts.cells.count, spacing: columnSpacing),
                height: nil
            )
            return CGSize(width: width, height: parts.cells.map { $0.sizeThatFits(column).height }.max() ?? 0)
        }
        let row = ProposedViewSize(width: proposal.width, height: nil)
        let sizes = parts.cells.map { $0.sizeThatFits(row) }
        let height = sizes.map(\.height).reduce(0, +) + rowSpacing * (count - 1)
        return CGSize(width: proposal.width ?? (sizes.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let parts = split(subviews)
        for probe in parts.probes {
            probe.place(at: bounds.origin, proposal: .unspecified)
        }
        if sideBySide(bounds.width, parts) {
            let width = Self.columnWidth(bounds.width, count: parts.cells.count, spacing: columnSpacing)
            for (index, cell) in parts.cells.enumerated() {
                cell.place(
                    at: CGPoint(x: bounds.minX + CGFloat(index) * (width + columnSpacing), y: bounds.minY),
                    proposal: ProposedViewSize(width: width, height: nil)
                )
            }
            return
        }
        var originY = bounds.minY
        let row = ProposedViewSize(width: bounds.width, height: nil)
        for cell in parts.stackedCells {
            cell.place(at: CGPoint(x: bounds.minX, y: originY), proposal: row)
            originY += cell.sizeThatFits(row).height + rowSpacing
        }
    }
}
