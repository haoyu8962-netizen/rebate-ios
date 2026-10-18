import DesignSystem
import Generated
import HomeCore
import SwiftUI

public struct HomeSduiScreen: View {
    @ObservedObject private var controller: HomeController
    @Environment(\.dynamicTypeSize) private var size
    private let grayscale: Bool
    public init(controller: HomeController, grayscale: Bool = false) {
        self.controller = controller; self.grayscale = grayscale
    }

    public var body: some View {
        let model = controller.state
        let render = model.render
        let owner = controller
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CouliSpacing.s3) {
                if let failed = model.loadFailed {
                    VStack(spacing: CouliSpacing.s4) {
                        Text(verbatim: owner.text("home.load_failed")).couliFont(.title)
                        Text(verbatim: failed.message).fixedSize(horizontal: false, vertical: true)
                        Button(owner.text("home.retry")) { owner.retryLoadFailed(render) }
                            .disabled(!failed.retryEnabled).frame(minHeight: 44)
                    }.frame(maxWidth: .infinity).padding(CouliSpacing.s6)
                }
                ForEach(model.rowKeys, id: \.self) { key in
                    row(key, model: model, owner: owner)
                }
            }
            .padding(CouliSpacing.s4)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(CouliColor.backgroundCanvas)
        // 系统控件（重试按钮、加载圈）的强调色取令牌，不落到系统蓝
        .tint(CouliColor.textLink)
        .grayscale(grayscale ? 1 : 0)
        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in owner.interacted(render) })
        .refreshable {
            owner.refresh(render)
            await owner.whenIdle()
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(verbatim: toast.message).couliFont(.footnote).padding()
                    .background(CouliColor.backgroundSurface).cornerRadius(CouliRadius.card)
                    .onTapGesture { owner.consumeToast(toast.id) }
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(3))
                        owner.consumeToast(toast.id)
                    }
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

    @ViewBuilder private func row(_ key: String, model: HomeUiState, owner: HomeController) -> some View {
        if key == HomeRowKey.make("footer", []) {
            let lines = Self.disclaimerLines(model, text: owner.text)
            if !lines.isEmpty {
                // 页底口径说明（Main 稿）：上方一条装饰分隔线，说明句 caption 次要色
                VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                    Rectangle().fill(CouliColor.borderSubtle).frame(height: 1).accessibilityHidden(true)
                    DisclaimerFooter(lines: lines.map { DisclaimerFooter.Line($0) }).padding(
                        .horizontal,
                        CouliSpacing.s1
                    )
                }
            }
        } else if let section = model.sections.first(where: { $0.key == key }) {
            HomeSectionView(section: section, controller: owner)
                // 新渲染同时作废旧轮播 / 公告的 View 任务和局部状态（切 Tab 不换渲染票据）。身份 = 渲染票据 + 区段键：同一次
                // 渲染里每张卡各不相同（APP-11 P1：全部区段共用渲染票据时 LazyVStack 只画出第一张卡）。
                .id(HomeSectionViewId(render: model.render, key: key))
        } else {
            ForEach(model.sections.filter { $0.type == "feed_infinite" }) { section in
                if key == HomeRowKey.make("feed_status", [section.id]), let feed = section.feed {
                    feedStatus(feed, owner: owner)
                } else if let index = section.items.firstIndex(where: {
                    HomeRowKey.make("product", [section.id, $0.id]) == key
                }) {
                    feedRow(section, index: index, owner: owner)
                }
            }
        }
    }

    @ViewBuilder private func feedRow(_ section: HomeSectionUi, index: Int, owner: HomeController) -> some View {
        let columns = size.isAccessibilitySize ? 1 : 2
        if index % columns == 0 {
            HStack(alignment: .top, spacing: CouliSpacing.s3) {
                ForEach(0..<columns, id: \.self) { offset in
                    if index + offset < section.items.count {
                        HomeProductTile(item: section.items[index + offset], controller: owner)
                            .frame(maxWidth: .infinity)
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
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

    @ViewBuilder private func feedStatus(_ feed: HomeFeedUi, owner: HomeController) -> some View {
        let ticket = feed.ticket
        if let failure = feed.failure {
            VStack {
                Text(verbatim: failure.message).fixedSize(horizontal: false, vertical: true)
                Button(owner.text("home.retry")) { owner.retryFeed(ticket) }
                    .disabled(!failure.retryEnabled).frame(minHeight: 44)
            }.frame(maxWidth: .infinity)
        } else if !feed.exhausted {
            ProgressView().frame(maxWidth: .infinity).onAppear { owner.loadMore(ticket) }
        }
    }
}

/// 区段卡的视图身份：渲染票据 + 区段键。
private struct HomeSectionViewId: Hashable {
    let render: HomeRenderTicket
    let key: String
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
