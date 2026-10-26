import DesignSystem
import Generated
import OrderCore
import SwiftUI
import UIKit

// APP-08v-a 订单列表的小部件（brief §2.1–§2.3）：带测量的文字、状态胶囊、单号 +【复制】排法、两列金额格。
// 测量只在有接收方（Debug 测试宿主）时上报，Release 没有接收方、不多画任何视图。

/// 令牌文字 + 测量（实际字号随系统字号缩放，与 `couliFont` 同一缩放曲线）。`probeID` 为 nil 时不量。
struct OrderProbedText: View {
    let text: String
    let style: CouliTextStyle
    var weight: Font.Weight = .regular
    var monospacedDigits = false
    var probeID: String?
    @ScaledMetric private var size: CGFloat

    init(_ text: String, style: CouliTextStyle, weight: Font.Weight = .regular, monospacedDigits: Bool = false,
         probeID: String? = nil) {
        self.text = text
        self.style = style
        self.weight = weight
        self.monospacedDigits = monospacedDigits
        self.probeID = probeID
        _size = ScaledMetric(wrappedValue: style.baseSize, relativeTo: style.relativeTo)
    }

    var body: some View {
        let label = Text(verbatim: text).couliFont(style, weight: weight, monospacedDigits: monospacedDigits)
        if let probeID {
            label.couliTextProbe(probeID, role: "text", text: text, fontSize: size, baseFontSize: style.baseSize)
        } else {
            label
        }
    }
}

extension View {
    /// 可选编号的测量（nil 不量）。
    @ViewBuilder
    func orderProbe(_ id: String?, role: String = "box") -> some View {
        if let id {
            couliProbe(id, role: role)
        } else {
            self
        }
    }
}

// MARK: - 状态胶囊

/// 状态胶囊的图标（纯视图映射，brief §2.2）：预估类钟表；INVALID / NO_REBATE / 未知用 i；CLAWED_BACK 警告三角；已结算圆圈对勾。
enum OrderStatusIcon {
    static func icon(_ status: DisplayStatus) -> CouliIcon {
        switch status {
        case .credited, .creditedPartClawed: .check
        case .clawedBack: .alert
        case .invalid, .noRebate, .unknown: .info
        default: .clock
        }
    }

    /// 已结算（CREDITED / CREDITED_PART_CLAWED）用松叶绿成功色，其余中性。
    static func settled(_ status: DisplayStatus) -> Bool {
        status == .credited || status == .creditedPartClawed
    }
}

/// 列表卡的状态胶囊：高 22（最小高，随字号增高）、左右 8、圆角满、12 字 + 14 图标；中性次要底 + 次文字，已结算成功底 + 成功字。
struct OrderStatusPill: View {
    let summary: OrderSummary
    let texts: OrderTexts
    let hidden: Bool
    let probe: String

    var body: some View {
        let status = summary.displayStatus
        let settled = OrderStatusIcon.settled(status)
        HStack(alignment: .center, spacing: CouliSpacing.s1) {
            CouliIconView(OrderStatusIcon.icon(status), size: CouliGuideMetric.iconSmall, relativeTo: .caption)
                .couliProbe(probe + ".icon", role: "icon")
            OrderProbedText(OrderStatusLine.label(summary, texts: texts, hidden: hidden), style: .caption,
                            probeID: probe + ".label")
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(settled ? CouliColor.statusSuccessText : CouliColor.textSecondary)
        .padding(.horizontal, CouliSpacing.s2)
        .frame(minHeight: CouliGuideMetric.tagMinHeight)
        .background(Capsule().fill(settled ? CouliColor.statusSuccessBackground : CouliColor.backgroundMuted))
        .couliProbe(probe, role: "pill")
    }
}

// MARK: - 单号 +【复制】

/// 单号逐字排、【复制】紧跟单号末行文字（间距 8）；末行放不下时整体换到下一行的列起点（不停在多行中部，Android a 评审 r1 S2-2）。
/// 子视图顺序：单号各字…、单号测量框、【复制】可见文字、【复制】命中区（44，居中盖住可见文字，不参与行高）。
struct OrderNumberFlowLayout: Layout {
    let characters: Int
    let hasCopy: Bool
    let spacing: CGFloat
    let lineGap: CGFloat

    private struct Plan {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var numberBounds = CGRect.zero
        var copy = CGRect.zero
        var size = CGSize.zero
    }

    /// 一行：各字下标、基线以上最高、基线以下最深。
    private struct Line {
        var items: [Int] = []
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
    }

    private func breakLines(_ subviews: Subviews, width: CGFloat) -> ([Line], [ViewDimensions]) {
        var result: [Line] = []
        var current = Line()
        var dimensions: [ViewDimensions] = []
        for index in 0..<characters {
            let item = subviews[index].dimensions(in: .unspecified)
            dimensions.append(item)
            if !current.items.isEmpty, current.width + item.width > width + 0.5 {
                result.append(current)
                current = Line()
            }
            current.items.append(index)
            current.width += item.width
            current.ascent = max(current.ascent, item[.firstTextBaseline])
            current.descent = max(current.descent, item.height - item[.firstTextBaseline])
        }
        result.append(current)
        return (result, dimensions)
    }

