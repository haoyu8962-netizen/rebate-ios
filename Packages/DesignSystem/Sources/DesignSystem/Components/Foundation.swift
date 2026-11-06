import SwiftUI

// 组件共用的基础件：换行布局、图标、字重、卡片外观。

// MARK: - 字重

public extension Font.Weight {
    /// 令牌 font.weight.medium（500）。
    static let couliMedium = CouliFontWeight.medium.fontWeight
    /// 令牌 font.weight.semibold（600）。
    static let couliSemibold = CouliFontWeight.semibold.fontWeight
    /// 令牌 font.weight.bold（700，只给少量核心数值）。
    static let couliBold = CouliFontWeight.bold.fontWeight
}

// MARK: - 换行布局（CSS flex-wrap 的等价物）

/// 从左到右排，放不下就整块换到下一行（不压缩、不截断子项）。
/// 子项可用 `couliFlowPushTrailing()` 标记为「靠右」（CSS `margin-left: auto`）：在所在行贴右；
/// 换到新行时同样贴右（GUIDE §7.2.1「按钮整块换到下一行靠右」）。
public struct CouliFlowLayout: Layout {
    public var horizontalSpacing: CGFloat
    public var verticalSpacing: CGFloat

    public init(horizontalSpacing: CGFloat, verticalSpacing: CGFloat) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    private struct Item {
        let index: Int
        let size: CGSize
        let push: CouliFlowPush
    }

    private struct Line {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(for subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var result: [Line] = []
        var current = Line()
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            let item = Item(index: index, size: size, push: subview[CouliFlowTrailingKey.self])
            let needed = current.items.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            // 0.5pt 容差：避免浮点误差让刚好放得下的项被挤到下一行。
            if !current.items.isEmpty, needed > maxWidth + 0.5 {
                result.append(current)
                current = Line()
            }
            current.width = current.items.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            current.height = max(current.height, size.height)
            current.items.append(item)
        }
        if !current.items.isEmpty {
            result.append(current)
        }
        return result
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = lines(for: subviews, maxWidth: maxWidth)
        let height = lines.map(\.height).reduce(0, +) + verticalSpacing * CGFloat(max(lines.count - 1, 0))
        let widest = lines.map(\.width).max() ?? 0
        let hasTrailing = subviews.contains { $0[CouliFlowTrailingKey.self] != .none }
        let width = hasTrailing && maxWidth.isFinite ? maxWidth : widest
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let lines = lines(for: subviews, maxWidth: bounds.width)
        var lineY = bounds.minY
        for line in lines {
            var cursorX = bounds.minX
            for item in line.items {
                var originX = cursorX
                let wrappedAlone = item.index == line.items.first?.index
                if item.push == .always || (item.push == .inlineOnly && !wrappedAlone) {
                    // 靠右：本项及其后各项贴到行尾。
                    let rest = line.items.filter { $0.index >= item.index }
                    let restWidth = rest.map(\.size.width).reduce(0, +)
                        + horizontalSpacing * CGFloat(max(rest.count - 1, 0))
                    originX = max(cursorX, bounds.maxX - restWidth)
                }
                subviews[item.index].place(
                    at: CGPoint(x: originX, y: lineY + (line.height - item.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                cursorX = originX + item.size.width + horizontalSpacing
            }
            lineY += line.height + verticalSpacing
        }
    }
}

/// `CouliFlowLayout` 里的靠右方式。
public enum CouliFlowPush: Sendable {
    case none
    /// 总是贴右（换到新行时也贴右，GUIDE §7.2.1 购买按钮）。
    case always
    /// 与前面的项同行时贴右；单独换到新行时靠左（adaptation-a11y-spec §2 钱包【提现】）。
    case inlineOnly
}

private struct CouliFlowTrailingKey: LayoutValueKey {
    static let defaultValue = CouliFlowPush.none
}

public extension View {
    /// 在 `CouliFlowLayout` 里靠右（CSS `margin-left: auto`）。
    func couliFlowPushTrailing(_ push: CouliFlowPush = .always) -> some View {
        layoutValue(key: CouliFlowTrailingKey.self, value: push)
    }
}

// MARK: - 图标

/// 线性图标。设计稿图标（GUIDE §4，1.75 线宽的行内 SVG）尚未导出为资源，暂用 SF Symbols 近似。
/// TODO(N-11): 图标资源到位后换成设计稿图标。
public enum CouliIcon: String, Sendable, CaseIterable {
    case back = "chevron.left"
    case chevron = "chevron.right"
    case chevronDown = "chevron.down"
    case close = "xmark"
    case search = "magnifyingglass"
    case clock
    case check = "checkmark.circle"
    case alert = "exclamationmark.triangle"
    case info = "info.circle"
    case help = "questionmark.circle"
    case eye
    case eyeOff = "eye.slash"
    case home = "house"
    case chat = "bubble.left"
    case orders = "doc.text"
    case user = "person"
    case wallet = "creditcard"
    case ledger = "list.bullet.rectangle"
    /// 柱状图（APP-09v 钱包「收益看板」入口，W14；折线 `trend` 不变）。
    case barChart = "chart.bar"
    case claim = "doc.text.magnifyingglass"
    case invite = "person.badge.plus"
    case heart
    case star
    case headset = "headphones"
    case link
    case settings = "gearshape"
    case trend = "chart.line.uptrend.xyaxis"
    case copy = "doc.on.doc"
    case bell
    /// 断网（APP-08v 断网提示条，brief §7「功能图标用系统图标集」）。
    case wifiOff = "wifi.slash"
    /// 盾牌对勾（APP-09v-e 实名头部方块、单独同意要点）。
    case shieldCheck = "checkmark.shield"

    var systemName: String {
        rawValue
    }
}

/// 图标视图：尺寸随字号适当放大（adaptation-a11y-spec §2：图标随字号适当放大，命中区下限不变）。
/// 图标默认是装饰（读屏忽略），含义由相邻文字或按钮名称表达。
public struct CouliIconView: View {
    private let icon: CouliIcon
    @ScaledMetric private var size: CGFloat

    public init(
        _ icon: CouliIcon,
        size: CGFloat = CouliComponentMetric.iconDefault,
        relativeTo: Font.TextStyle = .body
    ) {
        self.icon = icon
        _size = ScaledMetric(wrappedValue: size, relativeTo: relativeTo)
    }

    public var body: some View {
        Image(systemName: icon.systemName)
            .font(.system(size: size * 0.8, weight: .regular))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - 卡片外观

public extension View {
    /// 白卡片：surface 底、卡片圆角、卡片阴影。内边距由调用方给（列表卡 12，普通卡 16）。
    func couliCard(padding: CGFloat = CouliSpacing.s4) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // 阴影只给底板，不落到卡内文字上。
                RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                    .fill(CouliColor.backgroundSurface)
                    .couliShadow(.card)
            )
    }

    /// 命中区下限（令牌 interaction.target.ios），视觉尺寸不变。
    func couliHitTarget() -> some View {
        frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
            .contentShape(Rectangle())
    }
}

/// 只上两角圆角（半屏用）。
struct TopRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let corner = min(radius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + corner))
        path.addArc(
            center: CGPoint(x: rect.minX + corner, y: rect.minY + corner),
            radius: corner,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - corner, y: rect.minY + corner),
            radius: corner,
            startAngle: .degrees(270),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - 焦点环

/// 键盘 / 辅助输入焦点的可见样式（adaptation-a11y-spec §8）：2 宽 focus.ring 实线，距控件 focus.offset，圆角跟随控件。
/// 只在获得焦点时出现（触摸时不出现）。
struct CouliFocusRing: ViewModifier {
    let cornerRadius: CGFloat
    /// 狸橙实底上用白色描一圈底，保证焦点环对比。
    var onBrand = false
    /// 环画在控件框内（缺省 false = 框外留 focus.offset）。框外的环哪怕透明也算进无障碍框，比真实命中区每边大 4；
    /// 命中区贴着邻控件、滚动边的按钮用（APP-09v-d【重新获取】）。
    var inside = false
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius + CouliFocus.offset, style: .continuous)
                .strokeBorder(CouliColor.focusRing, lineWidth: CouliFocus.width)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius + CouliFocus.offset, style: .continuous)
                        .strokeBorder(onBrand ? CouliColor.backgroundSurface : .clear, lineWidth: CouliFocus.width * 2)
                )
                .padding(inside ? 0 : -CouliFocus.offset - CouliFocus.width)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        )
    }
}

