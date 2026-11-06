import Generated
import SwiftUI
import UIKit

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
    /// 小图标（标签里的钟表、对勾）。
    public static let iconSmall = metric(DesignTokens.component, "icon.small", group: "component")
    /// 行内图标（口径 i、说明行）。
    public static let iconInline = metric(DesignTokens.component, "icon.inline", group: "component")
    /// 中号图标（提示条）。
    public static let iconMedium = metric(DesignTokens.component, "icon.medium", group: "component")
    /// 胶囊标签最小高（放大时继续增高）。
    public static let tagMinHeight = metric(DesignTokens.component, "tag.min-height", group: "component")
    /// 平台来源标签最小高。
    public static let badgeMinHeight = metric(DesignTokens.component, "platform-badge.min-height", group: "component")
    /// 列表卡左图边长。
    public static let listImage = metric(DesignTokens.component, "image.list", group: "component")
    /// 宫格格子最小高。
    public static let gridCellMinHeight = metric(DesignTokens.component, "grid-cell.min-height", group: "component")
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

    /// 浅色取 `DesignTokens.shadows`，深色取 `DesignTokens.shadowsDark`（深色为黑影，浅色为墨棕影）。
    func layers(dark: Bool) -> [DesignTokens.ShadowLayer] {
        guard let layers = (dark ? DesignTokens.shadowsDark : DesignTokens.shadows)[rawValue] else {
            assertionFailure("missing token shadow.\(rawValue)")
            return []
        }
        return layers
    }
}

private struct CouliShadowModifier: ViewModifier {
    let shadow: CouliShadow
    /// 按所在视图的外观取层：外观变化时 SwiftUI 重新求值 body，阴影跟着换。
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        // 令牌目前每档至多一层；多层时依次叠加。
        shadow.layers(dark: colorScheme == .dark).reduce(AnyView(content)) { view, layer in
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

/// 遮罩：令牌 overlay.scrim（浅色墨棕 40%，深色纯黑 55%；8 位色末两位是透明度）。随外观切换，见 `CouliColor.token`。
public enum CouliScrim {
    /// 浅色遮罩不透明度（令牌 overlay.scrim 浅色值的 alpha）。
    public static let opacity = TokenRGB(token: "overlay.scrim")?.alpha ?? 0
    public static var color: Color {
        CouliColor.token("overlay.scrim")
    }
}

/// 设计稿（GUIDE §3、§6、§7）规定、但锁定令牌（v0.5.1）里还没有的尺寸，写字面值集中在这里，组件不散写数字。
/// 待 DSX-02 令牌 v0.6.0 补上（tag padding、image frame、sheet handle）后由 DSX-120 改读令牌。
public enum CouliPendingTokenMetric {
    /// 胶囊标签上下内边距（GUIDE §7.2.1 返利标签 padding 2px 8px）。
    public static let tagPaddingVertical: CGFloat = 2
    /// 网格卡图片高宽比（GUIDE §6「157×132 网格卡」）。
    public static let gridImageAspect: CGFloat = 132.0 / 157.0
    /// 空态占位块边长（96）与其中图标（32）。
    public static let emptyIllustration: CGFloat = 96
    public static let emptyIcon: CGFloat = 32
    /// 半屏把手 36×4。
    public static let sheetHandleWidth: CGFloat = 36
    public static let sheetHandleHeight: CGFloat = 4
}
