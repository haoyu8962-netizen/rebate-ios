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
    private let minWidth: CGFloat?
    private let horizontalPadding: CGFloat?
    private let weight: Font.Weight
    private let mutedWhenDisabled: Bool
    private let leadingIcon: CouliIcon?
    private let iconProbeID: String?
    private let action: () -> Void
    @Environment(\.couliButtonLabelProbe) private var inheritedLabelProbe

    public init(
        _ title: String,
        kind: CouliButtonKind = .primary,
        size: CouliButtonSize = .regular,
        isLoading: Bool = false,
        isEnabled: Bool = true,
        fillsWidth: Bool = false,
        accessibilityLabel: String? = nil,
        labelProbeID: String? = nil,
        minWidth: CGFloat? = nil,
        horizontalPadding: CGFloat? = nil,
        weight: Font.Weight = .couliSemibold,
        mutedWhenDisabled: Bool = false,
        leadingIcon: CouliIcon? = nil,
        iconProbeID: String? = nil,
        action: @escaping () -> Void
    ) {
        self.leadingIcon = leadingIcon
        self.iconProbeID = iconProbeID
        self.labelProbeID = labelProbeID
        self.horizontalPadding = horizontalPadding
        self.weight = weight
        self.mutedWhenDisabled = mutedWhenDisabled
        self.minWidth = minWidth
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
                if let leadingIcon {
                    // 文字前的 20 图标（APP-12w-b 关于页【复制诊断信息】）：缺省 nil，既有按钮不变；装饰，读屏只读按钮名。
                    let icon = CouliIconView(leadingIcon, size: CouliGuideMetric.iconMedium, relativeTo: .footnote)
                    if let iconProbeID {
                        icon.couliProbe(iconProbeID, role: "icon")
                    } else {
                        icon
                    }
                }
                Text(verbatim: title)
                    .couliFont(size == .regular ? .body : .footnote, weight: weight)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    // 按钮字测量（APP-06v G-D13：200% 底栏排法的测试依据）；nil 或没有接收方时不加任何视图。
                    .couliTextNaturalProbe(
                        labelProbeID ?? inheritedLabelProbe, role: "button-label", text: title,
                        style: size == .regular ? .body : .footnote, weight: weight
                    )
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(CouliButtonStyle(kind: kind, size: size, enabled: isEnabled && !isLoading, minWidth: minWidth,
                                      horizontalPadding: horizontalPadding, mutedWhenDisabled: mutedWhenDisabled))
        .disabled(!isEnabled || isLoading)
        .accessibilityLabel(Text(verbatim: accessibilityLabel ?? title))
        .accessibilityAddTraits(isLoading ? .updatesFrequently : [])
    }
}

struct CouliButtonStyle: ButtonStyle {
    let kind: CouliButtonKind
    let size: CouliButtonSize
    let enabled: Bool
    /// 视觉最小宽（APP-09v 钱包【提现】96，W3）；nil 时只有命中区下限 44（既有按钮不变）。
    var minWidth: CGFloat?
    /// 左右内边距（APP-09v-c 待确认卡两等宽按钮按稿 8，七个字才放得下一行）；nil 时按尺寸取令牌（既有按钮不变）。
    var horizontalPadding: CGFloat?
    /// 次按钮不可用时取禁用实底、去描边（WithdrawPendingBusy）；缺省 false = 白底描边（既有按钮不变）。
    var mutedWhenDisabled = false

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
            mutedDisabled ? CouliColor.token("button.primary.disabled.background")
                : (pressed ? CouliColor.backgroundMuted : CouliColor.backgroundSurface)
        case .text:
            pressed ? CouliColor.brandSubtle : .clear
        case .inverse:
            enabled ? (pressed ? CouliColor.brandSubtle : CouliColor.backgroundSurface)
                : CouliColor.token("button.primary.disabled.background")
        }
    }

    private var mutedDisabled: Bool {
        mutedWhenDisabled && !enabled
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let minHeight = size == .regular ? CouliComponentMetric.buttonMinHeight : CouliHitTarget.minimum
        let horizontal = horizontalPadding
            ?? (size == .regular ? CouliComponentMetric.buttonPaddingInline : CouliSpacing.s4)
        let vertical = size == .regular ? CouliComponentMetric.buttonPaddingBlock : CouliSpacing.s2
        return configuration.label
            .foregroundColor(Self.foreground(kind: kind, enabled: enabled, pressed: pressed))
            .padding(.horizontal, kind == .text ? CouliSpacing.s2 : horizontal)
            .padding(.vertical, vertical)
            .frame(
                minWidth: max(CouliHitTarget.minimum, minWidth ?? 0),
                minHeight: kind == .text ? CouliHitTarget.minimum : minHeight
            )
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .fill(background(pressed: pressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .strokeBorder(
                        kind == .secondary && !mutedDisabled ? CouliColor.borderControl : .clear,
                        lineWidth: CouliComponentMetric.controlBorderWidth
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous))
            .modifier(CouliFocusRing(cornerRadius: CouliRadius.button, onBrand: kind == .inverse))
    }
}

public extension EnvironmentValues {
    /// 按钮字的测量编号（环境传入）：`labelProbeID` 没给时用它。只影响测量上报，不改外观（缺省 nil）。
    @Entry var couliButtonLabelProbe: String?
}

public extension View {
    /// 给这个视图里的 `CouliButton` 指定按钮字测量编号（APP-09v-c 提现页【提交】：调用字面锁定，不能多加实参）。
    func couliButtonLabelProbe(_ id: String?) -> some View {
        environment(\.couliButtonLabelProbe, id)
    }
}
