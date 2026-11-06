// 生成物，禁止手改；来源 contract.lock
// 快照：design/design-tokens.json

/// 设计令牌原始常量；SwiftUI 映射在 DesignSystem。
public enum DesignTokens {
    public static let version: Swift.String = "0.5.1"

    /// 颜色（浅色，tokens.color.*.value）：去掉 tokens.color. 前缀的点分路径 → "#RRGGBB" 或 "#RRGGBBAA"（CSS 顺序，末两位透明度；保留源字符串）。
    public static let colors: [Swift.String: Swift.String] = [
        "background.admin-canvas": "#F6F3ED",
        "background.canvas": "#F2EEE6",
        "background.muted": "#EFEAE2",
        "background.placeholder": "#E9E2D9",
        "background.surface": "#FFFFFF",
        "badge.background": "#C44820",
        "border.active": "#28251F",
        "border.control": "#8A8177",
        "border.subtle": "#E4DED5",
        "brand.emphasis": "#A83B1F",
        "brand.primary": "#C44820",
        "brand.secondary": "#26735B",
        "brand.subtle": "#FBEFE8",
        "button.inverse.background": "#FFFFFF",
        "button.inverse.text": "#A83B1F",
        "button.primary.default.background": "#C44820",
        "button.primary.default.text": "#FFFFFF",
        "button.primary.disabled.background": "#E9E2D9",
        "button.primary.disabled.text": "#655E57",
        "button.primary.pressed.background": "#A83B1F",
        "button.primary.pressed.text": "#FFFFFF",
        "control.checked": "#C44820",
        "focus.ring": "#26735B",
        "overlay.on-image": "#0000008C",
        "overlay.scrim": "#28251F66",
        "platform.tag.jd": "#E02018",
        "platform.tag.pdd": "#EB0007",
        "platform.tag.taobao": "#D53D00",
        "platform.tag.tmall": "#EA0031",
        "price.text": "#28251F",
        "rebate.background": "#FBEFE8",
        "rebate.solid.background": "#C44820",
        "rebate.solid.text": "#FFFFFF",
        "rebate.text": "#A83B1F",
        "source.background": "#FFFFFF",
        "source.border": "#E4DED5",
        "source.text": "#655E57",
        "status.error.background": "#FDECF0",
        "status.error.text": "#B42345",
        "status.pending.background": "#EFEAE2",
        "status.pending.text": "#655E57",
        "status.success.background": "#EAF4EE",
        "status.success.text": "#26735B",
        "status.warning.background": "#FBF2DC",
        "status.warning.text": "#846020",
        "text.inverse": "#FFFFFF",
        "text.link": "#A83B1F",
        "text.primary": "#28251F",
        "text.secondary": "#655E57",
    ]

    /// 颜色（深色，tokens.color.*.dark）：键与 colors 相同，写法同上。
    public static let colorsDark: [Swift.String: Swift.String] = [
        "background.admin-canvas": "#171513",
        "background.canvas": "#171513",
        "background.muted": "#2F2B27",
        "background.placeholder": "#36312C",
        "background.surface": "#24211E",
        "badge.background": "#C44820",
        "border.active": "#F2EEE6",
        "border.control": "#8C8278",
        "border.subtle": "#3A3530",
        "brand.emphasis": "#F0956B",
        "brand.primary": "#C44820",
        "brand.secondary": "#6CC49F",
        "brand.subtle": "#3A2219",
        "button.inverse.background": "#FFFFFF",
        "button.inverse.text": "#A83B1F",
        "button.primary.default.background": "#C44820",
        "button.primary.default.text": "#FFFFFF",
        "button.primary.disabled.background": "#36312C",
        "button.primary.disabled.text": "#A39A90",
        "button.primary.pressed.background": "#A83B1F",
        "button.primary.pressed.text": "#FFFFFF",
        "control.checked": "#C44820",
        "focus.ring": "#5DBB97",
        "overlay.on-image": "#0000008C",
        "overlay.scrim": "#0000008C",
        "platform.tag.jd": "#E02018",
        "platform.tag.pdd": "#EB0007",
        "platform.tag.taobao": "#D53D00",
        "platform.tag.tmall": "#EA0031",
        "price.text": "#F2EEE6",
        "rebate.background": "#3A2219",
        "rebate.solid.background": "#C44820",
        "rebate.solid.text": "#FFFFFF",
        "rebate.text": "#F29A6E",
        "source.background": "#24211E",
        "source.border": "#3A3530",
        "source.text": "#B5ACA2",
        "status.error.background": "#3B1A22",
        "status.error.text": "#F28DA4",
        "status.pending.background": "#2F2B27",
        "status.pending.text": "#B5ACA2",
        "status.success.background": "#16302A",
        "status.success.text": "#6CC49F",
        "status.warning.background": "#33290F",
        "status.warning.text": "#E3B65C",
        "text.inverse": "#FFFFFF",
        "text.link": "#F0956B",
        "text.primary": "#F2EEE6",
        "text.secondary": "#B5ACA2",
    ]

