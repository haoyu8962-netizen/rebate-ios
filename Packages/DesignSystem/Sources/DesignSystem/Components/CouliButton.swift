import SwiftUI

/// 按钮种类（GUIDE §3：主 / 次 / 文字）。
public enum CouliButtonKind: Sendable {
    /// 狸橙实底、白字。一个区域一个。
    case primary
    /// 白底、控件边界描边、墨棕字。
    case secondary
    /// 强调色文字按钮 / 链接。
    case text
    /// 狸橙实底卡内的白底按钮（WalletHeroCard【提现】，GUIDE §7.1）。
    case inverse
}

/// 按钮尺寸。
public enum CouliButtonSize: Sendable {
    /// 标准：最小高 48（component.button），body 17/600。
    case regular
    /// 紧凑：卡片内购买按钮，最小高 44（命中区下限），footnote 14/600（GUIDE §7.2.1）。
    case compact
}

/// 通用按钮：主 / 次 / 文字；loading、禁用；最小高取令牌。文字不截断，大字号时按钮增高。
public struct CouliButton: View {
    private let title: String
    private let kind: CouliButtonKind
    private let size: CouliButtonSize
    private let isLoading: Bool
    private let isEnabled: Bool
    private let fillsWidth: Bool
    private let accessibilityLabel: String?
    private let labelProbeID: String?
    private let action: () -> Void

    public init(
        _ title: String,
        kind: CouliButtonKind = .primary,
        size: CouliButtonSize = .regular,
        isLoading: Bool = false,
        isEnabled: Bool = true,
        fillsWidth: Bool = false,
        accessibilityLabel: String? = nil,
        labelProbeID: String? = nil,
        action: @escaping () -> Void
    ) {
        self.labelProbeID = labelProbeID
        self.title = title
        self.kind = kind
        self.size = size
        self.isLoading = isLoading
        self.isEnabled = isEnabled
        self.fillsWidth = fillsWidth
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: CouliComponentMetric.buttonGap) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(CouliButtonStyle.foreground(kind: kind, enabled: false, pressed: false))
                        .accessibilityHidden(true)
                }
                Text(verbatim: title)
                    .couliFont(size == .regular ? .body : .footnote, weight: .couliSemibold)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    // 按钮字测量（APP-06v G-D13：200% 底栏排法的测试依据）；nil 或没有接收方时不加任何视图。
                    .couliTextNaturalProbe(
                        labelProbeID, role: "button-label", text: title,
                        style: size == .regular ? .body : .footnote, weight: .couliSemibold
                    )
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(CouliButtonStyle(kind: kind, size: size, enabled: isEnabled && !isLoading))
        .disabled(!isEnabled || isLoading)
        .accessibilityLabel(Text(verbatim: accessibilityLabel ?? title))
        .accessibilityAddTraits(isLoading ? .updatesFrequently : [])
    }
}

struct CouliButtonStyle: ButtonStyle {
    let kind: CouliButtonKind
    let size: CouliButtonSize
    let enabled: Bool

    /// 主按钮令牌路径：button.primary.<default|pressed|disabled>.<part>。
    static func primaryToken(enabled: Bool, pressed: Bool, part: String) -> String {
        let state = !enabled ? "disabled" : (pressed ? "pressed" : "default")
        return "button.primary.\(state).\(part)"
    }

    static func foreground(kind: CouliButtonKind, enabled: Bool, pressed: Bool) -> Color {
        switch kind {
        case .primary:
            CouliColor.token(primaryToken(enabled: enabled, pressed: pressed, part: "text"))
        case .secondary:
            enabled ? CouliColor.textPrimary : CouliColor.token("button.primary.disabled.text")
        case .text:
            enabled ? CouliColor.textLink : CouliColor.textSecondary
        case .inverse:
            enabled ? CouliColor.brandEmphasis : CouliColor.textSecondary
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary:
            CouliColor.token(Self.primaryToken(enabled: enabled, pressed: pressed, part: "background"))
        case .secondary:
            pressed ? CouliColor.backgroundMuted : CouliColor.backgroundSurface
        case .text:
            pressed ? CouliColor.brandSubtle : .clear
        case .inverse:
            enabled ? (pressed ? CouliColor.brandSubtle : CouliColor.backgroundSurface)
                : CouliColor.token("button.primary.disabled.background")
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let minHeight = size == .regular ? CouliComponentMetric.buttonMinHeight : CouliHitTarget.minimum
        let horizontal = size == .regular ? CouliComponentMetric.buttonPaddingInline : CouliSpacing.s4
        let vertical = size == .regular ? CouliComponentMetric.buttonPaddingBlock : CouliSpacing.s2
        return configuration.label
            .foregroundColor(Self.foreground(kind: kind, enabled: enabled, pressed: pressed))
            .padding(.horizontal, kind == .text ? CouliSpacing.s2 : horizontal)
            .padding(.vertical, vertical)
            .frame(minWidth: CouliHitTarget.minimum, minHeight: kind == .text ? CouliHitTarget.minimum : minHeight)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .fill(background(pressed: pressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .strokeBorder(
                        kind == .secondary ? CouliColor.borderControl : .clear,
                        lineWidth: CouliComponentMetric.controlBorderWidth
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous))
            .modifier(CouliFocusRing(cornerRadius: CouliRadius.button, onBrand: kind == .inverse))
    }
}
