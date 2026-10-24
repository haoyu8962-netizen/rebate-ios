import Generated
import SwiftUI
import UIKit

/// 六级文字样式，字号取 tokens.font.size，并跟随 Dynamic Type 缩放（03 §10.4）。
public enum CouliTextStyle: String, Sendable, CaseIterable {
    case caption
    case footnote
    case body
    case title
    case heading
    case display

    /// 默认（系统字号为「大」）时的字号。
    public var baseSize: CGFloat {
        metric(DesignTokens.fontSize, rawValue, group: "font.size")
    }

    /// 行高倍数（tokens.font.line-height）。
    public var lineHeightMultiple: CGFloat {
        guard let value = DesignTokens.lineHeight[rawValue] else {
            assertionFailure("missing token font.line-height.\(rawValue)")
            return 1
        }
        return CGFloat(value)
    }

    /// 缩放参照的系统文字样式。
    public var relativeTo: Font.TextStyle {
        switch self {
        case .caption: .caption
        case .footnote: .footnote
        case .body: .body
        case .title: .title2
        case .heading: .title
        case .display: .largeTitle
        }
    }
}

/// 令牌字重（tokens.font.weight）。
public enum CouliFontWeight: String, Sendable, CaseIterable {
    case regular
    case medium
    case semibold
    case bold

    /// 令牌数值（400 / 500 / 600 / 700）。
    public var value: Int {
        guard let value = DesignTokens.fontWeight[rawValue] else {
            assertionFailure("missing token font.weight.\(rawValue)")
            return 400
        }
        return value
    }

    public var fontWeight: Font.Weight {
        switch value {
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        default: .bold
        }
    }
}

private struct CouliFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let style: CouliTextStyle
    private let weight: Font.Weight
    private let monospacedDigits: Bool

    init(style: CouliTextStyle, weight: Font.Weight, monospacedDigits: Bool) {
        _size = ScaledMetric(wrappedValue: style.baseSize, relativeTo: style.relativeTo)
        self.style = style
        self.weight = weight
        self.monospacedDigits = monospacedDigits
    }

    func body(content: Content) -> some View {
        let font = Font.system(size: size, weight: weight)
        return content
            .font(monospacedDigits ? font.monospacedDigit() : font)
            // 行高令牌：令牌行高减去字体自身行高，作为行距（单行时不改变高度）。
            .lineSpacing(max(size * style.lineHeightMultiple - CouliFontMetrics.lineHeight(size), 0))
    }
}

public extension View {
    /// 套用令牌文字样式；字号随系统字号缩放。金额传 `monospacedDigits: true`（等宽数字）。
    func couliFont(
        _ style: CouliTextStyle,
        weight: Font.Weight = .regular,
        monospacedDigits: Bool = false
    ) -> some View {
        modifier(CouliFontModifier(style: style, weight: weight, monospacedDigits: monospacedDigits))
    }
}

/// 字体行高：中文正文落到苹方，按苹方的行高计算令牌行距（拿不到时用系统字体）。
enum CouliFontMetrics {
    static func font(_ size: CGFloat) -> UIFont {
        UIFont(name: "PingFangSC-Regular", size: size) ?? UIFont.systemFont(ofSize: size)
    }

    static func lineHeight(_ size: CGFloat) -> CGFloat {
        font(size).lineHeight
    }
}

private struct CouliLineBoxModifier: ViewModifier {
    @ScaledMetric private var height: CGFloat

    init(style: CouliTextStyle) {
        _height = ScaledMetric(wrappedValue: style.baseSize * style.lineHeightMultiple, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        content.frame(minHeight: height)
    }
}

public extension View {
    /// 单行文字也按令牌行高占位（`couliFont` 的行距只作用于多行）：最小高 = 字号 × 行高倍数，随系统字号缩放。
    /// 只给需要与设计稿行高对齐的新组件用（APP-11v 首页），不改 `couliFont` 本身。
    func couliLineBox(_ style: CouliTextStyle) -> some View {
        modifier(CouliLineBoxModifier(style: style))
    }
}
