import DesignSystem
import Generated
import OrderCore
import SwiftUI

/// 订单详情页的配置（App 给）：执行器、文案、跳转出口。
@MainActor
public final class OrderDetailPageConfig: ObservableObject {
    public let controller: OrderDetailController
    public let texts: OrderTexts
    public let mask: AmountMaskStore
    public var onBack: () -> Void = {}
    /// 经 Router 打开一个目标（详情按钮、「查看说明」、「查看商品」、【查看申诉进度】；路由名都在 routes.json）。
    public var onOpen: (_ target: RouteTarget) -> Void = { _ in }
    /// /v1/config.help_links（「查看说明」的目标；未配置为 nil）。
    public var helpLinks: () -> [String: Any]? = { nil }
    public var now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    public init(controller: OrderDetailController, texts: OrderTexts, mask: AmountMaskStore) {
        self.controller = controller
        self.texts = texts
        self.mask = mask
    }
}

/// 订单详情（OrderDetail 路由；设计稿 OrderDetail*、AdaptLargeTextOrderDetail）：状态与金额卡（标题 + 眼睛、金额格、预计结算月份 /
/// 入账句 / 状态说明）→ 原因区「为什么没返利？」（直接显示，不进 AI、不发请求；「查看说明」）→ 申诉中块 → 商品卡（平台 +「查看商品」、
/// 图 + 标题 + 件数、订单号 + 复制）→ 时间线 → 底部按钮（最多 2 个）。30701 空态；断网缓存显示提示条 +【重试】并可下拉刷新（共性第 26 条）；
/// 会话换代后清空（共性第 1 条）。「问问 AI」本任务不显示（G18，TODO(APP-10)）。
public struct OrderDetailScreen: View {
    @ObservedObject var config: OrderDetailPageConfig
    @ObservedObject var controller: OrderDetailController
    @ObservedObject var mask: AmountMaskStore
    @State var toast: CouliToastMessage?

    public init(config: OrderDetailPageConfig) {
        self.config = config
        controller = config.controller
        mask = config.mask
    }

    var texts: OrderTexts {
        config.texts
    }

    public var body: some View {
        VStack(spacing: 0) {
            NavBar(
                title: texts.text(OrderKeys.detailTitle),
                backLabel: texts.text(OrderKeys.back),
                onBack: config.onBack
            )
            .background(CouliColor.backgroundCanvas)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .task { controller.start() }
        .couliToast($toast)
        .onChange(of: controller.snapshot.copyToast) { value in
            guard let value else { return }
            toast = value.couli(texts)
            controller.consumeCopyToast()
        }
        .onChange(of: controller.snapshot.toast) { value in
            guard let value else { return }
            toast = value.couli(texts)
            controller.consumeToast()
        }
    }

    @ViewBuilder var content: some View {
        let snapshot = controller.snapshot
        switch snapshot.phase {
        case .loading:
            ScrollView {
                OrderCardSkeleton()
                    .padding(CouliSpacing.s4)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: texts.text(OrderKeys.loading)))
            .accessibilityIdentifier("orderDetail.loading")
        case .empty:
            EmptyState(icon: .orders, title: texts.text("error.30701"))
                .accessibilityIdentifier("orderDetail.empty")
        case .error:
            ErrorState(
                title: texts.text(OrderKeys.loadFailed), message: OrderErrorText.text(snapshot.error, texts: texts),
                retryTitle: texts.text(OrderKeys.retry)
            ) {
                controller.retry()
            }
            .disabled(snapshot.blocked)
            .accessibilityIdentifier("orderDetail.error")
        case .cleared:
            Color.clear
                .accessibilityIdentifier("orderDetail.cleared")
        case .content, .stale:
            if let detail = snapshot.detail {
                loaded(detail, snapshot: snapshot)
            }
        }
    }

    func loaded(_ detail: OrderDetail, snapshot: OrderDetailSnapshot) -> some View {
        let actions = OrderDetailActions.view(detail)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                    if snapshot.phase == .stale, let at = snapshot.staleAt {
                        staleBanner(at, blocked: snapshot.blocked || snapshot.refreshing)
                    }
                    statusCard(detail)
                    reasonCard(detail)
                    if actions.appealPendingBlock {
                        appealBlock
                    }
                    productCard(detail)
                    timelineCard(detail)
                }
                .padding(CouliSpacing.s4)
                .frame(maxWidth: OrderLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await controller.refreshAndWait() }
            if !actions.buttons.isEmpty {
                bottomBar(actions.buttons)
            }
        }
    }
}
