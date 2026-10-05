// 生成物，禁止手改；来源 contract.lock
// 快照：design/design-tokens.json

/// 设计令牌原始常量；SwiftUI 映射在 DesignSystem。
public enum DesignTokens {
    public static let version: Swift.String = "0.3.0"

    /// 颜色：去掉 tokens.color. 前缀的点分路径 → "#RRGGBB"（保留源大小写）。
    public static let colors: [Swift.String: Swift.String] = [
        "background.admin-canvas": "#F6F3ED",
        "background.canvas": "#F2EEE6",
        "background.muted": "#EFEAE2",
        "background.placeholder": "#E9E2D9",
        "background.surface": "#FFFFFF",
        "border.control": "#8A8177",
        "border.subtle": "#E4DED5",
        "brand.emphasis": "#A83B1F",
        "brand.primary": "#C44820",
        "brand.secondary": "#26735B",
        "brand.subtle": "#FBEFE8",
        "button.primary.default.background": "#C44820",
        "button.primary.default.text": "#FFFFFF",
        "button.primary.disabled.background": "#E9E2D9",
        "button.primary.disabled.text": "#655E57",
        "button.primary.pressed.background": "#A83B1F",
        "button.primary.pressed.text": "#FFFFFF",
        "focus.ring": "#26735B",
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
        "button": 12,
        "card": 16,
        "panel": 24,
        "pill": 999,
        "small": 8,
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
}
