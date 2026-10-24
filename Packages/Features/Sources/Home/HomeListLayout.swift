import DesignSystem
import HomeCore
import SwiftUI
import UIKit

/// 信息流加载行的可见性判断输入：游标票据、加载状态、加载行顶边、视口高度，任一变化都重判。
struct HomeFeedProbe: Equatable {
    let ticket: HomeFeedTicket
    let loading: Bool
    let top: CGFloat
    let viewport: CGFloat
}

/// 一次 body 内信息流的行索引（行键 → 商品位置 / 加载行）与每个信息流区段的列数（整组只算一次）。
@MainActor
struct HomeFeedLayout {
    struct Product {
        let section: HomeSectionUi
        let index: Int
    }

    private(set) var products: [String: Product] = [:]
    /// 信息流商品行（两件一组，以组内第一件的行键为行键），按列表顺序。
    private(set) var pairKeys: [String] = []
    private(set) var statuses: [String: HomeFeedUi] = [:]
    private(set) var columns: [String: Int] = [:]

    init(_ sections: [HomeSectionUi], render: HomeRenderTicket, size: DynamicTypeSize, column: CGFloat,
         owner: HomeController, widths: HomeFeedWidths) {
        for section in sections where section.type == "feed_infinite" {
            for (index, item) in section.items.enumerated() {
                let key = HomeRowKey.make("product", [section.id, item.id])
                products[key] = Product(section: section, index: index)
                if index % 2 == 0 {
                    pairKeys.append(key)
                }
            }
            if let feed = section.feed {
                statuses[HomeRowKey.make("feed_status", [section.id])] = feed
            }
            columns[section.id] = HomeVisualRules.gridColumns(
                availableWidth: column,
                requiredItemWidth: widths.required(section, render: render, size: size, owner: owner),
                spacing: CouliSpacing.s3
            )
        }
    }
}

/// 信息流整组量宽的增量缓存：同一渲染、同一字号下，翻页只量新到的商品，整组取最大值；换渲染或字号重新量。
@MainActor
final class HomeFeedWidths {
    private struct Group: Hashable {
        let section: String
        let size: DynamicTypeSize
    }

    private struct Measured {
        let ids: [String]
        let width: CGFloat
    }

    private var render: HomeRenderTicket?
    private var groups: [Group: Measured] = [:]
    /// 实际量过的商品件数（测量桥 / 长列表数据用；不影响布局）。
    private(set) var measuredItems = 0

    func required(_ section: HomeSectionUi, render: HomeRenderTicket, size: DynamicTypeSize,
                  owner: HomeController) -> CGFloat {
        if render != self.render {
            self.render = render
            groups = [:]
        }
        let group = Group(section: section.id, size: size)
        let ids = section.items.map(\.id)
        var start = 0
        var width: CGFloat = 0
        // 只在前面的商品原样不变（翻页追加）时沿用已量的结果，否则整组重量
        if let measured = groups[group], measured.ids.count <= ids.count,
           ids[0..<measured.ids.count].elementsEqual(measured.ids) {
            start = measured.ids.count
            width = measured.width
        }
        if start < ids.count {
            let fresh = Array(section.items[start...])
            measuredItems += fresh.count
            width = max(width, HomeProductTile.requiredWidth(fresh, style: .feed, size: size, owner: owner))
        }
        groups[group] = Measured(ids: ids, width: width)
        return width
    }
}

/// 列表各行在视口里的位置（只记录、不触发重画）。宽度变化（折叠屏展开 / 收起、分屏）后，把变化前视口里最后一个顶边已进入视口的行
/// （用户正看着的、最靠下的那一行内容）挪回原来离视口顶的距离（03 §10.4「滚动位置在折叠 / 展开后保留」）：直接调所在 UIScrollView 的
/// contentOffset，不包 ScrollViewReader；新布局分几帧到位，期间该行每次位置更新都再校正一次（最多 1 秒）。
@MainActor
final class HomeRowFrames {
    static let space = "home.list.viewport"
    private var frames: [AnyHashable: CGRect] = [:]
    private struct Pending {
        let key: AnyHashable
        let top: CGFloat
        let until: Date
    }

    private var pending: Pending?
    weak var scrollView: UIScrollView?

