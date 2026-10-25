import SwiftUI
import UIKit

// 商品详情页主体（APP-06v-a，App 内高保真第 1 批定稿 Product-v2 / ProductJd / ProductOffShelf-v3 /
// ProductPriceCompareCancelled-v2）：头图、价格大卡、口径块。旧的 ProductHeroImage / ProductDetailHeader / DisclaimerFooter(.boxed)
// 保持不变（DS 目录基准不动），详情页改用这里的新件。测量编号（product.*）只在有测量接收方时上报（Release 没有接收方）。

// MARK: - 头图

/// 详情头图（GUIDE §6「详情头图完整显示 contain」，画板 358 × 264、圆角 8、1 描边）：占位底 + 商品图完整显示，
/// 两侧 / 上下露出占位底；加载中、为空、失败只显示占位底。单图（契约 image，G-D03）。
/// - `adLabel`：BR-TEXT-17 推广标识原文（非 null 才给），左上 8 白底描边角标（G-D04），读屏读在图名之前、只读一次。
/// - `grayscale`：下架原位置灰（ProductOffShelf-v3）：整块头图去色（商品图、占位底、描边一起饱和度 0；不是加蒙层）。
public struct ProductDetailHero: View {
    /// 画板 Product-v2 头图框 358 × 264（含描边）。
    public static let aspectRatio: CGFloat = 358.0 / 264.0

    private let url: URL?
    private let accessibilityLabel: String
    private let adLabel: String?
    private let grayscale: Bool
    @State private var phase: ProductImagePhase = .none

    public init(url: URL?, accessibilityLabel: String, adLabel: String? = nil, grayscale: Bool = false) {
        self.url = url
        self.accessibilityLabel = accessibilityLabel
        self.adLabel = adLabel
        self.grayscale = grayscale
    }

    /// 读屏名：有角标时角标原文在前（「广告 · 平台原文，商品图片，{标题}」）。
    static func spoken(_ label: String, adLabel: String?) -> String {
        adLabel.map { $0 + PriceTerms.spokenPause + label } ?? label
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous)
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            CouliColor.backgroundPlaceholder
            ProductRemoteImage(url: url, contentMode: .fit) { phase = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let adLabel {
                CouliTag(adLabel, style: .outline)
                    .fixedSize()
                    .couliProbe("product.adLabel", role: "ad-label", text: adLabel)
                    .padding(CouliSpacing.s2)
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(CouliColor.borderSubtle, lineWidth: CouliComponentMetric.controlBorderWidth))
        // 下架：整块头图去色（商品图饱和度 0；深色占位底本身带一点暖色，也一并去色，整块读作「灰掉」）
        .modifier(ProductGrayscale(enabled: grayscale))
        .couliProbe("product.hero", role: "hero")
        // 读屏只有一项图片「（角标原文，）商品图片，{标题}」。用 accessibilityRepresentation 而不是
        // accessibilityElement(children: .ignore)：后者在 XCUI 无障碍树里仍把角标文字挂成子节点（同 PlatformBadge）。
        .accessibilityRepresentation {
            Image(uiImage: UIImage())
                .accessibilityLabel(Text(verbatim: Self.spoken(accessibilityLabel, adLabel: adLabel)))
        }
        // UI 测试据此核对加载结果（成功显示图片、失败与为空显示占位）。
        .accessibilityIdentifier("product.image.\(phase.rawValue)")
    }
}

/// 去色（饱和度 0，不是加蒙层）；关闭时不加任何修饰。
struct ProductGrayscale: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.saturation(0)
        } else {
            content
        }
    }
}

// MARK: - 金额段

// MARK: - 价格大卡

/// 商品详情价格大卡（GUIDE §7.2「商品详情」，画板 Product-v2）：口径词 14 + 主价 34/700 → 副行 12（券前 · 券 / 无券）→
/// 紧挨其下大号返利标签（+ 区间「以结算为准」）与「预估返后 · 取价」（两者间距 8）→ 优惠标签 → 分隔线 → 来源 + 标题 17/600 → 店铺。
/// - `rebateOverride`：比价无返利原因行（ProductPriceCompareCancelled-v2）放在返利标签的位置、替代返利标签。
/// - `offShelfLabel`：下架原位置灰（ProductOffShelf-v3）：卡顶灰胶囊、标题与店铺次要色，价格 / 返利 / 预估返后 / 取价 /
///   优惠标签 / 分隔线全部不显示；读屏卡片读「商品已下架，{平台}，{标题}」。
/// - `width`：卡片外框宽，由页面按视口宽算出（不受内容撑宽）；给了才对超长金额做退档判断。
/// 判定全部来自 `ProductCardData`（映射不变），这里只排版。
public struct ProductDetailCard: View {
    private let data: ProductCardData
    private let fetchedAt: String?
    private let shopName: String?
    private let staleNote: String?
    private let offShelfLabel: String?
    private let rebateOverride: AnyView?
    private let width: CGFloat?

