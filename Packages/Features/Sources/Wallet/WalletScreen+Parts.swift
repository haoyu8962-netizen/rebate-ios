import DesignSystem
import SwiftUI
import UIKit

// 钱包页（APP-09v-a）私有的小件：带测量的文字、不可拆金额、视觉框与命中区分开的图标按钮、提示条外壳。
// 测量编号经 DesignSystem 的 `couliProbe` 一族上报（没有接收方时原样返回、不多画任何视图；Release 没有接收方）。

/// 有编号才上报布局框（没有编号时原样返回）。
struct WalletProbe: ViewModifier {
    let id: String?
    var role = "box"

    func body(content: Content) -> some View {
        if let id {
            content.couliProbe(id, role: role)
        } else {
            content
        }
    }
}

extension View {
    func walletProbe(_ id: String?, role: String = "box") -> some View {
        modifier(WalletProbe(id: id, role: role))
    }
}

/// 令牌字号的文字（可折行），连同实际字号一起上报测量（`text` = 显示的文字）。
struct WalletText: View {
    private let text: String
    private let style: CouliTextStyle
    private let weight: Font.Weight
    private let monospacedDigits: Bool
    private let probe: String?
    @ScaledMetric private var size: CGFloat

    init(_ text: String, style: CouliTextStyle, weight: Font.Weight = .regular, monospacedDigits: Bool = false,
         probe: String? = nil) {
        self.text = text
        self.style = style
        self.weight = weight
        self.monospacedDigits = monospacedDigits
        self.probe = probe
        _size = ScaledMetric(wrappedValue: style.baseSize, relativeTo: style.relativeTo)
    }

    var body: some View {
        let label = Text(verbatim: text)
            .couliFont(style, weight: weight, monospacedDigits: monospacedDigits)
            .fixedSize(horizontal: false, vertical: true)
            // 单行也按令牌行高占位（画板 line-height：14 → 21、12 → 18）
            .couliLineBox(style)
        if let probe {
            label.couliTextProbe(probe, role: "text", text: text, fontSize: size, baseFontSize: style.baseSize)
        } else {
            label
        }
    }
}

/// 一个金额段（大数、冻结中、预估）：放得下就单行、不截断、不缩字；单段比可用宽度还宽时整段一行、框内横向滚动
/// （D10-1230 判据 1：不在数字中间断、不截断、不缩字号）。有测量接收方时按同一字体量单行自然宽，连同实际框、实际字号一起上报
/// （`CouliUnbreakableText` 口径：放得下时实际宽 = 自然宽）。
/// `lineHeightMultiple`：单行占位高度倍数（主卡大数用按钮高 48 / 34，金额行与【提现】上下居中时金额框贴行顶）。
struct WalletAmount: View {
    private let text: String
    private let style: CouliTextStyle
    private let weight: Font.Weight
    private let lineHeightMultiple: CGFloat
    private let probe: String
    @ScaledMetric private var size: CGFloat
    @Environment(\.couliLayoutProbe) private var receiver

    init(text: String, style: CouliTextStyle, weight: Font.Weight = .couliSemibold, lineHeightMultiple: CGFloat? = nil,
         probe: String) {
        self.text = text
        self.style = style
        self.weight = weight
        self.lineHeightMultiple = lineHeightMultiple ?? style.lineHeightMultiple
        self.probe = probe
        _size = ScaledMetric(wrappedValue: style.baseSize, relativeTo: style.relativeTo)
    }

    var body: some View {
        let label = Text(verbatim: text)
            .font(Font.system(size: size, weight: weight).monospacedDigit())
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: (size * lineHeightMultiple).rounded())
        // 单段放不下时整段一行、框内横滑（D10-1230 判据 1：不在数字中间断、不缩字）
        CouliWholeDigits(minimumWidth: naturalWidth, probe: probe) {
            if receiver != nil {
                label.couliTextProbe(probe, role: "amount", text: text, fontSize: size,
                                     baseFontSize: style.baseSize, naturalWidth: naturalWidth)
            } else {
                label
            }
        }
    }

    /// 同一字体（系统字体、等宽数字、同字重）下整段的单行宽度（APP-06v K6 / APP-08v 做法：按字体量，不靠隐藏副本的布局回调）。
    private var naturalWidth: CGFloat {
        let uiWeight: UIFont.Weight = weight == .couliBold ? .bold : (weight == .couliMedium ? .medium : .semibold)
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: uiWeight)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}

