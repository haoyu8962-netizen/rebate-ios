import SwiftUI

/// 半屏标题样式（`CouliSheet(titleStyle:)`，缺省 `.standard`）。`CouliSheet(titleLeading:)` 是标题前的装饰（缺省无；APP-06v
/// 授权半屏的 32 平台图标，读屏隐藏由调用方负责）；`CouliSheet(showsClose:)` 缺省 true，false 时不画右上关闭（APP-06v 下单须知，
/// 画板无关闭；仍可点遮罩、下滑、读屏擦除关闭，由调用方给 `couliSheet` 的关闭方式）。
public enum CouliSheetTitleStyle: Sendable {
    /// 17/600（既有半屏）。
    case standard
    /// 约 20/700（APP-06v 授权半屏、下单须知画板；令牌没有 20 档，按画板字号、随系统字号缩放，行高取 title 档倍数）。
    case prominent
    /// 22/600（title 档；APP-09v-e 实名单独同意半屏）。
    case title

    var textStyle: CouliTextStyle {
        self == .title ? .title : .body
    }

    var weight: Font.Weight {
        self == .prominent ? .couliBold : .couliSemibold
    }
}

struct SheetTitleFont: ViewModifier {
    let style: CouliSheetTitleStyle
    @ScaledMetric(relativeTo: .title3) private var prominentSize: CGFloat = 20

    func body(content: Content) -> some View {
        switch style {
        case .standard:
            content.couliFont(.body, weight: .couliSemibold)
        case .title:
            content.couliFont(.title, weight: .couliSemibold)
        case .prominent:
            let lineHeight = prominentSize * CouliTextStyle.title.lineHeightMultiple
            content
                .font(.system(size: prominentSize, weight: .couliBold))
                .lineSpacing(max(lineHeight - CouliFontMetrics.lineHeight(prominentSize), 0))
        }
    }
}

/// 正文区：放得下时按内容高；放不下时占满剩余高度并滚动（头部与操作区固定，adaptation-a11y-spec §4）。
struct ScrollingBody<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView {
                content
            }
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
