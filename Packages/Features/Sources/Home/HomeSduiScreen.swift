import DesignSystem
import Generated
import HomeCore
import SwiftUI
import UIKit

/// 首页列表（APP-11v，Main-v3 / HomeGuest-v3）：原生头部（App 传入：提示条、游客价值卡、粘贴卡）与 SDUI 卡、口径页脚在同一条纵向滚动
/// 列表里，下拉刷新覆盖整列表（刷新只走 `HomeController.refresh`，原生头部不重建）。内容列限宽 600 居中（03 §10.4），页面左右 16、区块间距 12。
public struct HomeSduiScreen: View {
    @ObservedObject private var controller: HomeController
    @Environment(\.dynamicTypeSize) private var size
    private let grayscale: Bool
    private let header: AnyView?
    @State private var rows = HomeRowFrames()
    /// 列表实际宽度（内容列宽、网格列数与横滑卡宽按它算）。
    @State private var width: CGFloat = 0
    /// 列表视口高度（信息流加载行是否进入视口按它判断；视口变高也要重判）。
    @State private var viewport: CGFloat = 0
    /// 信息流单件量宽缓存（同一渲染内按商品 id、字号；换渲染即清空）。
    @State private var widths = HomeFeedWidths()
    /// 信息流窗口化（离视口远的商品行换同高占位）与它的重算计数。
    @State private var window = HomeFeedWindow()
    @State private var windowTick = 0
    /// 滚动容器的底部安全区（系统标签栏等压在列表底部的高度），列表按它补底部留白（HomeScrollBottomMargin，D10-831）。
    @State private var bottomInset: CGFloat = 0

    public init(controller: HomeController, grayscale: Bool = false) {
        self.controller = controller
        self.grayscale = grayscale
        header = nil
    }

    /// `header`：原生头部，作为同一纵向列表的首项（位于 SDUI 之前，不进 sections / 协议命名空间）。
    public init(controller: HomeController, grayscale: Bool = false,
                @ViewBuilder header: () -> some View) {
        self.controller = controller
        self.grayscale = grayscale
        self.header = AnyView(header())
    }

    /// 头部已包成 AnyView 时用（App 经环境值传入；nil = 没有头部）。
    public init(controller: HomeController, grayscale: Bool = false, header: AnyView?) {
        self.controller = controller
        self.grayscale = grayscale
        self.header = header
    }

    /// 内容列最大宽度（03 §10.4，与搜索行、搜索页同一取值）。
    static let maxColumn: CGFloat = 600

