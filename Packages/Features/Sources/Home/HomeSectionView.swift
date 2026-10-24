import DesignSystem
import HomeCore
import SwiftUI

/// 一张区段卡（Main-v3）。颜色、圆角、阴影、字号一律取令牌（深色模式随令牌映射，不写死色值）。
struct HomeSectionView: View {
    let section: HomeSectionUi
    let controller: HomeController
    /// 内容列宽（≤ 600）：网格列数与横滑卡宽按它与字号量。
    let column: CGFloat
    /// 列表行位置记录（宽度变化时保留滚动锚点）；nil 不记录。
    var rows: HomeRowFrames?
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        card.background {
            if let rows {
                rows.tracker(section.key)
            }
        }
    }

    @ViewBuilder private var card: some View {
        switch section.type {
        case "banner": HomeBanner(section: section, controller: controller)
        case "notice_bar": HomeNoticeView(section: section, controller: controller)
        case "product_scroll":
            // 整段放进白卡：标题行在卡内；横滑区左对齐卡内边距、右侧出血（Main-v3「今日精选」）
            let width = max(HomeProductTile.scrollMinWidth,
                            HomeProductTile.requiredWidth(section.items, style: .scroll, size: size, owner: controller))
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                header.padding(.trailing, CouliSpacing.s4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: CouliSpacing.s3) {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            HomeProductTile(item: item, controller: controller, style: .scroll, index: index,
                                            width: width)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, CouliSpacing.s4)
                }
            }
            .padding([.top, .bottom, .leading], CouliSpacing.s4)
            .homeCard()
        case "product_grid":
            // 整段放进白卡：标题 17/600 在卡内；2 列（最宽金额放不下时整组单列），卡内商品不再各自套卡
            let available = column - CouliSpacing.s4 * 2
            let columns = HomeVisualRules.gridColumns(
                availableWidth: available,
                requiredItemWidth: HomeProductTile.requiredWidth(section.items, style: .grid, size: size,
                                                                 owner: controller),
                spacing: CouliSpacing.s3
            )
            // 不用懒加载网格：区段商品不多（limit ≤ 20），单列时下方的卡也要实际布局（测量、读屏遍历都要拿到）
            let rows = stride(from: 0, to: section.items.count, by: columns).map { start in
                Array(section.items.enumerated())[start..<min(start + columns, section.items.count)]
            }
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                header
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: CouliSpacing.s3) {
                        ForEach(Array(row), id: \.element.id) { index, item in
                            HomeProductTile(item: item, controller: controller, style: .grid, index: index)
                                .frame(maxWidth: .infinity)
                        }
                        if row.count < columns {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(CouliSpacing.s4)
            .homeCard()
        case "icon_grid":
            // 列数按 props 的 columns，不随屏宽增加；格间距 竖 16 / 横 8（Main-v3 金刚区）
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: CouliSpacing.s2, alignment: .top),
                               count: section.columns),
                spacing: CouliSpacing.s4
            ) {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    HomeIconCell(item: item, controller: controller)
                        .couliProbe("home.icon.\(section.id).\(index)", role: "icon-cell")
                }
            }
            .padding(CouliSpacing.s4)
            .homeCard()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.section.\(section.id)")
        default:
            // 活动入口：2 列等宽白卡（无标题）；只有一张时占整行
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                header
                let count = size.isAccessibilitySize ? 1 : max(1, min(2, section.items.count))
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

    /// 区段标题 17/600 +「更多 ›」强调色 14（命中区 44，Main-v3）。没有标题的区段不画。
    @ViewBuilder private var header: some View {
        if let title = section.title {
            HStack(alignment: .center, spacing: CouliSpacing.s3) {
                Text(verbatim: title).couliFont(.body, weight: .couliSemibold).foregroundColor(CouliColor.textPrimary)
                    .lineLimit(2).accessibilityAddTraits(.isHeader)
                    .couliLineBox(.body)
                Spacer(minLength: 0)
                if let more = section.more {
                    Button { controller.open(more) } label: {
                        HStack(spacing: 0) {
                            Text(verbatim: controller.text("home.more")).couliFont(.footnote)
                            CouliIconView(.chevron, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                        }
                        .foregroundColor(CouliColor.textLink)
                        .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.more.\(section.id)")
                    .couliProbe("home.more.\(section.id)", role: "independent-hit")
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

/// 金刚区格（Main-v3）：44 图 + 4 + 12 号次要色格名；角标在图块右上角。读屏整格一项读格名。
/// - 平台格：官方平台图标 44 原图（BR-TEXT-24，不改色不描边，深色不变；F-X-05a `PlatformIcon`），来源按
///   `HomeVisualRules.platformIconSource`：下发图 → 包内官方图 → 文字兜底；
/// - 类目格：44 圆角 12 的页面底色图块 + 24 线性内容图标（主文字色，G-V08 照画板路径）；
/// - 其余下发图：按图显示，失败露占位底。
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
                    .couliLineBox(.caption)
            }
        }
        .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum, alignment: .top)
        // 整格一项：先把格内合成一个读屏元素，再包成按钮（按钮自带按钮角色；不在按钮外再套一层元素，避免格名读两次）
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ([item.adLabel, item.spokenName, item.badge].compactMap(\.self))
                .joined(separator: ", ")))
        .homeTap(item.tap, controller)
    }

    /// 平台格的平台编码（`builtin:platform.<code>`）；不是平台格时 nil。
    private var platformCode: String? {
        guard let image = item.image, image.hasPrefix("builtin:platform.") else { return nil }
        return String(image.dropFirst("builtin:platform.".count))
    }

    @ViewBuilder private var tileView: some View {
        let shape = RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
        if let image = item.image, image.hasPrefix("builtin:"), platformCode == nil {
            // 类目 / 指南：页面底色图块 + 墨棕线性图标（Main-v3）
            shape.fill(CouliColor.backgroundCanvas).frame(width: tile, height: tile)
                .overlay {
                    if let icon = CouliContentIcon.named(String(image.dropFirst("builtin:".count))) {
                        CouliContentIconView(icon).foregroundColor(CouliColor.textPrimary)
                    }
                }
        } else if let code = platformCode {
            switch HomeVisualRules.platformIconSource(code: code, hasRemoteImage: false, remoteFailed: false) {
            case "builtin": PlatformIcon(platformCode: code, size: .grid)
            default: textTile(shape)
            }
        } else if item.image != nil {
            HomeItemImage(item: item, controller: controller).frame(width: tile, height: tile).clipShape(shape)
        }
    }

    /// 文字兜底（没有官方图的平台）：占位底图块 + 格名首字（装饰；格名在下方读出一次）。
    private func textTile(_ shape: RoundedRectangle) -> some View {
        shape.fill(CouliColor.backgroundPlaceholder).frame(width: tile, height: tile)
            .overlay(
                Text(verbatim: String((item.title ?? "").prefix(2))).couliFont(.caption, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textSecondary).lineLimit(1).minimumScaleFactor(0.5)
                    .padding(CouliSpacing.s1)
            )
            .accessibilityHidden(true)
    }
}

