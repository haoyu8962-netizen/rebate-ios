import SwiftUI

/// 半屏标题样式（`CouliSheet(titleStyle:)`，缺省 `.standard`）。`CouliSheet(titleLeading:)` 是标题前的装饰（缺省无；APP-06v
/// 授权半屏的 32 平台图标，读屏隐藏由调用方负责）；`CouliSheet(showsClose:)` 缺省 true，false 时不画右上关闭（APP-06v 下单须知，
/// 画板无关闭；仍可点遮罩、下滑、读屏擦除关闭，由调用方给 `couliSheet` 的关闭方式）。
public enum CouliSheetTitleStyle: Sendable {
    /// 17/600（既有半屏）。
    case standard
    /// 约 20/700（APP-06v 授权半屏、下单须知画板；令牌没有 20 档，按画板字号、随系统字号缩放，行高取 title 档倍数）。
    case prominent
}

struct SheetTitleFont: ViewModifier {
    let style: CouliSheetTitleStyle
    @ScaledMetric(relativeTo: .title3) private var prominentSize: CGFloat = 20

    func body(content: Content) -> some View {
        switch style {
        case .standard:
            content.couliFont(.body, weight: .couliSemibold)
        case .prominent:
            let lineHeight = prominentSize * CouliTextStyle.title.lineHeightMultiple
            content
                .font(.system(size: prominentSize, weight: .couliBold))
                .lineSpacing(max(lineHeight - CouliFontMetrics.lineHeight(prominentSize), 0))
        }
    }
}

/// 可选的可访问标识（nil 时不加，既有调用方不变）。
struct SheetOptionalIdentifier: ViewModifier {
    let id: String?

    func body(content: Content) -> some View {
        if let id {
            content.accessibilityIdentifier(id)
        } else {
            content
        }
    }
}

/// 无标题半屏的容器读屏名（有标题时不加，与既有半屏一致）。
struct SheetPaneName: ViewModifier {
    let name: String?

    func body(content: Content) -> some View {
        if let name {
            content.accessibilityLabel(Text(verbatim: name))
        } else {
            content
        }
    }
}
