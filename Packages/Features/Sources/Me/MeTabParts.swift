import DesignSystem
import SwiftUI
import UIKit

// 「我的」Tab（APP-12v）私有的小件：带测量的文字、不可拆金额、视觉框与命中区分开的图标按钮。
// 页面私有、不进 DS（G-M17）；测量经 DS 的 `couliProbe` 一族上报，没有接收方时原样返回、不多画视图（Release 没有接收方）。

struct MeProbe: ViewModifier {
    let id: String?
    let role: String

    func body(content: Content) -> some View {
        if let id {
            content.couliProbe(id, role: role)
        } else {
            content
        }
    }
}

extension View {
    func meProbe(_ id: String?, role: String = "box") -> some View {
        modifier(MeProbe(id: id, role: role))
    }
}

/// 令牌字号的文字（可折行，不截断）：单行也按令牌行高占位；实际框、自然宽、字号一起上报。
struct MeText: View {
    let text: String
    let style: CouliTextStyle
    var weight: Font.Weight = .regular
    var monospacedDigits = false
    let probe: String?

    init(_ text: String, style: CouliTextStyle, weight: Font.Weight = .regular, monospacedDigits: Bool = false,
         probe: String? = nil) {
        self.text = text
        self.style = style
        self.weight = weight
        self.monospacedDigits = monospacedDigits
        self.probe = probe
    }

    var body: some View {
        Text(verbatim: text)
            .couliFont(style, weight: weight, monospacedDigits: monospacedDigits)
            .fixedSize(horizontal: false, vertical: true)
            .couliLineBox(style)
            .couliTextNaturalProbe(probe, role: "text", text: text, style: style, weight: weight)
    }
}

/// 一个金额段：放得下就单行、不截断、不缩字；比可用宽度还宽时整段一行、框内横向滚动（D10-1230）。有测量接收方时报单行自然宽。
/// `lineHeightMultiple`：单行占位高度倍数（大数按按钮高 48 / 34，与【提现】上下居中）。
struct MeAmount: View {
    private let text: String
    private let style: CouliTextStyle
    private let weight: Font.Weight
    private let lineHeightMultiple: CGFloat
    private let probe: String
    @ScaledMetric private var size: CGFloat
    @Environment(\.couliLayoutProbe) private var receiver

    init(_ text: String, style: CouliTextStyle, weight: Font.Weight, lineHeightMultiple: CGFloat? = nil,
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

    private var naturalWidth: CGFloat {
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight == .couliBold ? .bold : .semibold)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}

/// 图标按钮：视觉是图标本身，命中区 = max(44, 图标) 的方块，用负外边距溢出、不撑高所在行（brief §9 第 1 条）。焦点环画在框内：框外的环会算进
/// 无障碍框，边缘真点点空（APP-09v-d K4）。`margin`：负外边距少收多少（画板复制按钮两侧留 2）。测量：`probe` = 图标，`probe.hit` = 命中框。
struct MeIconButton: View {
    private let icon: CouliIcon
    private let base: CGFloat
    private let label: String
    private let onBrand: Bool
    private let margin: CGFloat
    private let probe: String
    private let action: () -> Void
    @ScaledMetric private var size: CGFloat

    init(_ icon: CouliIcon, base: CGFloat, label: String, onBrand: Bool = false, margin: CGFloat = 0, probe: String,
         action: @escaping () -> Void) {
        self.icon = icon
        self.base = base
        self.label = label
        self.onBrand = onBrand
        self.margin = margin
        self.probe = probe
        self.action = action
        _size = ScaledMetric(wrappedValue: base, relativeTo: .footnote)
    }

    var body: some View {
        let hit = max(CouliHitTarget.minimum, size)
        let inset = (hit - size) / 2
        Button(action: action) {
            CouliIconView(icon, size: base, relativeTo: .footnote)
                .meProbe(probe, role: "icon")
                .frame(width: hit, height: hit)
                .contentShape(Rectangle())
                .meProbe(probe + ".hit", role: "hit")
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small, onBrand: onBrand, ringInside: true))
        .padding(.vertical, -inset)
        .padding(.horizontal, -max(0, inset - margin))
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// 默认头像：56 圆、`background.muted`，人形 32 次文字色；装饰，不进读屏。
struct MeAvatar: View {
    var body: some View {
        ZStack {
            Circle().fill(CouliColor.backgroundMuted)
            CouliIconView(.user, size: CouliComponentMetric.iconMedium + CouliSpacing.s3)
                .foregroundColor(CouliColor.textSecondary)
                .meProbe("me.avatar.icon", role: "icon")
        }
        .frame(width: CouliSpacing.s12 + CouliSpacing.s2, height: CouliSpacing.s12 + CouliSpacing.s2)
        .meProbe("me.avatar", role: "avatar")
        .accessibilityHidden(true)
    }
}
