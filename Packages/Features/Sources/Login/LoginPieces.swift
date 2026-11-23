import DesignSystem
import SwiftUI

// MARK: - 小件

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