    func update(_ key: AnyHashable, _ frame: CGRect) {
        frames[key] = frame
        if let pending, pending.key == key {
            if Date() > pending.until {
                self.pending = nil
            } else {
                correct(to: pending.top, now: frame.minY)
            }
        }
    }

    func remove(_ key: AnyHashable) {
        frames.removeValue(forKey: key)
    }

    /// 某一行的位置记录器（放在行的背景里）。
    func tracker(_ key: AnyHashable) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(Self.space))
            Color.clear
                .onAppear { self.update(key, frame) }
                .onChange(of: frame) { self.update(key, $0) }
                .onDisappear { self.remove(key) }
        }
    }

    func keepAnchor() {
        let viewport = scrollView?.bounds.height ?? .infinity
        let started = frames.filter { $0.value.minY >= -0.5 && $0.value.minY < viewport }
        guard let anchor = started.max(by: { $0.value.minY < $1.value.minY }) else { return }
        pending = Pending(key: anchor.key, top: anchor.value.minY, until: Date().addingTimeInterval(1))
        DispatchQueue.main.async { [weak self] in
            guard let self, let now = frames[anchor.key]?.minY else { return }
            correct(to: anchor.value.minY, now: now)
        }
    }

    private func correct(to top: CGFloat, now: CGFloat) {
        guard let scroll = scrollView, abs(now - top) > 0.5 else { return }
        let maxOffset = max(0, scroll.contentSize.height - scroll.bounds.height)
        let target = min(max(0, scroll.contentOffset.y + now - top), maxOffset)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
    }
}

/// 信息流窗口化（APP-11v r1 S1-1）：首页列表是普通纵向栈（行高全部实测、内容高度精确，末端回拉不跳；区段卡、页脚、加载行始终实际
/// 布局），但信息流的商品行（两件一组）离视口超过窗口范围时换成同高的空占位：可翻很多页时，同时实际布局的商品卡只有视口附近的
/// 几行，图片与卡片视图随之释放。行高按「列表宽 + 字号 + 渲染」实测缓存；没量过的行一律实际布局（不估算高度）。
///
/// 行位置用列表内容自身的坐标空间记录（滚动时不变，不逐帧回调）；滚动偏移由内容栈背景里的一个记录器给出，每滚过 1/4 屏重算一次窗口，
/// 窗口里应实际布局的行集合变了才让列表重算 body。
@MainActor
final class HomeFeedWindow {
    static let space = "home.list.content"
    /// 窗口：视口上方 1.5 屏到下方 2.5 屏。
    private static let above: CGFloat = 1.5
    private static let below: CGFloat = 2.5

    struct Signature: Equatable {
        let width: CGFloat
        let size: DynamicTypeSize
        let render: HomeRenderTicket
    }

    private var signature: Signature?
    private var tops: [String: CGFloat] = [:]
    private var heights: [String: CGFloat] = [:]
    private var order: [String] = []
    private var offset: CGFloat = 0
    private var viewport: CGFloat = 0
    private var evaluatedAt: CGFloat = -.infinity
    /// 当前用占位代替的行。
    private(set) var placeholders: Set<String> = []
    /// 占位集合变化时通知列表重算（列表在 onAppear 里接上）。
    var changed: (() -> Void)?

    /// 每次 body 调用：接上视口高度与重算计数（`bump` 让列表的计数加一、重算 body）。
    func attach(viewport: CGFloat, bump: Binding<Int>) -> HomeFeedWindow {
        self.viewport = viewport
        changed = { bump.wrappedValue &+= 1 }
        return self
    }

    /// 每次 body 调用（`tick` 只为让 body 依赖重算计数）：返回此刻用占位代替的行。
    func prepared(_ keys: [String], tick _: Int, signature: Signature) -> Set<String> {
        prepare(keys, signature: signature)
        return placeholders
    }

    /// 传入当前信息流商品行（两件一组的行键，按顺序）与布局签名；签名变了（宽度、字号、渲染）旧高度作废、全部重新实测。
    func prepare(_ keys: [String], signature: Signature) {
        if signature != self.signature {
            self.signature = signature
            tops = [:]
            heights = [:]
            placeholders = []
            evaluatedAt = -.infinity
        }
        order = keys
        if keys.count <= Self.minimumRows {
            // 行数不多时不窗口化（与普通纵向栈完全一致，所有商品卡都在、可读屏遍历）
            if !placeholders.isEmpty {
                placeholders = []
            }
        }
    }

