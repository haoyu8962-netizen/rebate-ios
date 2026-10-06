import Generated
import SwiftUI

/// 组件尺寸（pt），对应 tokens.component。
public enum CouliComponentMetric {
    /// 主按钮最小高（大字号时继续增高）。
    public static let buttonMinHeight = metric(DesignTokens.component, "button.min-height", group: "component")
    public static let buttonPaddingInline = metric(DesignTokens.component, "button.padding-inline", group: "component")
    public static let buttonPaddingBlock = metric(DesignTokens.component, "button.padding-block", group: "component")
    public static let buttonGap = metric(DesignTokens.component, "button.gap", group: "component")
    /// 输入框、紧凑按钮等控件的最小高。
    public static let controlMinHeight = metric(DesignTokens.component, "control.min-height", group: "component")
    public static let controlBorderWidth = metric(DesignTokens.component, "control.border-width", group: "component")
    /// 图标默认尺寸。
    public static let iconDefault = metric(DesignTokens.component, "icon.default", group: "component")
}

/// 焦点环（pt），对应 tokens.focus。
public enum CouliFocus {
    public static let width = metric(DesignTokens.focus, "width", group: "focus")
    public static let offset = metric(DesignTokens.focus, "offset", group: "focus")
}

/// 阴影令牌（tokens.shadow）。
public enum CouliShadow: String, Sendable, CaseIterable {
    case none
    case card
    case floating

    var layers: [DesignTokens.ShadowLayer] {
        guard let layers = DesignTokens.shadows[rawValue] else {
            assertionFailure("missing token shadow.\(rawValue)")
            return []
        }
        return layers
    }
}

private struct CouliShadowModifier: ViewModifier {
    let shadow: CouliShadow

    func body(content: Content) -> some View {
        // 令牌目前每档至多一层；多层时依次叠加。
        shadow.layers.reduce(AnyView(content)) { view, layer in
            AnyView(
                view.shadow(
                    color: (TokenRGB(hex: layer.color)?.color ?? .clear).opacity(layer.opacity),
                    // CSS blur 半径 ≈ 2 × SwiftUI radius。
                    radius: CGFloat(layer.blur) / 2,
                    x: CGFloat(layer.x),
                    y: CGFloat(layer.y)
                )
            )
        }
    }
}

public extension View {
    /// 套用阴影令牌。
    func couliShadow(_ shadow: CouliShadow) -> some View {
        modifier(CouliShadowModifier(shadow: shadow))
    }
}

/// 遮罩：墨棕按令牌规定的不透明度（GUIDE §2：rgba(40, 37, 31, 0.4)）。
/// TODO(N-11): 令牌补 overlay.scrim 后改读令牌。
public enum CouliScrim {
    public static let opacity = 0.4
    public static var color: Color {
        CouliColor.textPrimary.opacity(opacity)
    }
}

/// 设计稿（GUIDE §3、§6、§7）规定、但令牌里还没有的尺寸。集中在这里，组件不散写数字。
/// 能由间距令牌组合出的直接组合；其余三项（14、22、2）待令牌补齐。
/// TODO(N-11): 令牌补 component.tag / icon.small 等后改读令牌。
public enum CouliGuideMetric {
    /// 小图标（标签里的钟表、对勾，GUIDE §3）。
    public static let iconSmall: CGFloat = 14
    /// 行内图标（口径 i、说明行，GUIDE §7.2.1）。
    public static let iconInline = CouliSpacing.s4
    /// 中号图标（提示条，GUIDE §3）。
    public static let iconMedium = CouliSpacing.s5
    /// 胶囊标签最小高（GUIDE §3 标签 height 22，放大时改为最小高）。
    public static let tagMinHeight: CGFloat = 22
    /// 胶囊标签上下内边距（GUIDE §7.2.1 返利标签 padding 2px 8px）。
    public static let tagPaddingVertical: CGFloat = 2
    /// 平台来源标签最小高（GUIDE §7.2.1 高 20）。
    public static let badgeMinHeight = CouliSpacing.s5
    /// 列表卡左图边长（96）。
    public static let listImage = CouliSpacing.s12 * 2
    /// 网格卡图片高宽比（GUIDE §6「157×132 网格卡」）。
    public static let gridImageAspect: CGFloat = 132.0 / 157.0
    /// 宫格格子最小高（≥72，GUIDE §7.2）。
    public static let gridCellMinHeight = CouliSpacing.s12 + CouliSpacing.s6
    /// 空态占位块边长（96）与其中图标（32）。
    public static let emptyIllustration = CouliSpacing.s12 * 2
    public static let emptyIcon = CouliSpacing.s8
    /// 半屏把手 36×4。
    public static let sheetHandleWidth = CouliSpacing.s8 + CouliSpacing.s1
    public static let sheetHandleHeight = CouliSpacing.s1
}