    public init(
        _ data: ProductCardData,
        fetchedAt: String? = nil,
        shopName: String? = nil,
        staleNote: String? = nil,
        offShelfLabel: String? = nil,
        rebateOverride: AnyView? = nil,
        width: CGFloat? = nil
    ) {
        self.width = width
        self.data = data
        self.fetchedAt = fetchedAt
        self.shopName = shopName
        self.staleNote = staleNote
        self.offShelfLabel = offShelfLabel
        self.rebateOverride = rebateOverride
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            if let offShelfLabel {
                offShelf(offShelfLabel)
            } else {
                if !data.hidesPrice {
                    priceBlock
                }
                rebateBlock
                notesAndTags
                Rectangle()
                    .fill(CouliColor.borderSubtle)
                    .frame(height: CouliComponentMetric.controlBorderWidth)
                    .accessibilityHidden(true)
                titleBlock(color: CouliColor.textPrimary)
            }
        }
        // 金额可用宽 = 卡片外框宽（调用方从页面视口 / 内容列算出，不随内容撑宽）− 左右内边距
        .environment(\.productAmountWidth, width.map { $0 - CouliSpacing.s4 * 2 })
        .couliCard()
        .couliProbe("product.card", role: "card")
    }

    // MARK: 价格

    private var priceBlock: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            mainPrice
            subLine
        }
    }

    private var priceLabel: some View {
        Text(verbatim: data.price.mainLabel)
            .couliFont(.footnote)
            .foregroundColor(CouliColor.textSecondary)
            .fixedSize()
    }

    private var priceAmount: some View {
        ProductDetailAmount(text: data.price.mainAmount, style: .display, weight: .couliBold,
                            probeID: "product.amount.price")
            .foregroundColor(CouliColor.priceText)
    }

    /// 口径词与主价按基线对齐；放不下时口径词在上、主价在下（不缩字号、不截断）。用同一组子视图的布局切换，
    /// 不换视图身份（测量与读屏不因切换重建）。
    private var mainPrice: some View {
        ProductPriceRowLayout(spacing: CouliSpacing.s1) {
            if !data.price.mainLabel.isEmpty {
                priceLabel
            }
            priceAmount
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: data.price.mainAccessibilityText))
    }

    /// 副行：「券前 ¥x · 券 ¥y」两段各自成块（段间优先折行）；无券写「无券」；主价没有口径词（价格待补齐）时不写。
    @ViewBuilder private var subLine: some View {
        if !data.price.mainLabel.isEmpty {
            if let sub = data.price.subLine {
                let segments = sub.components(separatedBy: PriceTerms.separator)
                let dot = PriceTerms.separator.trimmingCharacters(in: .whitespaces)
                CouliFlowLayout(horizontalSpacing: CouliSpacing.s1, verticalSpacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        let parts = ProductDetailLabeledAmount.split(segment)
                        ProductDetailLabeledAmount(
                            label: index == 0 ? parts.label : dot + " " + parts.label,
                            amount: parts.amount,
                            style: .caption,
                            probeID: index == 0 ? "product.amount.before" : "product.amount.coupon"
                        )
                    }
                }
                .foregroundColor(CouliColor.textSecondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: data.price.subLineAccessibilityText ?? sub))
            } else {
                Text(verbatim: PriceTerms.noCoupon)
                    .couliFont(.caption)
                    .foregroundColor(CouliColor.textSecondary)
            }
        }
    }

    // MARK: 返利

    @ViewBuilder private var rebateBlock: some View {
        if let unavailable = data.priceUnavailableText {
            // 价格不可用（BR-PRICE-01；APP-06a 共性 1）：不显示任何金额与取价时间，只显示这句（比价原因行仍可替代返利位置）。
            Text(verbatim: unavailable)
                .couliFont(.body, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let rebateOverride {
                rebateOverride
            }
        } else {
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                if let rebateOverride {
                    rebateOverride
                } else if data.showsRebate {
                    rebateRow
                }
                metaRow
            }
        }
    }

    /// 返利大标签 + 区间时「以结算为准」：读屏一项、读完整句（「预估返 1.23 元到 2.34 元，以结算为准」）。
    private var rebateRow: some View {
        let rebate = data.rebate.hidingAmount(data.amountHidden)
        let note = (data.rebate.kind == .range && !data.amountHidden) ? data.settlementNote : nil
        let spoken = rebate.accessibilityText + (note.map { PriceTerms.spokenPause + $0 } ?? "")
        return CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s1) {
            ProductDetailRebateTag(content: rebate)
            if let note {
                Text(verbatim: note)
                    .couliFont(.caption)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    /// 「预估返后 ¥… 取价 hh:mm」（12 次文字，间距 12；stale 提示接在取价后）。
    @ViewBuilder private var metaRow: some View {
        let estNet = data.showsRebate
            ? EstNetLine.visibleText(data.estNet, rebate: data.rebate, amountHidden: data.amountHidden) : nil
        let stale = staleNote.map { PriceTerms.separator + $0 } ?? ""
        let fetched = fetchedAt.map { PriceTerms.priceFetchedAt + " " + $0 + stale }
        if estNet != nil || fetched != nil {
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s3, verticalSpacing: CouliSpacing.s1) {
                if let estNet {
                    let parts = ProductDetailLabeledAmount.split(estNet)
                    ProductDetailLabeledAmount(label: parts.label, amount: parts.amount, style: .caption,
                                               probeID: "product.amount.estNet")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: data.estNetAccessibility ?? estNet))
                }
                if let fetched {
                    // 取价时间 + 缓存降级提示是可变长文案（共性 24，03 §10.4）：放不下一行时按可用宽度换行。
                    Text(verbatim: fetched)
                        .couliFont(.caption, monospacedDigits: true)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("product.fetchedAt")
                }
            }
            .foregroundColor(CouliColor.textSecondary)
            .couliProbe("product.fetchedAt", role: "text")
        }
    }

    // MARK: 说明、标签、标题

    @ViewBuilder private var notesAndTags: some View {
        let notes = (data.price.presaleLabel != nil ? [PriceTerms.presalePriceNote] : []) + data.notes
        ForEach(notes, id: \.self) { note in
            Text(verbatim: note)
                .couliFont(.caption)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !data.allTags.isEmpty {
            TagRow(tags: data.allTags)
                .couliProbe("product.benefitTags", role: "tags")
        }
    }

    private func badgedTitle(color: Color) -> some View {
        BadgedTitle(
            platform: data.platformName,
            platformCode: data.platformCode,
            title: data.title,
            style: .body,
            weight: .couliSemibold,
            lineLimit: nil,
            isHeader: true,
            color: color
        )
        .couliProbe("product.title", role: "title")
    }

    private func titleBlock(color: Color) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            badgedTitle(color: color)
                .accessibilityIdentifier("product.title")
            shop
        }
    }

    @ViewBuilder private var shop: some View {
        if let shopName {
            Text(verbatim: shopName)
                .couliFont(.caption)
                .foregroundColor(CouliColor.textSecondary)
        }
    }

    /// 下架：卡顶灰胶囊 → 来源 + 标题（次要色）→ 店铺；胶囊与标题读屏合为一项「商品已下架，淘宝，标题」。
    private func offShelf(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                ProductStatusCapsule(label)
                    .couliProbe("product.offShelf", role: "capsule")
                badgedTitle(color: CouliColor.textSecondary)
            }
            // 读屏一项「商品已下架，{平台}，{标题}」。用 accessibilityRepresentation：children: .ignore 在 XCUI 树里仍把胶囊文字
            // 挂成子节点，「商品已下架」会被数两次（APP-06v-b G-D07 只许卡上一处，同头图 K8 做法）。
            .accessibilityRepresentation {
                Text(verbatim: label + PriceTerms.spokenPause
                    + BadgedTitle.accessibilityText(platform: data.platformName, title: data.title))
                    .accessibilityAddTraits(.isHeader)
            }
            .accessibilityIdentifier("product.title")
            shop
                .padding(.top, -CouliSpacing.s2)
        }
    }
}
