import DesignSystem
import HomeCore
import SwiftUI

/// 一张区段卡（Main 稿）。颜色、圆角、阴影、字号一律取令牌（深色模式随令牌映射，不写死色值）。
struct HomeSectionView: View {
    let section: HomeSectionUi
    let controller: HomeController
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        switch section.type {
        case "banner": HomeBanner(section: section, controller: controller)
        case "notice_bar": HomeNoticeView(section: section, controller: controller)
        case "product_scroll":
            // 白卡左、上、下留 16，右侧不留：横滑卡贴到卡边（Main 稿「今日精选」）
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                header.padding(.trailing, CouliSpacing.s4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: CouliSpacing.s3) {
                        ForEach(section.items) { item in
                            HomeProductTile(item: item, controller: controller, framed: false)
                                .frame(width: size.isAccessibilitySize ? 270 : 144)
                        }
                    }
                    .padding(.trailing, CouliSpacing.s4)
                }
            }
            .padding([.top, .bottom, .leading], CouliSpacing.s4)
            .homeCard()
        case "product_grid":
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                header
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: CouliSpacing.s3, alignment: .top),
                                   count: size.isAccessibilitySize ? 1 : 2),
                    alignment: .leading, spacing: CouliSpacing.s3
                ) {
                    ForEach(section.items) { HomeProductTile(item: $0, controller: controller, framed: false) }
                }
            }
            .padding(CouliSpacing.s4)
            .homeCard()
        case "icon_grid":
            // 列数按 props 的 columns，不随屏宽增加；格间距 竖 16 / 横 8（Main 稿金刚区）
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: CouliSpacing.s2, alignment: .top),
                               count: section.columns),
                spacing: CouliSpacing.s4
            ) {
                ForEach(section.items) { HomeIconCell(item: $0, controller: controller) }
            }
            .padding(CouliSpacing.s4)
            .homeCard()
        default:
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                header
                let count = size.isAccessibilitySize ? 1 : max(1, section.items.count)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: CouliSpacing.s3, alignment: .top),
                                   count: count),
                    spacing: CouliSpacing.s3
                ) {
                    ForEach(section.items) { HomeActivityCell(item: $0, controller: controller) }
                }
            }
        }
    }

    /// 区段标题 17/600 +「更多 ›」（Main 稿）。没有标题的区段不画。
    @ViewBuilder private var header: some View {
        if let title = section.title {
            HStack(alignment: .center, spacing: CouliSpacing.s3) {
                Text(verbatim: title).couliFont(.body, weight: .semibold).foregroundColor(CouliColor.textPrimary)
                    .lineLimit(2).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let more = section.more {
                    Button { controller.open(more) } label: {
                        HStack(spacing: 0) {
                            Text(verbatim: controller.text("home.more")).couliFont(.footnote)
                            CouliIconView(.chevron, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                        }
                        .foregroundColor(CouliColor.textLink)
                        .frame(minHeight: CouliHitTarget.minimum).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

extension View {
    /// 首页区段白卡：surface 底、卡片圆角 16、卡片阴影（令牌 shadow.card）。内边距由调用方先给。
    func homeCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                    .fill(CouliColor.backgroundSurface)
                    .couliShadow(.card)
            )
    }

    /// 点得到才是按钮；没有目标的条目按普通内容画（不用禁用按钮：系统会把禁用态整块压淡、文字变灰）。
    @ViewBuilder func homeTap(_ tap: HomeTap?, _ controller: HomeController) -> some View {
        if let tap {
            Button { controller.open(tap) } label: { self.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            self
        }
    }
}

/// 金刚区格（Main 稿）：44×44、圆角 12 的图块居中，下方格名 caption 12/18 次要色；角标在图块右上角（与 Android、鸿蒙一致）。
struct HomeIconCell: View {
    let item: HomeItemUi
    let controller: HomeController
    /// 图块固定 44×44（不随字号放大：5 列时放大会互相压住；格名随字号放大、换行不截断）。
    private let tile: CGFloat = 44
    var body: some View {
        VStack(spacing: CouliSpacing.s1) {
            HomeAdBadge(label: item.adLabel)
            tileView
                .overlay(alignment: .topTrailing) {
                    if let badge = item.badge {
                        Text(verbatim: badge).couliFont(.caption).foregroundColor(CouliColor.textInverse)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, CouliSpacing.s1)
                            .background(Capsule().fill(CouliColor.brandPrimary))
                            .alignmentGuide(.top) { $0.height / 2 }
                            .alignmentGuide(.trailing) { $0.width - CouliSpacing.s2 }
                    }
                }
            if let title = item.title {
                Text(verbatim: title).couliFont(.caption).foregroundColor(CouliColor.textSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum, alignment: .top)
        .homeTap(item.tap, controller)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(item.tap == nil ? [] : .isButton)
        .accessibilityLabel(Text(verbatim: ([item.adLabel, item.spokenName, item.badge].compactMap(\.self))
                .joined(separator: ", ")))
    }

    @ViewBuilder private var tileView: some View {
        let shape = RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
        if let image = item.image, image.hasPrefix("builtin:") {
            let name = String(image.dropFirst("builtin:".count))
            if let icon = Self.icon(name) {
                // 类目 / 指南：页面底色图块 + 墨棕线性图标（Main 稿）
                shape.fill(CouliColor.backgroundCanvas).frame(width: tile, height: tile)
                    .overlay(
                        CouliIconView(icon).foregroundColor(CouliColor.textPrimary).dynamicTypeSize(.large)
                    )
            } else {
                // 平台格：平台 logo 素材未到（TODO(N-11)），按 Main 稿画占位色图块，平台名在格名里
                shape.fill(CouliColor.backgroundPlaceholder).frame(width: tile, height: tile)
            }
        } else if item.image != nil {
            HomeItemImage(item: item, controller: controller).frame(width: tile, height: tile).clipShape(shape)
        }
    }

    /// 包内默认的类目 / 指南图标借用设计系统已有线性图标（与 Android HomeCards.builtinIcon 同一张对照表；平台格返回 nil）。
    static func icon(_ name: String) -> CouliIcon? {
        switch name {
        case "category.supermarket": .orders
        case "category.fresh": .heart
        case "category.baby": .user
        case "category.beauty": .star
        case "category.household": .home
        case "category.electronics": .trend
        case "guide": .help
        default: nil
        }
    }
}

/// 活动入口格（Main 双入口）：白卡、圆角 16、阴影，内边距 12、最小高 72；标题 14/600 最多两行，副标题 caption 次要色。
struct HomeActivityCell: View {
    let item: HomeItemUi
    let controller: HomeController
    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            HomeAdBadge(label: item.adLabel)
            if item.image != nil {
                HomeItemImage(item: item, controller: controller).frame(height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous))
            }
            if let title = item.title {
                Text(verbatim: title).couliFont(.footnote, weight: .semibold).foregroundColor(CouliColor.textPrimary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let subtitle = item.subtitle {
                Text(verbatim: subtitle).couliFont(.caption).foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let badge = item.badge {
                Text(verbatim: badge).couliFont(.caption).foregroundColor(CouliColor.textLink)
            }
        }
        .frame(maxWidth: .infinity, minHeight: CouliGuideMetric.gridCellMinHeight - CouliSpacing.s3 * 2,
               alignment: .leading)
        .padding(CouliSpacing.s3)
        .homeCard()
        .homeTap(item.tap, controller)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(item.tap == nil ? [] : .isButton)
        .accessibilityLabel(Text(verbatim: ([item.adLabel, item.spokenName, item.subtitle, item.badge]
                .compactMap(\.self)).joined(separator: ", ")))
    }
}

/// 「推广」角标（BR-TEXT-17 原样显示、读屏读出）：白底胶囊、装饰描边，caption 次要色，高 22（Main 稿）。
struct HomeAdBadge: View {
    let label: String?
    var body: some View {
        if let label {
            Text(verbatim: label).couliFont(.caption).foregroundColor(CouliColor.textSecondary)
                .fixedSize()
                .padding(.horizontal, CouliSpacing.s2)
                .frame(minHeight: CouliGuideMetric.tagMinHeight)
                .background(Capsule(style: .circular).fill(CouliColor.backgroundSurface))
                .overlay(Capsule(style: .circular).strokeBorder(CouliColor.borderSubtle,
                                                                lineWidth: CouliComponentMetric.controlBorderWidth))
        }
    }
}

struct HomeItemImage: View {
    let item: HomeItemUi
    let controller: HomeController
    var body: some View {
        let ticket = item.imageTicket
        // 图片叠在占位色上、按占位的框裁切：scaledToFill 的大图不会把框撑大（否则叠在框角上的「推广」被挤出可见区域）
        CouliColor.backgroundPlaceholder
            .overlay {
                if !item.imageFailed {
                    ProductRemoteImage(url: ProductImageSource.url(item.image)) { phase in
                        if let ticket, phase == .loaded || phase == .failed {
                            controller.imageLoaded(ticket, ok: phase == .loaded)
                        }
                    }
                }
            }
            .clipped()
            .accessibilityLabel(Text(verbatim: item.spokenName))
    }
}

struct HomeProductTile: View {
    let item: HomeItemUi
    let controller: HomeController
    var framed = true
    var body: some View {
        if let product = item.product {
            let mapped = ProductCardMapper.map(
                product.fields.mapValues(\.anyValue),
                texts: controller.text,
                buyEnabled: false
            )
            ProductGridCard(mapped.data, framed: framed) {
                HomeItemImage(item: item, controller: controller)
                    .overlay(alignment: .topLeading) { HomeAdBadge(label: item.adLabel).padding(CouliSpacing.s2) }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let tap = item.tap {
                    controller.open(tap)
                }
            }
            .accessibilityAction {
                if let tap = item.tap {
                    controller.open(tap)
                }
            }
        }
    }
}