    public var body: some View {
        let model = controller.state
        let render = model.render
        let owner = controller
        let column = min(Self.maxColumn, max(0, width - CouliSpacing.s4 * 2))
        // 信息流的商品行索引与列数：每次 body 只建一次（不在每行里扫整组、不每行对整组量宽）；单件量宽按渲染票据缓存
        let feeds = HomeFeedLayout(model.sections, render: render, size: size, column: column, owner: owner,
                                   widths: widths)
        let context = HomeRowContext(
            model: model, owner: owner, column: column, feeds: feeds,
            placeholders: window.attach(viewport: viewport, bump: $windowTick)
                .prepared(feeds.pairKeys, tick: windowTick,
                          signature: HomeFeedWindow.Signature(width: column, size: size, render: render))
        )
        ScrollView {
            // 普通纵向栈：行高全部实测、内容高度精确（末端回拉不跳，APP-11v P2）。信息流可翻很多页：离视口远的商品行换成同高
            // 占位（HomeFeedWindow），同时实际布局的商品卡只有视口附近几行
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                if let header {
                    header
                        .frame(maxWidth: .infinity)
                        .couliProbe("home.column.native", role: "column")
                        .background(rows.tracker(HomeRowId.header))
                }
                if let failed = model.loadFailed {
                    loadFailed(failed, owner: owner, render: render)
                }
                ForEach(model.rowKeys, id: \.self) { key in
                    row(key, in: context)
                }
                footer(model, owner: owner)
            }
            .coordinateSpace(name: HomeFeedWindow.space)
            .background(window.scrollReader())
            .couliProbe("home.column.sdui", role: "column")
            .frame(maxWidth: Self.maxColumn)
            .padding(.horizontal, CouliSpacing.s4)
            .padding(.top, CouliSpacing.s1)
            .padding(.bottom, CouliSpacing.s4 + HomeScrollBottomMargin.legacy(bottomInset))
            .frame(maxWidth: .infinity)
            .background(HomeScrollInsets(rows: rows, bottom: $bottomInset))
        }
        // 列表外层的修饰收在一个修饰器里（视图类型层级浅，既有身份探针按层级找行 ForEach）
        .modifier(HomeListChrome(model: model, owner: owner, grayscale: grayscale, rows: rows, bottom: bottomInset,
                                 width: $width, viewport: $viewport))
    }

    /// 整页最后防线（包内默认也坏）：通用错误版式。
    private func loadFailed(_ failed: HomeFailureUi, owner: HomeController, render: HomeRenderTicket) -> some View {
        VStack(spacing: CouliSpacing.s4) {
            Text(verbatim: owner.text("home.load_failed")).couliFont(.title, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: failed.message).couliFont(.footnote).foregroundColor(CouliColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            CouliButton(owner.text("home.retry"), kind: .secondary, size: .compact,
                        isEnabled: failed.retryEnabled) { owner.retryLoadFailed(render) }
        }
        .frame(maxWidth: .infinity)
        .padding(CouliSpacing.s6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.loadFailed")
    }

    @ViewBuilder private func row(_ key: String, in context: HomeRowContext) -> some View {
        let model = context.model
        let owner = context.owner
        let feeds = context.feeds
        if let product = feeds.products[key] {
            if context.placeholders.contains(key) {
                // 离视口远的信息流行：同高空占位（实测过的行高），只记位置
                Color.clear.frame(height: window.height(key)).background(window.reader(key, measured: false))
            } else {
                feedRow(product.section, index: product.index, columns: feeds.columns[product.section.id] ?? 1,
                        owner: owner)
            }
        } else if let section = model.sections.first(where: { $0.key == key }) {
            HomeSectionView(section: section, controller: owner, column: context.column, rows: rows)
                // 新渲染同时作废旧轮播 / 公告的 View 任务和局部状态（切 Tab 不换渲染票据）。身份 = 渲染票据 + 区段键：同一次
                // 渲染里每张卡各不相同（APP-11 P1：全部区段共用渲染票据时懒加载栈只画出第一张卡）。
                .id(HomeSectionViewId(render: model.render, key: key))
        } else if let feed = feeds.statuses[key] {
            feedStatus(feed, owner: owner)
        } else {
            // 页脚行（footer 键）由 `footer` 在全部行之后画（不随 ForEach 行身份）
            EmptyView()
        }
    }

    /// 页底口径说明（Main-v3）：上方 1 分隔线，两行 12 次要色，无 i 图标、无卡底。
    @ViewBuilder private func footer(_ model: HomeUiState, owner: HomeController) -> some View {
        let lines = Self.disclaimerLines(model, text: owner.text)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                Rectangle().fill(CouliColor.borderSubtle).frame(height: 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    ForEach(lines, id: \.self) { line in
                        Text(verbatim: line).couliFont(.caption).foregroundColor(CouliColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, CouliSpacing.s1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.footer")
            .background(rows.tracker(HomeRowKey.make("footer", [])))
        }
    }

    /// 信息流：每件一张独立白卡，两件一组成行（列数规则见 `HomeVisualRules.gridColumns`，整组同列数、整组只量一次；改单列时同一组
    /// 上下排，窗口化的粒度不随列数变化）。
    @ViewBuilder private func feedRow(_ section: HomeSectionUi, index: Int, columns: Int,
                                      owner: HomeController) -> some View {
        if index % 2 == 0 {
            let key = HomeRowKey.make("product", [section.id, section.items[index].id])
            let pair = Array(section.items[index..<min(index + 2, section.items.count)].enumerated())
            Group {
                if columns == 2 {
                    HStack(alignment: .top, spacing: CouliSpacing.s3) {
                        ForEach(pair, id: \.element.id) { offset, item in
                            HomeProductTile(item: item, controller: owner, style: .feed, index: index + offset)
                                .frame(maxWidth: .infinity)
                        }
                        if pair.count == 1 {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: CouliSpacing.s3) {
                        ForEach(pair, id: \.element.id) { offset, item in
                            HomeProductTile(item: item, controller: owner, style: .feed, index: index + offset)
                        }
                    }
                }
            }
            .background(rows.tracker(key))
            .background(window.reader(key, measured: true))
        }
    }

    /// 加载行进入视口（含 1/4 屏预取）才翻页。加载行出现、位置变、视口高度变、本页加载结束（游标票据 / 加载状态变化）都重判一次：
    /// 下一页为空但带新游标、或新到的一件只补齐当前双列行时，加载行原地不动，也会接着请求下一页。同一游标不重复请求（控制器只接受
    /// 当前票据，且在途时拒绝）。
    private func loadMoreIfVisible(_ probe: HomeFeedProbe, owner: HomeController) {
        if !probe.loading, probe.viewport > 0, probe.top < probe.viewport * 1.25 {
            owner.loadMore(probe.ticket)
        }
    }

    /// 页底口径说明（APP-11 P2）：与搜索页同一条合并规则（DesignSystem `ProductDisclaimers.footerKeys`：混排只留
    /// price_basis.general、有普通返利金额时追加 rebate_estimate、价格句在前），文案经注入的文案函数取；取不到文案的句子不显示，
    /// 键名不上屏；同一句只出一次。
    static func disclaimerLines(_ state: HomeUiState, text: (String) -> String) -> [String] {
        let products = state.sections.flatMap(\.items).compactMap { $0.product?.fields.mapValues(\.anyValue) }
        var seen: Set<String> = []
        return ProductDisclaimers.footerKeys(products).compactMap { key in
            let line = text(key)
            guard !line.isEmpty, line != key, seen.insert(line).inserted else { return nil }
            return line
        }
    }

    /// 信息流底部：加载中（不另加骨架）/ 失败行【重试】（不变）。
    @ViewBuilder private func feedStatus(_ feed: HomeFeedUi, owner: HomeController) -> some View {
        let ticket = feed.ticket
        if let failure = feed.failure {
            VStack(spacing: CouliSpacing.s2) {
                Text(verbatim: failure.message).couliFont(.footnote).foregroundColor(CouliColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                CouliButton(owner.text("home.retry"), kind: .secondary, size: .compact,
                            isEnabled: failure.retryEnabled) { owner.retryFeed(ticket) }
                    .accessibilityIdentifier("home.feed.retry")
                    .couliProbe("home.feed.retry", role: "independent-hit")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, CouliSpacing.s2)
        } else if !feed.exhausted {
            ProgressView().frame(maxWidth: .infinity)
                .background(
                    GeometryReader { proxy in
                        let probe = HomeFeedProbe(ticket: ticket, loading: feed.loading,
                                                  top: proxy.frame(in: .named(HomeRowFrames.space)).minY,
                                                  viewport: viewport)
                        Color.clear
                            .onAppear { loadMoreIfVisible(probe, owner: owner) }
                            .onChange(of: probe) { loadMoreIfVisible($0, owner: owner) }
                    }
                )
        }
    }
}

/// 一次 body 里各行共用的输入。
private struct HomeRowContext {
    let model: HomeUiState
    let owner: HomeController
    let column: CGFloat
    let feeds: HomeFeedLayout
    /// 此刻用同高占位代替的信息流行。
    let placeholders: Set<String>
}

/// 区段卡的视图身份：渲染票据 + 区段键。
private struct HomeSectionViewId: Hashable {
    let render: HomeRenderTicket
    let key: String
}

private enum HomeRowId: Hashable {
    case header
}

/// 不经控制器的固定文案（首页弹窗的读屏名）。区段卡与页底说明一律经 `HomeController.text`（注入的文案函数）。
enum HomeText {
    static func text(_ key: String) -> String {
        DefaultTexts.text(key) ?? HomeTextDrafts.values[key] ?? key
    }
}

public struct HomeRootTone<Content: View>: View {
    let grayscale: Bool
    let content: Content
    public init(grayscale: Bool, @ViewBuilder content: () -> Content) {
        self.grayscale = grayscale; self.content = content()
    }

    public var body: some View {
        content.grayscale(grayscale ? 1 : 0)
    }
}

/// 首页列表外层：坐标空间、读屏容器与标识、宽高读取（宽度变化保留滚动锚点）、底色、强调色、置灰、下拉刷新、提示、首页弹窗。
private struct HomeListChrome: ViewModifier {
    let model: HomeUiState
    let owner: HomeController
    let grayscale: Bool
    let rows: HomeRowFrames
    /// 底部留白（滚动容器的底部安全区，HomeScrollBottomMargin）。
    let bottom: CGFloat
    @Binding var width: CGFloat
    @Binding var viewport: CGFloat
    @State private var toast: CouliToastMessage?
    /// 正在显示的提示对应的控制器 toast id。
    @State private var toastSource: UUID?

    private func show(_ source: HomeToast?) {
        guard let source, source.id != toastSource else { return }
        toastSource = source.id
        toast = CouliToastMessage(source.message, icon: .info)
    }

    func body(content: Content) -> some View {
        let render = model.render
        content.modifier(HomeScrollBottomMargin(bottom: bottom))
            .coordinateSpace(name: HomeRowFrames.space)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.list")
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            width = proxy.size.width
                            viewport = proxy.size.height
                        }
                        .onChange(of: proxy.size.width) { value in
                            rows.keepAnchor()
                            width = value
                        }
                        .onChange(of: proxy.size.height) { viewport = $0 }
                }
            )
            .background(CouliColor.backgroundCanvas)
            // 系统控件（重试按钮、加载圈）的强调色取令牌，不落到系统蓝
            .tint(CouliColor.textLink)
            .grayscale(grayscale ? 1 : 0)
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in owner.interacted(render) })
            .refreshable {
                owner.refresh(render)
                await owner.whenIdle()
            }
            // 刷新失败等轻提示用 DS 的 couliToast（D10-643）：控制器的 toast 模型不变，这里只换呈现层；
            // DS 计时消失后再交还控制器（consumeToast），同一条提示重绘不重复计时、不重复播报。
            .couliToast($toast)
            .onAppear { show(model.toast) }
            .onChange(of: model.toast?.id) { _ in show(model.toast) }
            .onChange(of: toast) { value in
                if value == nil, let source = toastSource {
                    toastSource = nil
                    owner.consumeToast(source)
                }
            }
            .fullScreenCover(item: Binding(get: { model.popup }, set: { value in
                if value == nil, let popup = model.popup {
                    owner.closePopup(popup.ticket)
                }
            })) { popup in
                HomePopupView(
                    popup: popup,
                    onClose: { owner.closePopup(popup.ticket) },
                    onTap: { owner.tapPopup(popup.ticket) }
                )
                .onAppear { owner.popupShown(popup.ticket) }
            }
    }
}