/// 活动入口格（Main-v3 双入口）：白卡、圆角 16、阴影，内边距 12、最小高 72；标题 14/600 最多两行，副标题 12 次要色。
/// 步骤点 / 圆底小图标等装饰无契约字段（G-V04），不做。
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
                Text(verbatim: title).couliFont(.footnote, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .couliLineBox(.footnote)
            }
            if let subtitle = item.subtitle {
                Text(verbatim: subtitle).couliFont(.caption).foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .couliLineBox(.caption)
            }
            if let badge = item.badge {
                Text(verbatim: badge).couliFont(.caption).foregroundColor(CouliColor.textLink)
            }
        }
        .frame(maxWidth: .infinity, minHeight: CouliGuideMetric.gridCellMinHeight - CouliSpacing.s3 * 2,
               alignment: .leading)
        .padding(CouliSpacing.s3)
        .homeCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ([item.adLabel, item.spokenName, item.subtitle, item.badge]
                .compactMap(\.self)).joined(separator: ", ")))
        .homeTap(item.tap, controller)
    }
}

/// 「推广」角标（BR-TEXT-17 原样显示、读屏读出）：白底胶囊、装饰描边，caption 次要色，高 22（Main 稿）。
struct HomeAdBadge: View {
    let label: String?
    /// 是否单独可读（商品卡为 false：原文由整卡读名读一次）。
    var spoken = true
    var body: some View {
        if let label {
            Text(verbatim: label).couliFont(.caption).foregroundColor(CouliColor.textSecondary)
                .fixedSize()
                .padding(.horizontal, CouliSpacing.s2)
                .frame(minHeight: CouliGuideMetric.tagMinHeight)
                .background(Capsule(style: .circular).fill(CouliColor.backgroundSurface))
                .overlay(Capsule(style: .circular).strokeBorder(CouliColor.borderSubtle,
                                                                lineWidth: CouliComponentMetric.controlBorderWidth))
                // 商品卡上的角标原文已拼进整卡读名（HomeProductTile.spokenLabel），不再单独可读，避免读两次。整卡合并读屏后子元素
                // 仍出现在自动化树里（隐藏标记不去掉它），所以同时清空它自己的读名
                .accessibilityLabel(Text(verbatim: spoken ? label : ""))
                .accessibilityHidden(!spoken)
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

/// 首页商品卡（DesignSystem `HomeProductCard` 的首页接线）：横滑 / 网格 / 信息流三种排法，图片带「推广」角标左上 8。
/// 整卡点击经控制器打开商品（路由不变）；横滑卡读屏名按 `HomeVisualRules.scrollAccessibilityLabel`。
struct HomeProductTile: View {
    let item: HomeItemUi
    let controller: HomeController
    let style: HomeProductCardStyle
    let index: Int
    var width: CGFloat?

    /// 横滑卡最窄宽度（Main-v3 实测 144）；长金额 / 大字号按金额加宽。
    static let scrollMinWidth: CGFloat = 144

    static func data(_ item: HomeItemUi, owner: HomeController) -> ProductCardData? {
        item.product.map {
            ProductCardMapper.map($0.fields.mapValues(\.anyValue), texts: owner.text, buyEnabled: false).data
        }
    }

    /// 一组商品在当前字号下不截断金额所需的卡宽（取最宽的一张）。
    static func requiredWidth(_ items: [HomeItemUi], style: HomeProductCardStyle, size: DynamicTypeSize,
                              owner: HomeController) -> CGFloat {
        items.compactMap { data($0, owner: owner) }
            .map { HomeProductCardMetrics.requiredWidth($0, style: style, dynamicTypeSize: size) }
            .max() ?? 0
    }

    /// 整卡读屏名：卡上画出的推广标识（服务端 `ad_label` 原文，BR-TEXT-17）放在最前、只读一次（整卡合并读屏后角标本身不再单独
    /// 读）；其后横滑卡按 `HomeVisualRules.scrollAccessibilityLabel`，网格 / 信息流按组件库读名。读名里已有同一段文字时不重复。
    static func spokenLabel(_ data: ProductCardData, style: HomeProductCardStyle, adLabel: String?) -> String {
        let base = style == .scroll ? HomeVisualRules.scrollAccessibilityLabel(data)
            : HomeProductCardMetrics.accessibilityLabel(data)
        let label = adLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !label.isEmpty, !base.components(separatedBy: PriceTerms.spokenPause).contains(label) else { return base }
        return base.isEmpty ? label : label + PriceTerms.spokenPause + base
    }

    var body: some View {
        if let data = Self.data(item, owner: controller) {
            let tap = item.tap
            HomeProductCard(
                data, style: style, index: index, width: width,
                spokenLabel: Self.spokenLabel(data, style: style, adLabel: item.adLabel),
                onOpen: tap.map { tap in { controller.open(tap) } }
            ) {
                HomeItemImage(item: item, controller: controller)
                    .accessibilityHidden(true)
                    .overlay(alignment: .topLeading) {
                        HomeAdBadge(label: item.adLabel, spoken: false).padding(CouliSpacing.s2)
                    }
            }
        }
    }
}