/// 图标按钮、整格入口等的按钮样式：不加底色，按下时浅底，获得焦点时显示焦点环。
public struct CouliPlainButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    let onBrand: Bool
    let ringInside: Bool

    public init(cornerRadius: CGFloat = CouliRadius.small, onBrand: Bool = false, ringInside: Bool = false) {
        self.cornerRadius = cornerRadius
        self.onBrand = onBrand
        self.ringInside = ringInside
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(configuration.isPressed && !onBrand ? CouliColor.backgroundMuted : .clear)
            )
            .modifier(CouliFocusRing(cornerRadius: cornerRadius, onBrand: onBrand, inside: ringInside))
    }
}

// MARK: - 只在空格处折行的文字

/// 金额与带金额的短句：放得下就一行；放不下时只在空格处折行（「券前」「¥13345.67」）。
/// 含金额的小段整体不拆（不在数字中间或小数点前断开）；放不下整段时由外层改布局（列表卡价格区占整卡宽、
/// 网格卡改单列），不缩字号、不截断（03 §10.4）。不含金额的文字段照常折行。
struct BreakableText: View {
    let text: String
    let style: CouliTextStyle
    let weight: Font.Weight
    let monospacedDigits: Bool

    init(_ text: String, style: CouliTextStyle, weight: Font.Weight = .regular, monospacedDigits: Bool = true) {
        self.text = text
        self.style = style
        self.weight = weight
        self.monospacedDigits = monospacedDigits
    }

    /// 按空格切段，段后保留空格。
    static func pieces(_ text: String) -> [String] {
        let words = text.components(separatedBy: " ")
        return words.enumerated().compactMap { index, word in
            let piece = word + (index < words.count - 1 ? " " : "")
            return piece.isEmpty ? nil : piece
        }
    }

    /// 含金额（¥ 或数字）的段整体不拆。
    static func isAtomic(_ piece: String) -> Bool {
        piece.contains(PriceTerms.yuanSign) || piece.contains(where: \.isNumber)
    }

    var body: some View {
        CouliFlowLayout(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(Self.pieces(text).enumerated()), id: \.offset) { _, piece in
                Text(verbatim: piece)
                    .couliFont(style, weight: weight, monospacedDigits: monospacedDigits)
                    .fixedSize(horizontal: Self.isAtomic(piece), vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }
}

/// 问号说明按钮：图标 16，命中区 44（负外边距扩展，视觉位置不变），带焦点环。
struct HelpButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CouliIconView(.help, size: CouliComponentMetric.iconInline, relativeTo: .caption)
                .couliHitTarget()
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
        .padding(-CouliSpacing.s3)
        .accessibilityLabel(Text(verbatim: label))
    }
}
