import CoreGraphics
import Generated

/// 间距（pt），对应 tokens.space。
public enum CouliSpacing {
    public static let s0 = value("0")
    public static let s1 = value("1")
    public static let s2 = value("2")
    public static let s3 = value("3")
    public static let s4 = value("4")
    public static let s5 = value("5")
    public static let s6 = value("6")
    public static let s8 = value("8")
    public static let s10 = value("10")
    public static let s12 = value("12")
    public static let s16 = value("16")

    static func value(_ key: String) -> CGFloat {
        metric(DesignTokens.spacing, key, group: "space")
    }
}

/// 圆角（pt），对应 tokens.radius。
public enum CouliRadius {
    public static let small = metric(DesignTokens.radius, "small", group: "radius")
    public static let button = metric(DesignTokens.radius, "button", group: "radius")
    public static let card = metric(DesignTokens.radius, "card", group: "radius")
    public static let panel = metric(DesignTokens.radius, "panel", group: "radius")
    public static let pill = metric(DesignTokens.radius, "pill", group: "radius")
}

/// 命中区（pt），对应 tokens.interaction.target；下限不随字号缩小（03 §10.4）。
public enum CouliHitTarget {
    public static let minimum = metric(DesignTokens.interactionTarget, "ios", group: "interaction.target")
}

func metric(_ table: [String: Int], _ key: String, group: String) -> CGFloat {
    guard let value = table[key] else {
        assertionFailure("missing token \(group).\(key)")
        return 0
    }
    return CGFloat(value)
}
