import DesignSystem
import SwiftUI
import UIKit
import WalletCore

// 提现记录（APP-09v-b，画板 WithdrawRecords-v2 一族）页面私有的小件：带测量的令牌文字、状态胶囊、1pt 分隔线、骨架。
// 测量编号经 DesignSystem 的 `couliProbe` 一族上报（没有接收方时原样返回、不多画任何视图；Release 没有接收方）。

/// 令牌字号的文字（缺省可折行；`singleLine` 时不折行、不截断），连同实际字号与单行自然宽一起上报测量。
/// 自然宽按同一字体（系统字体、同字重、等宽数字设置）用 UIFont 量（APP-06v K6 / APP-09v-a K4：不靠隐藏副本的布局回调）。
struct RecordText: View {
    private let text: String
    private let style: CouliTextStyle
    private let weight: Font.Weight
    private let color: Color
    private let monospacedDigits: Bool
    private let singleLine: Bool
    private let alignment: TextAlignment
    private let probe: String?
    @ScaledMetric private var size: CGFloat
    @Environment(\.couliLayoutProbe) private var receiver

    init(_ text: String, style: CouliTextStyle, weight: Font.Weight = .regular, color: Color,
         monospacedDigits: Bool = false, singleLine: Bool = false, alignment: TextAlignment = .leading,
         probe: String? = nil) {
        self.text = text
        self.style = style
        self.weight = weight
        self.color = color
        self.monospacedDigits = monospacedDigits
        self.singleLine = singleLine
        self.alignment = alignment
        self.probe = probe
        _size = ScaledMetric(wrappedValue: style.baseSize, relativeTo: style.relativeTo)
    }

    var body: some View {
        let font = Font.system(size: size, weight: weight)
        let label = Text(verbatim: text)
            .font(monospacedDigits ? font.monospacedDigit() : font)
            // 多行行距按令牌行高（r1 S2-3：14 → 21、12 → 18、17 → 25.5）。DS `couliFont` 按苹方行高扣行距，
            // 而这里实际排版用系统字体（中文回落苹方但行高仍按系统字体），多行每行矮约 2pt；页面私有修正，不改 DS 默认。
            .lineSpacing(singleLine ? 0 : RecordMeasure.lineSpacing(style, size: size, weight: weight,
                                                                    monospacedDigits: monospacedDigits))
            .foregroundColor(color)
            .multilineTextAlignment(alignment)
            .lineLimit(singleLine ? 1 : nil)
            .fixedSize(horizontal: singleLine, vertical: true)
            // 单行也按令牌行高占位（画板 line-height：17 → 25.5、14 → 21、12 → 18）
            .couliLineBox(style)
        if let probe, receiver != nil {
            label.couliTextProbe(probe, role: "text", text: text, fontSize: size, baseFontSize: style.baseSize,
                                 naturalWidth: RecordMeasure.width(text, size: size, weight: weight,
                                                                   monospacedDigits: monospacedDigits))
        } else {
            label
        }
    }
}

/// 同一字体下一段文字的单行宽度（UIFont 口径）。
enum RecordMeasure {
    static func width(_ text: String, size: CGFloat, weight: Font.Weight, monospacedDigits: Bool) -> CGFloat {
        let ui = uiWeight(weight)
        let font = monospacedDigits ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: ui)
            : UIFont.systemFont(ofSize: size, weight: ui)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// 多行行距 = 令牌行高（字号 × 行高倍数）− 实际排版字体（系统字体，同字重、同等宽数字设置）的行高。
    static func lineSpacing(_ style: CouliTextStyle, size: CGFloat, weight: Font.Weight,
                            monospacedDigits: Bool) -> CGFloat {
        let ui = uiWeight(weight)
        let font = monospacedDigits ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: ui)
            : UIFont.systemFont(ofSize: size, weight: ui)
        return max(size * style.lineHeightMultiple - font.lineHeight, 0)
    }

    static func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .couliBold: .bold
        case .couliSemibold: .semibold
        case .couliMedium: .medium
        default: .regular
        }
    }
}

/// 状态胶囊的色调（brief §2.2 第 3 条、W21）：中性 + 钟表（审核中 / 打款中 / 处理中）；成功绿 + 对勾（已到账）；警告 + 三角（未通过 /
/// 打款未成功）。底色取状态令牌（status.*.background），字与图标同色。
struct RecordTone {
    let background: Color
    let ink: Color
    let icon: CouliIcon

