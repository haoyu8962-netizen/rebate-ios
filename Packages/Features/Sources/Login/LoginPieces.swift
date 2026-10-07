import DesignSystem
import SwiftUI

// MARK: - 小件

/// 品牌方块（设计稿 72×72、圆角 20）：图形，不随字号放大（AdaptLargeText200Login：Logo 不放大）；读屏跳过。
struct BrandMark: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 22, weight: .bold))
            .tracking(2)
            .foregroundColor(CouliColor.textInverse)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: 72, height: 72)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(CouliColor.brandPrimary))
            .accessibilityHidden(true)
    }
}

/// 复选框（20×20，随字号略放大）。
struct CheckBox: View {
    static let side: CGFloat = 20
    let checked: Bool
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = CheckBox.side

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous)
                .fill(checked ? CouliColor.brandPrimary : CouliColor.backgroundSurface)
            RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous)
                .strokeBorder(checked ? Color.clear : CouliColor.borderControl, lineWidth: 1.5)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.6, weight: .bold))
                    .foregroundColor(CouliColor.textInverse)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 协议链接（共性 6、8）：独立的 44pt 命中区（宽、高都不小于命中区下限），读屏为链接。
struct AgreementLinkButton: View {
    let title: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .couliFont(.footnote)
                .foregroundColor(CouliColor.brandEmphasis)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(CouliPlainButtonStyle())
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier(id)
    }
}

/// 协议行里的连接字（「和」「，」）：读屏跳过（复选框与两个链接已表达完整含义）。
struct PlainPiece: View {
    let text: String
    let primary: Bool

    init(_ text: String, primary: Bool = false) {
        self.text = text
        self.primary = primary
    }

    var body: some View {
        Text(verbatim: text)
            .couliFont(.footnote)
            .foregroundColor(primary ? CouliColor.textPrimary : CouliColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: CouliHitTarget.minimum)
            .accessibilityHidden(!primary)
    }
}
