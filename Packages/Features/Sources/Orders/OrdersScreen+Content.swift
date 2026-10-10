import DesignSystem
import Generated
import OrderCore
import SwiftUI

extension OrdersScreen {
    // MARK: - 内容

    @ViewBuilder var content: some View {
        switch snapshot.phase {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in
                OrderCardSkeleton()
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
            emptyState
        case .content, .stale:
            if snapshot.phase == .stale, let at = snapshot.staleAt {
                staleBanner(at)
            }
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

    @ViewBuilder var emptyState: some View {
        let share = snapshot.query.scope == OrderQuery.shareScope
        if snapshot.query.filtered {
            EmptyState(
                icon: .search, title: texts.text(OrderKeys.searchNone),
                message: share && snapshot.query.keyword != nil ? texts.text(OrderKeys.shareNote) : nil
            )
            .accessibilityIdentifier("orders.searchEmpty")
        } else {
            EmptyState(
                icon: .orders,
                title: texts.text(share ? OrderKeys.emptyShareTitle : OrderKeys.emptySelfTitle),
                message: texts.text(share ? OrderKeys.emptyShareMessage : OrderKeys.emptySelfMessage),
                actionTitle: texts.text(OrderKeys.emptyAction), action: config.onHome
            )
            .accessibilityIdentifier(share ? "orders.empty.share" : "orders.empty.self")
        }
        historyHint
    }

    func staleBanner(_ at: Int64) -> some View {
        HStack(alignment: .top, spacing: CouliSpacing.s2) {
            CouliIconView(.info, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                .foregroundColor(CouliColor.statusWarningText)
            Text(verbatim: texts.format(
                OrderKeys.staleData, ["time": CouliFormat.timeListPast(epochMillis: at, nowEpochMillis: config.now())]
            ))
            .couliFont(.footnote)
            .foregroundColor(CouliColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(CouliSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CouliRadius.small).fill(CouliColor.backgroundMuted))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("orders.stale")
    }

    var footer: some View {
        VStack(spacing: CouliSpacing.s2) {
            if snapshot.phase == .stale {
                // 缓存态不能翻页：显示同一错误与【重试】（整页刷新，G10）
                pageErrorRow(OrderErrorText.text(
                    OrderErrorView(actionRaw: OrderErrorKind.networkError, textKey: OrderErrorAction.networkKey),
                    texts: texts
                ))
            } else if let error = snapshot.pageError {
                pageErrorRow(OrderErrorText.text(error, texts: texts))
            } else if snapshot.loadingMore {
                HStack(spacing: CouliSpacing.s2) {
                    ProgressView()
                    Text(verbatim: texts.text(OrderKeys.loading))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("orders.loadingMore")
            } else if snapshot.nextCursor != nil {
                Text(verbatim: texts.text(OrderKeys.loadMore))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .onAppear { controller.loadMore() }
                    .accessibilityIdentifier("orders.loadMoreHint")
            } else if snapshot.query.keyword != nil {
                // 搜索结果条数：接口没有总数，只在没有下一页时按已加载条数显示（H14 同口径）
                Text(verbatim: texts.format(OrderKeys.searchFound, ["n": String(snapshot.items.count)]))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier("orders.searchFound")
            }
            historyHint
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CouliSpacing.s2)
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
        let top = snapshot.items.first { frames[$0.orderId].map { $0.maxY > 0 } ?? false }?.orderId
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
