import DesignSystem
import Generated
import OrderCore
import SwiftUI

extension OrdersScreen {
    // MARK: - 内容

    @ViewBuilder var content: some View {
        switch snapshot.phase {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { index in
                OrderListSkeletonCard(probe: index == 0 ? "orders.skeleton.0" : nil)
                    .padding(.bottom, CouliSpacing.s3)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: texts.text(OrderKeys.loading)))
            .accessibilityIdentifier("orders.loading")
        case .error:
            ErrorState(
                title: texts.text(OrderKeys.loadFailed), message: OrderErrorText.text(snapshot.error, texts: texts),
                retryTitle: texts.text(OrderKeys.retry)
            ) {
                controller.retry()
            }
            .disabled(snapshot.blocked)
            .accessibilityIdentifier("orders.error")
        case .empty:
            if snapshot.query.filtered {
                // 搜索 / 筛选无结果按画板 OrdersSearchEmpty 紧接头部排（画板本身不居中）
                filteredEmpty
            } else {
                // 没有订单的空态在头部（及待跟单卡区）以下的列表区上下居中（画板 OrdersEmpty / OrdersShareEmpty，评审 r1 S2-4 / r2 S2-1）；
                // 剩余高度放不下时按档自适应：先去插图、再压上下留白，标题、说明与【去首页逛逛】始终保留（测试 v5 跟进）
                VStack(spacing: 0) { homeEmpty(emptyDensity, live: true) }
                    .frame(maxWidth: .infinity, minHeight: emptyAreaHeight)
                    .background(alignment: .top) { emptyMeasurer }
            }
        case .content, .stale:
            // 断网提示条在头部（标题下、子 Tab 上，见 controls）
            ForEach(snapshot.items) { item in
                // 渲染这一刻固定【复制】票据（页面、会话、查询轮次、单号）；回调执行时只核对、不重新绑定（共性第 41 条）
                let ticket = config.copyTicket(item)
                OrderCard(item: item, texts: texts, hidden: mask.hidden, now: config.now(), onOpen: {
                    config.onOpenDetail(item.orderId)
                }, onCopy: { config.copyOrderNo(ticket, rendered: $0) })
                    .background(GeometryReader { geometry in
                        Color.clear.preference(
                            key: OrderCardFramesKey.self,
                            value: [item.orderId: geometry.frame(in: .named(OrderListSpace.name))]
                        )
                    })
                    .padding(.bottom, CouliSpacing.s3)
                    .id(item.orderId)
                    .onAppear {
                        if item.orderId == snapshot.items.last?.orderId {
                            controller.loadMore()
                        }
                    }
            }
            footer
        }
    }

    /// 头部以下的列表区高（视口高 − 头部 − 头部下 12 − 待跟单卡区（含其下 12）− 列表底内边距 24）。
    var emptyAreaHeight: CGFloat {
        let pending = snapshot.query.scope == OrderQuery.selfScope && config.pendingTrack != nil ? pendingHeight : 0
        return max(0, viewportHeight - headerHeight - CouliSpacing.s3 - pending - CouliSpacing.s6)
    }

    @ViewBuilder var filteredEmpty: some View {
        let share = snapshot.query.scope == OrderQuery.shareScope
        EmptyState(
            icon: .search, title: texts.text(OrderKeys.searchNone),
            message: share && snapshot.query.keyword != nil ? texts.text(OrderKeys.shareNote) : nil
        )
        .couliProbe("orders.empty", role: "empty")
        .accessibilityIdentifier("orders.searchEmpty")
        historyHint.padding(.top, CouliSpacing.s3)
    }

    /// 没有订单的空态（含其下查询范围提示）。`live` = false 是只用来量高度的隐藏副本：不量测、不进读屏、按钮不做事。
    @ViewBuilder func homeEmpty(_ density: EmptyStateDensity, live: Bool) -> some View {
        let share = snapshot.query.scope == OrderQuery.shareScope
        VStack(spacing: 0) {
            let state = EmptyState(
                icon: .orders,
                title: texts.text(share ? OrderKeys.emptyShareTitle : OrderKeys.emptySelfTitle),
                message: texts.text(share ? OrderKeys.emptyShareMessage : OrderKeys.emptySelfMessage),
                actionTitle: texts.text(OrderKeys.emptyAction), actionKind: .primary, density: density,
                action: live ? config.onHome : {}
            )
            if live {
                state
                    .couliProbe("orders.empty", role: "empty")
                    .accessibilityIdentifier(share ? "orders.empty.share" : "orders.empty.self")
                historyHint.padding(.top, CouliSpacing.s3)
            } else {
                state
                if snapshot.earliestVisibleDate != nil {
                    historyHintText.padding(.top, CouliSpacing.s3)
                }
            }
        }
    }

    /// 各档空态的自然高度（只依赖宽与字号，与选哪一档无关，不会互相触发）：隐藏副本量一次，尺寸变化时更新。
    var emptyMeasurer: some View {
        ZStack(alignment: .top) {
            ForEach(EmptyStateDensity.allCases, id: \.rawValue) { density in
                homeEmpty(density, live: false)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geometry in
                        Color.clear
                            .onAppear { emptyHeights[density.rawValue] = geometry.size.height }
                            .onChange(of: geometry.size.height) { emptyHeights[density.rawValue] = $0 }
                    })
            }
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 放得下剩余列表区的第一档（完整 → 去插图 → 压留白）；都放不下用最紧的一档（页面可滚到它）。
    var emptyDensity: EmptyStateDensity {
        let area = emptyAreaHeight
        return EmptyStateDensity.allCases.first { density in
            emptyHeights[density.rawValue].map { $0 <= area + 0.5 } ?? (density == .regular)
        } ?? .compact
    }

    /// 惰性列表里的页脚：只有负责自动翻页的「上拉加载更多」（出现即翻页，必须随惰性列表在末行附近才出现；G26 不变）。
    @ViewBuilder var footer: some View {
        if snapshot.phase == .content, snapshot.pageError == nil, !snapshot.loadingMore, snapshot.nextCursor != nil {
            Text(verbatim: texts.text(OrderKeys.loadMore))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .onAppear { controller.loadMore() }
                .accessibilityIdentifier("orders.loadMoreHint")
                .frame(maxWidth: .infinity)
                .padding(.vertical, CouliSpacing.s2)
        }
    }

    /// 列表尾的展示内容（惰性列表之外）：断网缓存态的网络错误 +【重试】、翻页失败 + trace6 +【重试】、翻页加载中、搜索条数，
    /// 以及查询范围提示。各分支的条件与顺序同原页脚；空态里的查询范围提示由空态自己排。
    @ViewBuilder var listTail: some View {
        if [.content, .stale].contains(snapshot.phase), tailStatus != nil || snapshot.earliestVisibleDate != nil {
            VStack(spacing: CouliSpacing.s2) {
                tailStatusView
                historyHint
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, CouliSpacing.s2)
        }
    }

    /// 列表尾状态行的种类（与原页脚分支同序）。
    enum TailStatus {
        case stale
        case pageError(OrderErrorView)
        case loadingMore
        case searchFound
    }

    var tailStatus: TailStatus? {
        if snapshot.phase == .stale {
            return .stale
        }
        if let error = snapshot.pageError {
            return .pageError(error)
        }
        if snapshot.loadingMore {
            return .loadingMore
        }
        if snapshot.nextCursor == nil, snapshot.query.keyword != nil {
            return .searchFound
        }
        return nil
    }

    @ViewBuilder var tailStatusView: some View {
        switch tailStatus {
        case .stale:
            // 缓存态不能翻页：显示同一错误与【重试】（整页刷新，G10）
            pageErrorRow(OrderErrorText.text(
                OrderErrorView(actionRaw: OrderErrorKind.networkError, textKey: OrderErrorAction.networkKey),
                texts: texts
            ))
        case let .pageError(error):
            pageErrorRow(OrderErrorText.text(error, texts: texts))
        case .loadingMore:
            HStack(spacing: CouliSpacing.s2) {
                ProgressView()
                Text(verbatim: texts.text(OrderKeys.loading))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("orders.loadingMore")
        case .searchFound:
            // 搜索结果条数：接口没有总数，只在没有下一页时按已加载条数显示（H14 同口径）
            Text(verbatim: texts.format(OrderKeys.searchFound, ["n": String(snapshot.items.count)]))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .accessibilityAddTraits(.updatesFrequently)
                .couliProbe("orders.searchFound", role: "text")
                .accessibilityIdentifier("orders.searchFound")
        case nil:
            EmptyView()
        }
    }

    /// 查询范围提示的纯文字（量高度的隐藏副本用：不量测、不带标识）。
    @ViewBuilder var historyHintText: some View {
        if let date = snapshot.earliestVisibleDate {
            Text(verbatim: texts.format(
                OrderKeys.historyHint, ["date": CouliFormat.dateOnly(isoDate: date, nowEpochMillis: config.now())]
            ))
            .couliFont(.footnote)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder var historyHint: some View {
        // earliest_visible_date 非 null 时显示（AC-S1-73），{date} 按 BR-TEXT-11 纯日期
        if let date = snapshot.earliestVisibleDate {
            Text(verbatim: texts.format(
                OrderKeys.historyHint, ["date": CouliFormat.dateOnly(isoDate: date, nowEpochMillis: config.now())]
            ))
            .couliFont(.footnote)
            .foregroundColor(CouliColor.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .couliProbe("orders.historyHint", role: "text")
            .accessibilityIdentifier("orders.historyHint")
        }
    }

    func pageErrorRow(_ message: String) -> some View {
        VStack(spacing: CouliSpacing.s2) {
            Text(verbatim: message)
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .couliProbe("orders.pageError", role: "text")
                .accessibilityIdentifier("orders.pageError")
            CouliButton(texts.text(OrderKeys.retry), kind: .secondary, size: .compact, isEnabled: !snapshot.blocked) {
                controller.retryPage()
            }
            .accessibilityIdentifier("orders.pageRetry")
        }
    }

    // MARK: - 滚动锚点

    /// 视口顶部那张卡（第一张底边还在视口顶边以下的卡）；恢复进行中不记录（OrderAnchorKeeper 冻结），页面失效后不记录。
    func recordTop() {
        let top = snapshot.items.first { cardFrames.frames[$0.orderId].map { $0.maxY > 0 } ?? false }?.orderId
        if config.recordTop(top) {
            config.onStateChange()
        }
    }

    /// 进程恢复的一次性顶对齐（共性第 10、17、21、24、35 条）：判定与延迟回调的复核都在页面配置里。
    func restoreStep(_ proxy: ScrollViewProxy) {
        config.restoreStep { id in
            proxy.scrollTo(id, anchor: .top)
        }
    }
}

/// 列表内容顶边在视口坐标系里的纵坐标（= 负的滚动偏移；恢复期间判断列表是否被别的原因移动过）。
struct OrderListOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}
