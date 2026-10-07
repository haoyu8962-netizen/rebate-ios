import Foundation

/// `#RRGGBB` / `#RRGGBBAA` 颜色（ui.setNavBar 的 bg_color、bg_gradient、text_color；契约 pattern 已校验格式）。分量 0…1。
public struct BridgeColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static func parse(_ text: String?) -> BridgeColor? {
        guard let text, text.hasPrefix("#") else { return nil }
        let hex = text.dropFirst()
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let rgba = hex.count == 6 ? value << 8 | 0xFF : value
        func channel(_ shift: UInt64) -> Double {
            Double((rgba >> shift) & 0xFF) / 255
        }
        return BridgeColor(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }
}

/// ui.setNavBar 的参数（契约 methods.ui.setNavBar.params 的全部字段；没给的字段为 nil，表示保持原样）。
/// APP-04 三端共性第 23 条：全部参数都要生效；本端做不到的参数（`unsupportedKeys`）整次调用返回失败，什么都不改。
public struct BridgeNavBar: Sendable, Equatable {
    public let visible: Bool?
    public let title: String?
    public let bgColor: BridgeColor?
    public let bgGradient: [BridgeColor]?
    public let bgImage: URL?
    public let textColor: BridgeColor?
    /// light（浅色文字）/ dark（深色文字）。
    public let statusBarStyle: String?
    public let immersive: Bool?
    public let hideClose: Bool?
    public let hideBottomSafeArea: Bool?
    public let bounce: Bool?

    public init(
        visible: Bool? = nil,
        title: String? = nil,
        bgColor: BridgeColor? = nil,
        bgGradient: [BridgeColor]? = nil,
        bgImage: URL? = nil,
        textColor: BridgeColor? = nil,
        statusBarStyle: String? = nil,
        immersive: Bool? = nil,
        hideClose: Bool? = nil,
        hideBottomSafeArea: Bool? = nil,
        bounce: Bool? = nil
    ) {
        self.visible = visible
        self.title = title
        self.bgColor = bgColor
        self.bgGradient = bgGradient
        self.bgImage = bgImage
        self.textColor = textColor
        self.statusBarStyle = statusBarStyle
        self.immersive = immersive
        self.hideClose = hideClose
        self.hideBottomSafeArea = hideBottomSafeArea
        self.bounce = bounce
    }

    /// 从已按契约校验过的 params 取值。
    public init(params: [String: Any]) {
        self.init(
            visible: JSONKind.bool(params["visible"]),
            title: JSONKind.string(params, "title"),
            bgColor: BridgeColor.parse(JSONKind.string(params, "bg_color")),
            bgGradient: params["bg_gradient"] == nil
                ? nil : JSONKind.strings(params, "bg_gradient").compactMap(BridgeColor.parse),
            bgImage: JSONKind.string(params, "bg_image").flatMap(URL.init(string:)),
            textColor: BridgeColor.parse(JSONKind.string(params, "text_color")),
            statusBarStyle: JSONKind.string(params, "status_bar_style"),
            immersive: JSONKind.bool(params["immersive"]),
            hideClose: JSONKind.bool(params["hide_close"]),
            hideBottomSafeArea: JSONKind.bool(params["hide_bottom_safe_area"]),
            bounce: JSONKind.bool(params["bounce"])
        )
    }
}
