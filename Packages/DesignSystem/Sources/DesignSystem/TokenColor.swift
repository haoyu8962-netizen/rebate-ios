import Generated
import SwiftUI
import UIKit

/// "#RRGGBB" / "#RRGGBBAA" 令牌的 sRGB 分量（0…1）。8 位按 CSS 顺序 RGBA 读（末两位是透明度，不换成 ARGB）；6 位不透明。
public struct TokenRGB: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit),
              let value = UInt32(digits, radix: 16)
        else {
            return nil
        }
        let rgb = digits.count == 8 ? value >> 8 : value
        red = Double((rgb >> 16) & 0xFF) / 255
        green = Double((rgb >> 8) & 0xFF) / 255
        blue = Double(rgb & 0xFF) / 255
        alpha = digits.count == 8 ? Double(value & 0xFF) / 255 : 1
    }

    /// 取 `DesignTokens.colors` 里的令牌（点分路径，如 "brand.primary"）。
    public init?(token path: String) {
        guard let hex = DesignTokens.colors[path] else {
            return nil
        }
        self.init(hex: hex)
    }

    /// 取 `DesignTokens.colorsDark` 里的令牌（同一路径的深色取值）。
    public init?(darkToken path: String) {
        guard let hex = DesignTokens.colorsDark[path] else {
            return nil
        }
        self.init(hex: hex)
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

/// 语义颜色。名字 = 令牌路径的 lowerCamel（brand.primary → brandPrimary），三端对齐。
public enum CouliColor {
    public static let brandPrimary = token("brand.primary")
    public static let brandEmphasis = token("brand.emphasis")
    public static let brandSecondary = token("brand.secondary")
    public static let brandSubtle = token("brand.subtle")

    public static let backgroundCanvas = token("background.canvas")
    public static let backgroundSurface = token("background.surface")
    public static let backgroundMuted = token("background.muted")
    public static let backgroundPlaceholder = token("background.placeholder")

    public static let textPrimary = token("text.primary")
    public static let textSecondary = token("text.secondary")
    public static let textInverse = token("text.inverse")
    public static let textLink = token("text.link")

    public static let priceText = token("price.text")
    public static let rebateText = token("rebate.text")
    public static let rebateBackground = token("rebate.background")

    public static let statusSuccessText = token("status.success.text")
    public static let statusWarningText = token("status.warning.text")
    public static let statusErrorText = token("status.error.text")
    /// 已结算松叶绿底（APP-08v 列表状态胶囊）。
    public static let statusSuccessBackground = token("status.success.background")
    /// 警告浅底（APP-08v 断网提示条）。
    public static let statusWarningBackground = token("status.warning.background")

    public static let borderSubtle = token("border.subtle")
    public static let borderControl = token("border.control")
    /// 输入中描边（昵称输入框等）。
    public static let borderActive = token("border.active")
    public static let focusRing = token("focus.ring")

    /// 全部语义名用到的令牌路径（测试核对它们都存在）。
    static let usedPaths = [
        "brand.primary", "brand.emphasis", "brand.secondary", "brand.subtle",
        "background.canvas", "background.surface", "background.muted", "background.placeholder",
        "text.primary", "text.secondary", "text.inverse", "text.link",
        "price.text", "rebate.text", "rebate.background",
        "status.success.text", "status.warning.text", "status.error.text",
        "status.success.background", "status.warning.background",
        "border.subtle", "border.control", "border.active", "focus.ring",
    ]

    /// 任意令牌路径 → Color（组件任务里用于语义名之外的令牌）。浅色读 `DesignTokens.colors`、深色读 `DesignTokens.colorsDark`（都是锁定
    /// 快照的生成物），返回随浅 / 深外观切换的动态颜色（UIKit 特征与 SwiftUI colorScheme 同一来源）；每次解析都按当时的外观取值，
    /// 不在创建时先取定一种。
    public static func token(_ path: String) -> Color {
        guard let rgb = TokenRGB(token: path), let dark = TokenRGB(darkToken: path) else {
            assertionFailure("missing color token \(path)")
            return .clear
        }
        let light = rgb.uiColor
        let night = dark.uiColor
        return Color(UIColor { $0.userInterfaceStyle == .dark ? night : light })
    }
}
