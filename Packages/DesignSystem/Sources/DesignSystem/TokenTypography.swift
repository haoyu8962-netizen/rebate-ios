import Generated
import SwiftUI

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

private struct CouliFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(style: CouliTextStyle, weight: Font.Weight) {
        _size = ScaledMetric(wrappedValue: style.baseSize, relativeTo: style.relativeTo)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

public extension View {
    /// 套用令牌文字样式；字号随系统字号缩放。
    func couliFont(_ style: CouliTextStyle, weight: Font.Weight = .regular) -> some View {
        modifier(CouliFontModifier(style: style, weight: weight))
    }
}
