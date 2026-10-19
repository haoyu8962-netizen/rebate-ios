import SwiftUI
import UIKit

/// 品牌 Logo 的版式（规划仓库 design/logo/README.md「文件」表）。
public enum CouliLogoVariant: String, CaseIterable, Sendable {
    /// 主图形（画布 256 × 256）。建议最小显示 24 × 24 pt。
    case mark = "logo-mark"
    /// 横向组合：图形 + 中文字标（画布 580 × 256）。建议最小宽 112 pt；更窄的地方用 `mark`。
    case horizontal = "logo-horizontal"

    /// 资源目录里的图片集名（本包 Resources/Brand.xcassets）。
    public var assetName: String {
        rawValue
    }

    /// 原始画布宽高比（宽 / 高），与 SVG 源文件的 viewBox 一致。
    public var aspectRatio: CGFloat {
        switch self {
        case .mark: 1
        case .horizontal: 580.0 / 256.0
        }
    }

    /// 按外观取图（测试与非 SwiftUI 场景用）：浅色是原色版，深色是反白版（同一图片集的 Dark 外观）。
    public func uiImage(dark: Bool) -> UIImage? {
        UIImage(
            named: assetName,
            in: .module,
            compatibleWith: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        )
    }
}

/// 品牌 Logo（BRAND-01）：只是取用入口，不决定页面摆放（登录等页面的位置以定稿画板为准）。
///
/// 资源是规划仓库 design/logo/source 的 SVG 原文件（保留矢量）。浅 / 深自动选图：图片集的 Any 外观是原色版，
/// Dark 外观是反白版，跟随当前视图环境的配色（App 目前在 Info.plist 固定浅色，深色接入后自动换反白）。
/// 等比缩放、不拉伸；四周留白由调用方按 Logo 规范排版。
public struct CouliLogo: View {
    private let variant: CouliLogoVariant
    private let accessibilityText: String?

    /// - Parameters:
    ///   - accessibilityText: 读屏文本（由调用方经文案字典取）；不给则视为装饰图，对读屏隐藏。
    public init(_ variant: CouliLogoVariant = .mark, accessibilityText: String? = nil) {
        self.variant = variant
        self.accessibilityText = accessibilityText
    }

    public var body: some View {
        let image = Image(variant.assetName, bundle: .module)
            .resizable()
            .aspectRatio(variant.aspectRatio, contentMode: .fit)
        if let accessibilityText {
            image
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: accessibilityText))
                .accessibilityAddTraits(.isImage)
        } else {
            image.accessibilityHidden(true)
        }
    }
}
