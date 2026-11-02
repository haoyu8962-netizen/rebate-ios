import DesignSystem
import SwiftUI

// 设置一族（APP-12w-a）私有的小件：版式枚举、列表行内容、提示条、文字链接。测量经 DS 的 `couliProbe` 一族上报，没有接收方时不多画视图。

/// 共用列表件的版式（G-S02）：`standard` = 隐私中心等页面的现状，默认值；`settings` = 设置一族画板（行 min 44、卡内 4 / 16、分组名 12、箭头 20）。
enum MeListStyle {
    case standard
    case settings
}

/// 设置一族的列表行内容：标题 17 + 值 14（等宽数字）+ 箭头 20，值到箭头 4、标题到值 12；放不下时值换到标题下一行，标题不被挤窄（brief §2 第 13 条）。
/// 行高：卡内 52（画板内容盒 min 44 + 上下 4，分隔线另 1）；协议半屏传 44（画板 border-box）。
struct SettingsRowContent: View {
    static let cardRowHeight = CouliHitTarget.minimum + CouliSpacing.s2

    let title: String
    let value: String?
    let chevron: Bool
    let enabled: Bool
    let minHeight: CGFloat
    let probe: String?

    var body: some View {
        HStack(alignment: .center, spacing: CouliSpacing.s1) {
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s3, verticalSpacing: 0) {
                MeText(title, style: .body, probe: probe.map { $0 + ".title" })
                    .foregroundColor(enabled ? CouliColor.textPrimary : CouliColor.textSecondary)
                if let value, !value.isEmpty {
                    MeText(value, style: .footnote, monospacedDigits: true, probe: probe.map { $0 + ".value" })
                        .foregroundColor(CouliColor.textSecondary)
                        .couliFlowPushTrailing(.inlineOnly)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if chevron {
                CouliIconView(.chevron, size: CouliGuideMetric.iconMedium, relativeTo: .footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .meProbe(probe.map { $0 + ".chevron" }, role: "icon")
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, CouliSpacing.s1)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        .contentShape(Rectangle())
        .meProbe(probe, role: "row")
    }
}

/// 行间 1 像素分隔线（左右由所在卡片的内边距决定）。
struct SettingsDivider: View {
    let probe: String

    var body: some View {
        Rectangle()
            .fill(CouliColor.borderSubtle)
            .frame(height: CouliComponentMetric.controlBorderWidth)
            .meProbe(probe, role: "divider")
    }
}

/// 提示条骨架：圆角 12、内边距 12、图标 20 + 8 + 内容（基本模式、通知未申请、通知已拒绝）。
struct SettingsNoticeBar<Content: View>: View {
    let icon: CouliIcon
    let iconColor: Color
    let background: Color
    let probe: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: CouliSpacing.s2) {
            CouliIconView(icon, size: CouliGuideMetric.iconMedium, relativeTo: .footnote)
                .foregroundColor(iconColor)
                .meProbe(probe + ".icon", role: "icon")
                .accessibilityHidden(true)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CouliSpacing.s3)
        .background(RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous).fill(background))
        .meProbe(probe, role: "notice")
    }
}

/// 文字链接（去登录、去设置）：视觉是一行字（14/600），命中区 ≥ 44 向外扩、不撑高所在块。上方只扩 4：与上一段文字间距 8，命中区不盖文字，其余扩到下方。
/// 测量：`probe` = 文字，`hitProbe` = 命中框。
struct SettingsTextLink: View {
    private static let hitTop = CouliSpacing.s1
    private static let hitBottom = CouliHitTarget.minimum - hitTop
        - CouliTextStyle.footnote.baseSize * CouliTextStyle.footnote.lineHeightMultiple
    private static let hitSide = CouliSpacing.s3

    let title: String
    let color: Color
    let probe: String
    let hitProbe: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MeText(title, style: .footnote, weight: .couliSemibold, probe: probe)
                .foregroundColor(color)
                .underline()
                .padding(.top, Self.hitTop)
                .padding(.bottom, Self.hitBottom)
                .padding(.horizontal, Self.hitSide)
                .contentShape(Rectangle())
                .meProbe(hitProbe, role: "hit")
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small, ringInside: true))
        .padding(.top, -Self.hitTop)
        .padding(.bottom, -Self.hitBottom)
        .padding(.horizontal, -Self.hitSide)
    }
}