/// 图标按钮：视觉是图标本身（`base` 号、随字号缩放），命中区 = max(44, 图标) 的方块，用负外边距溢出、不撑高所在行
/// （APP-08v §9 风险 1；Android a r1 S2-1：图标放大到超过 44 时命中区就是图标本身，不再向外扩，换行后与邻控件不重叠）。
/// 测量：`probe` = 图标视觉框，`probe.hit` = 命中框。
struct WalletIconButton: View {
    let icon: CouliIcon
    let base: CGFloat
    var relativeTo: Font.TextStyle = .footnote
    let label: String
    var onBrand = false
    let probe: String?
    /// 读屏焦点绑定（弹层关闭后焦点回到这里，`restoreFocusTo:`）；nil 不挂。
    let focus: AccessibilityFocusState<Bool>.Binding?
    let action: () -> Void
    @ScaledMetric private var size: CGFloat

    init(_ icon: CouliIcon, base: CGFloat, relativeTo: Font.TextStyle = .footnote, label: String,
         onBrand: Bool = false, probe: String?, focus: AccessibilityFocusState<Bool>.Binding? = nil,
         action: @escaping () -> Void) {
        self.icon = icon
        self.base = base
        self.relativeTo = relativeTo
        self.label = label
        self.onBrand = onBrand
        self.probe = probe
        self.focus = focus
        self.action = action
        _size = ScaledMetric(wrappedValue: base, relativeTo: relativeTo)
    }

    var body: some View {
        let hit = max(CouliHitTarget.minimum, size)
        Button(action: action) {
            CouliIconView(icon, size: base, relativeTo: relativeTo)
                .walletProbe(probe, role: "icon")
                .frame(width: hit, height: hit)
                .contentShape(Rectangle())
                .walletProbe(probe.map { $0 + ".hit" }, role: "hit")
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small, onBrand: onBrand))
        .padding(-(hit - size) / 2)
        .accessibilityLabel(Text(verbatim: label))
        .modifier(WalletFocusBinding(focus: focus))
    }
}

/// 有绑定时挂读屏焦点（`accessibilityFocused(_:)`），没有时原样。
struct WalletFocusBinding: ViewModifier {
    let focus: AccessibilityFocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let focus {
            content.accessibilityFocused(focus)
        } else {
            content
        }
    }
}

/// 提示条的语气（brief §2 通用：圆角 12、内边距 12、图标 20 + 14 字）。
enum WalletStripTone {
    case warning

    var background: Color {
        CouliColor.statusWarningBackground
    }

    var foreground: Color {
        CouliColor.statusWarningText
    }
}

/// 提示条外壳：图标 20（随字号缩放）+ 文字列；可选右侧 ›（20）。
struct WalletStrip<Lines: View>: View {
    let icon: CouliIcon
    var tone = WalletStripTone.warning
    let probe: String
    var chevron = false
    @ViewBuilder let lines: () -> Lines

    var body: some View {
        HStack(alignment: .top, spacing: CouliSpacing.s2) {
            CouliIconView(icon, size: CouliComponentMetric.iconMedium, relativeTo: .footnote)
                .walletProbe(probe + ".icon", role: "icon")
            VStack(alignment: .leading, spacing: 2) {
                lines()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if chevron {
                CouliIconView(.chevron, size: CouliComponentMetric.iconMedium, relativeTo: .footnote)
                    .walletProbe(probe + ".chevron", role: "icon")
            }
        }
        .foregroundColor(tone.foreground)
        .padding(CouliSpacing.s3)
        .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous).fill(tone.background))
        .walletProbe(probe, role: "strip")
    }
}