    private func plan(_ subviews: Subviews, width: CGFloat) -> Plan {
        var plan = Plan()
        let (lines, dimensions) = breakLines(subviews, width: width)
        plan.origins = Array(repeating: .zero, count: characters)
        plan.sizes = dimensions.map { CGSize(width: $0.width, height: $0.height) }
        var top: CGFloat = 0
        var lastTop: CGFloat = 0
        for (number, line) in lines.enumerated() {
            if number > 0 {
                top += lineGap
            }
            lastTop = top
            var cursor: CGFloat = 0
            for index in line.items {
                plan.origins[index] = CGPoint(x: cursor, y: top + line.ascent - dimensions[index][.firstTextBaseline])
                cursor += dimensions[index].width
            }
            top += line.ascent + line.descent
        }
        let last = lines.last ?? Line()
        plan.numberBounds = CGRect(x: 0, y: 0, width: lines.map(\.width).max() ?? 0, height: top)
        plan.size = plan.numberBounds.size
        guard hasCopy else { return plan }
        let label = subviews[characters + 1].dimensions(in: .unspecified)
        if last.width + spacing + label.width <= width + 0.5 {
            plan.copy = CGRect(x: last.width + spacing, y: lastTop + last.ascent - label[.firstTextBaseline],
                               width: label.width, height: label.height)
        } else {
            plan.copy = CGRect(x: 0, y: top + lineGap, width: label.width, height: label.height)
        }
        plan.size = CGSize(width: max(plan.numberBounds.width, plan.copy.maxX),
                           height: max(plan.numberBounds.maxY, plan.copy.maxY))
        return plan
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        plan(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let plan = plan(subviews, width: bounds.width)
        let origin = bounds.origin
        for index in 0..<characters {
            subviews[index].place(at: CGPoint(x: origin.x + plan.origins[index].x, y: origin.y + plan.origins[index].y),
                                  proposal: ProposedViewSize(plan.sizes[index]))
        }
        subviews[characters].place(at: origin, proposal: ProposedViewSize(plan.numberBounds.size))
        guard hasCopy else { return }
        let label = plan.copy.offsetBy(dx: origin.x, dy: origin.y)
        subviews[characters + 1].place(at: label.origin, proposal: ProposedViewSize(label.size))
        let hit = CGSize(
            width: max(CouliHitTarget.minimum, label.width),
            height: max(CouliHitTarget.minimum, label.height)
        )
        subviews[characters + 2].place(at: CGPoint(x: label.midX, y: label.midY), anchor: .center,
                                       proposal: ProposedViewSize(hit))
    }
}

/// 列表卡右列的「订单号 {no}」+【复制】（brief §2.2）：单号 12 次文字等宽数字；自购单【复制】12 强调色紧随、命中区 44（不撑高行）；
/// 分享单只显示脱敏原样、没有【复制】。整卡读屏另由卡片给出，这里的文字不单独进读屏；【复制】是独立的第二个目标。
struct OrderListNumber: View {
    let summary: OrderSummary
    let texts: OrderTexts
    let probe: String
    let onCopy: (String) -> Void
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = CouliTextStyle.caption.baseSize

    var body: some View {
        let number = OrderNumberDisplay.view(summary)
        if let raw = number.text {
            let text = texts.format(OrderKeys.orderNo, ["no": raw])
            let characters = text.map { String($0) }
            let lineGap = max(size * CouliTextStyle.caption.lineHeightMultiple - Self.lineHeight(size), 0)
            OrderNumberFlowLayout(characters: characters.count, hasCopy: number.copyable,
                                  spacing: CouliSpacing.s2, lineGap: lineGap) {
                ForEach(Array(characters.enumerated()), id: \.offset) { _, character in
                    Text(verbatim: character).couliFont(.caption, monospacedDigits: true)
                        .accessibilityHidden(true)
                }
                Color.clear
                    .accessibilityHidden(true)
                    .couliTextProbe(probe + ".number", role: "text", text: text, fontSize: size,
                                    baseFontSize: CouliTextStyle.caption.baseSize)
                if number.copyable {
                    OrderProbedText(texts.text(OrderKeys.copy), style: .caption, probeID: probe + ".copy.label")
                        .foregroundColor(CouliColor.brandEmphasis)
                        .fixedSize()
                        .accessibilityHidden(true)
                    copyButton(raw)
                }
            }
            .foregroundColor(CouliColor.textSecondary)
        }
    }

    private func copyButton(_ raw: String) -> some View {
        Button {
            onCopy(raw)
        } label: {
            Color.clear
                .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .couliProbe(probe + ".copy", role: "hit")
        .accessibilityLabel(Text(verbatim: texts.text(OrderKeys.copyLabel)))
        .accessibilityIdentifier("order.copy")
    }

    /// 字体自身行高（中文落到苹方，同 DesignSystem 行距算法）。
    static func lineHeight(_ size: CGFloat) -> CGFloat {
        (UIFont(name: "PingFangSC-Regular", size: size) ?? UIFont.systemFont(ofSize: size)).lineHeight
    }
}