    /// 信息流商品行（两件一组）超过这么多行才窗口化：首页一页信息流通常 20 件 = 10 行，翻到第二页起生效。
    static let minimumRows = 10

    func isPlaceholder(_ key: String) -> Bool {
        placeholders.contains(key)
    }

    func height(_ key: String) -> CGFloat {
        heights[key] ?? 0
    }

    /// 行在内容坐标里的框（实际行报高度与顶边，占位只更新顶边）。
    func place(_ key: String, _ frame: CGRect, measured: Bool) {
        tops[key] = frame.minY
        if measured {
            heights[key] = frame.height
        }
        evaluate(force: true)
    }

    /// 列表内容顶边在视口坐标里的位置（内容栈背景里的记录器逐帧报）：取负即滚动偏移（内容坐标里视口顶边的位置）。
    func scrolled(contentTop: CGFloat) {
        offset = -contentTop
        evaluate(force: false)
    }

    /// 滚动偏移记录器（放在内容栈背景里；内容栈始终实际布局，滚到哪里都在报）。
    func scrollReader() -> some View {
        GeometryReader { proxy in
            let top = proxy.frame(in: .named(HomeRowFrames.space)).minY
            Color.clear
                .onAppear { self.scrolled(contentTop: top) }
                .onChange(of: top) { self.scrolled(contentTop: $0) }
        }
    }

    private func evaluate(force: Bool) {
        guard viewport > 0, order.count > Self.minimumRows else { return }
        guard force || abs(offset - evaluatedAt) >= viewport / 4 else { return }
        evaluatedAt = offset
        let low = offset - viewport * Self.above
        let high = offset + viewport * (1 + Self.below)
        var next: Set<String> = []
        for key in order {
            guard let top = tops[key], let height = heights[key] else { continue }
            if top + height < low || top > high {
                next.insert(key)
            }
        }
        if next != placeholders {
            placeholders = next
            changed?()
        }
    }

    /// 行的内容坐标记录器（放在行背景里）。
    func reader(_ key: String, measured: Bool) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(Self.space))
            Color.clear
                .onAppear { self.place(key, frame, measured: measured) }
                .onChange(of: frame) { self.place(key, $0, measured: measured) }
        }
    }
}

/// 首页列表夹在吸顶搜索行与底栏之间，不需要系统按安全区再给滚动内容加内边距（APP-11v）：关掉所在 UIScrollView 的自动内边距，
/// 滚动位置从 0 起算（原生头部与 SDUI 同一 contentOffset）。只找最近的那一个纵向滚动容器，不改别的设置。
struct HomeScrollInsets: UIViewRepresentable {
    let rows: HomeRowFrames

    func makeUIView(context _: Context) -> UIView {
        Probe(rows: rows)
    }

    func updateUIView(_ view: UIView, context _: Context) {
        (view as? Probe)?.apply()
    }

    /// SwiftUI 更新滚动容器时可能把内边距行为改回自动（列表内容变化后整列表按安全区下移，偏移变负）：每次更新与布局都重新确认。
    private final class Probe: UIView {
        private let rows: HomeRowFrames

        init(rows: HomeRowFrames) {
            self.rows = rows
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            nil
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            apply()
        }

        func apply() {
            var next = superview
            while let view = next {
                if let scroll = view as? UIScrollView {
                    rows.scrollView = scroll
                    guard scroll.contentInsetAdjustmentBehavior != .never else { return }
                    scroll.contentInsetAdjustmentBehavior = .never
                    // 自动内边距期间留下的负偏移收回到顶（不在拖动、减速或下拉刷新中时）
                    let top = -scroll.adjustedContentInset.top
                    if scroll.contentOffset.y < top, !scroll.isDragging, !scroll.isDecelerating,
                       scroll.refreshControl?.isRefreshing != true {
                        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: top), animated: false)
                    }
                    return
                }
                next = view.superview
            }
        }
    }
}
