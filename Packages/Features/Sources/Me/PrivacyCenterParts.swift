import DesignSystem
import SwiftUI

/// 系统权限一行（画板 PrivacyCenter，G-P16）：图标 20 + 名称 17 / 用途 12 + 状态 14 + 箭头 20，上下 12；读屏「名称，用途，状态，按钮」。
/// 可点时整行是命中区；不可点时不画箭头、不画成按钮（同 `MeRow`）。无障碍字号下状态词换到用途下面，文字不被挤窄。
struct PrivacyPermissionRow: View {
    let type: String
    let name: String
    let purpose: String?
    let status: String?
    let clickable: Bool
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var probe: String {
        "privacy.permission." + type
    }

    var body: some View {
        if clickable {
            Button(action: action) {
                content(chevron: true)
            }
            .buttonStyle(CouliPlainButtonStyle(cornerRadius: 0))
            .accessibilityIdentifier(probe)
        } else {
            content(chevron: false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(probe)
        }
    }

    private func content(chevron: Bool) -> some View {
        HStack(alignment: .center, spacing: CouliSpacing.s1) {
            HStack(alignment: .center, spacing: CouliSpacing.s3) {
                PrivacyPermissionIcon(type: type)
                    .foregroundColor(CouliColor.textSecondary)
                    .meProbe(probe + ".icon", role: "icon")
                texts
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !typeSize.isAccessibilitySize {
                statusText
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, CouliSpacing.s1)
            }
            if chevron {
                CouliIconView(.chevron, size: CouliComponentMetric.iconMedium, relativeTo: .footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .meProbe(probe + ".chevron", role: "icon")
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, CouliSpacing.s3)
        .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum, alignment: .leading)
        .contentShape(Rectangle())
        .meProbe(probe, role: "row")
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s1 / 2) {
            MeText(name, style: .body, probe: probe + ".name")
                .foregroundColor(CouliColor.textPrimary)
            if let purpose {
                MeText(purpose, style: .caption, probe: probe + ".purpose")
                    .foregroundColor(CouliColor.textSecondary)
            }
            if typeSize.isAccessibilitySize {
                statusText
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if let status {
            MeText(status, style: .footnote, probe: probe + ".status")
                .foregroundColor(CouliColor.textSecondary)
        }
    }
}

/// 权限行图标（系统图标集，D10-559）：通知铃铛、相册图片。`CouliIcon` 没有图片类，组件库本组只加可选参数，所以这里直接取系统图标，尺寸写法同 `CouliIconView`。
private struct PrivacyPermissionIcon: View {
    let type: String
    @ScaledMetric(relativeTo: .footnote) private var size = CouliComponentMetric.iconMedium

    var body: some View {
        Image(systemName: type == "push" ? CouliIcon.bell.rawValue : "photo")
            .font(.system(size: size * 0.8, weight: .regular))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