    /// 间距（pt）："0"…"16"。
    public static let spacing: [Swift.String: Swift.Int] = [
        "0": 0,
        "1": 4,
        "10": 40,
        "12": 48,
        "16": 64,
        "2": 8,
        "3": 12,
        "4": 16,
        "5": 20,
        "6": 24,
        "8": 32,
    ]

    /// 圆角（pt）。
    public static let radius: [Swift.String: Swift.Int] = [
        "avatar": 10,
        "button": 12,
        "card": 16,
        "panel": 24,
        "pill": 999,
        "small": 8,
        "tag": 4,
    ]

    /// 字号（pt）：caption … display。
    public static let fontSize: [Swift.String: Swift.Int] = [
        "body": 17,
        "caption": 12,
        "display": 34,
        "footnote": 14,
        "heading": 28,
        "title": 22,
    ]

    /// 命中区（pt）：tokens.interaction.target。
    public static let interactionTarget: [Swift.String: Swift.Int] = [
        "android": 48,
        "harmony": 48,
        "ios": 44,
        "minimum": 44,
    ]

    /// 行高倍数：caption … display（tokens.font.line-height）。
    public static let lineHeight: [Swift.String: Swift.Double] = [
        "body": 1.5,
        "caption": 1.5,
        "display": 1.2,
        "footnote": 1.5,
        "heading": 1.25,
        "title": 1.3,
    ]

    /// 字重：regular … bold（tokens.font.weight）。
    public static let fontWeight: [Swift.String: Swift.Int] = [
        "bold": 700,
        "medium": 500,
        "regular": 400,
        "semibold": 600,
    ]

    /// 焦点环（pt）：width、offset（tokens.focus）。
    public static let focus: [Swift.String: Swift.Int] = [
        "offset": 2,
        "width": 2,
    ]

    /// 组件尺寸（pt，type dimension）：点分路径，如 "button.min-height"（tokens.component）。
    public static let component: [Swift.String: Swift.Int] = [
        "button.gap": 8,
        "button.min-height": 48,
        "button.padding-block": 12,
        "button.padding-inline": 20,
        "checkbox.size": 18,
        "chip.height": 32,
        "code-cell.height": 56,
        "control.border-width": 1,
        "control.min-height": 44,
        "count-badge.size": 18,
        "field.min-height": 52,
        "grid-cell.min-height": 72,
        "icon.default": 24,
        "icon.inline": 16,
        "icon.medium": 20,
        "icon.small": 14,
        "image.list": 96,
        "oauth.gap": 32,
        "oauth.size": 48,
        "platform-badge.min-height": 20,
        "tab-indicator.height": 2,
        "tag.min-height": 22,
    ]

    /// 组件非整数值（type number，如 checkbox.max-scale）。
    public static let componentNumber: [Swift.String: Swift.Double] = [
        "checkbox.max-scale": 1.5,
    ]

    /// 阴影的一层（tokens.shadow.* 的 value / dark 数组元素）。color 为 "#RRGGBB"，opacity 0…1。
    public struct ShadowLayer: Swift.Sendable, Swift.Equatable {
        public let x: Swift.Int
        public let y: Swift.Int
        public let blur: Swift.Int
        public let spread: Swift.Int
        public let color: Swift.String
        public let opacity: Swift.Double
    }

    /// 阴影（浅色）：none / card / floating …（tokens.shadow.*.value）。
    public static let shadows: [Swift.String: [ShadowLayer]] = [
        "card": [
            ShadowLayer(x: 0, y: 2, blur: 8, spread: 0, color: "#28251F", opacity: 0.06),
        ],
        "floating": [
            ShadowLayer(x: 0, y: 8, blur: 24, spread: 0, color: "#28251F", opacity: 0.12),
        ],
        "none": [],
    ]

    /// 阴影（深色）：键与 shadows 相同（tokens.shadow.*.dark；空档 none 无 dark 时为空）。
    public static let shadowsDark: [Swift.String: [ShadowLayer]] = [
        "card": [
            ShadowLayer(x: 0, y: 2, blur: 8, spread: 0, color: "#000000", opacity: 0.3),
        ],
        "floating": [
            ShadowLayer(x: 0, y: 8, blur: 24, spread: 0, color: "#000000", opacity: 0.45),
        ],
        "none": [],
    ]
}