    static func of(_ status: String) -> RecordTone {
        if WithdrawalText.isPaid(status) {
            return RecordTone(background: CouliColor.statusSuccessBackground, ink: CouliColor.statusSuccessText,
                              icon: .check)
        }
        if status == "REJECTED" || status == "FAILED" {
            return RecordTone(background: CouliColor.statusWarningBackground, ink: CouliColor.statusWarningText,
                              icon: .alert)
        }
        return RecordTone(background: CouliColor.token("status.pending.background"), ink: CouliColor.textSecondary,
                          icon: .clock)
    }
}

/// 状态胶囊：高 22（大字号时增高）、左右 8、14 图标 + 12 字（不折行、不截断）。测量：`probe` 外框、`.icon`、`.text`。
/// 图标按画板 14 方框画满（画板 SVG 线框占满 14 视框；`CouliIconView` 的字形只占 0.8，钟表 / 对勾 / 三角在 14 下难以分辨）。
struct RecordStatusPill: View {
    let status: String
    let title: String
    let probe: String
    @ScaledMetric(relativeTo: .caption) private var icon: CGFloat = CouliComponentMetric.iconSmall

    var body: some View {
        let tone = RecordTone.of(status)
        HStack(spacing: CouliSpacing.s1) {
            Image(systemName: tone.icon.rawValue)
                .resizable()
                .scaledToFit()
                .frame(width: icon, height: icon)
                .accessibilityHidden(true)
                .walletProbe(probe + ".icon", role: "icon")
            RecordText(title, style: .caption, color: tone.ink, singleLine: true, probe: probe + ".text")
        }
        .foregroundColor(tone.ink)
        .padding(.horizontal, CouliSpacing.s2)
        .frame(minHeight: CouliComponentMetric.tagMinHeight)
        .background(Capsule(style: .circular).fill(tone.background))
        .walletProbe(probe, role: "pill")
        .accessibilityHidden(true)
    }
}

/// 卡内 1pt 分隔线（border.subtle 令牌色）。
struct RecordDivider: View {
    var body: some View {
        Rectangle()
            .fill(CouliColor.borderSubtle)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// 白卡外观（surface 底、卡片圆角与阴影；展开卡另加 1 描边，画板 WithdrawRecordsPending-v2）。
struct RecordCardBackground: ViewModifier {
    var bordered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                    .fill(CouliColor.backgroundSurface)
                    .couliShadow(.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                    .strokeBorder(bordered ? CouliColor.borderSubtle : .clear, lineWidth: 1)
            )
    }
}

extension View {
    func recordCard(bordered: Bool = false) -> some View {
        modifier(RecordCardBackground(bordered: bordered))
    }
}

/// 记录骨架（首次加载 3 行、翻页中 1 行，W35）：同收起行结构（金额块 + 胶囊块、时间账号块、副文案块），行间分隔线，白卡里。
/// 整卡读屏一次「加载中」。测量：`probe` 卡、`probe.row.<n>`（`rows` > 1 时）。
struct RecordSkeleton: View {
    let rows: Int
    let probe: String
    let label: String

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { index in
                if index > 0 {
                    RecordDivider()
                        .padding(.horizontal, CouliSpacing.s4)
                }
                row
                    .walletProbe(rows > 1 ? "\(probe).row.\(index)" : nil, role: "skeleton")
            }
        }
        .frame(maxWidth: .infinity)
        .recordCard()
        .walletProbe(probe, role: "skeleton")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityIdentifier(probe)
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            HStack {
                block(width: 80, height: 20)
                    .frame(height: CouliTextStyle.body.baseSize * CouliTextStyle.body.lineHeightMultiple)
                Spacer(minLength: CouliSpacing.s2)
                Capsule(style: .circular)
                    .fill(CouliColor.backgroundMuted)
                    .frame(width: 56, height: CouliComponentMetric.tagMinHeight)
            }
            block(width: 150, height: 12)
                .frame(height: CouliTextStyle.caption.baseSize * CouliTextStyle.caption.lineHeightMultiple)
            block(width: 240, height: 14)
                .frame(height: CouliTextStyle.footnote.baseSize * CouliTextStyle.footnote.lineHeightMultiple)
        }
        .padding(.vertical, CouliSpacing.s3)
        .padding(.horizontal, CouliSpacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func block(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous)
            .fill(CouliColor.backgroundMuted)
            .frame(maxWidth: width)
            .frame(height: height)
    }
}
