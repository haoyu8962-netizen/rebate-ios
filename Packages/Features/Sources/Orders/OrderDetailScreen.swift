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
    /// 【联系客服】（CONTACT_CS）走统一客服出口（APP-12）：返回 true = 已交给客服出口；false（没接）时照旧经 `onOpen` 打开 Help。
    public var onContactService: () -> Bool = { false }
    /// /v1/config.help_links（「查看说明」的目标；未配置为 nil）。
    public var helpLinks: () -> [String: Any]? = { nil }
    /// 【问问 AI】（G-I02，与 Android 同）：打开 AgentChat 并带本单 context.order_id、不自动发送。nil = 不显示入口。
    public var onAskAI: (() -> Void)?
    public var now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    public init(controller: OrderDetailController, texts: OrderTexts, mask: AmountMaskStore) {
        self.controller = controller
        self.texts = texts
        self.mask = mask
    }
}

/// 订单详情（OrderDetail 路由；设计稿 OrderDetail*-v2、OrderDetailUnknown、OrderDetailReasonStates、AdaptLargeTextOrderDetail；
/// APP-08v-b）：状态卡（图标 + 标题 + 眼睛、左返利右实付、提示；分隔线下原因区 / 差额行 / 申诉中块 / 卡内按钮 / 未知状态的
/// 【刷新】与「查看流水」）→ 商品卡（来源 +「查看商品 ›」、图 + 标题 + 件数 + 单号【复制】）→ 时间线 →【问问 AI】整行卡；
/// 底部固定栏只放状态固有的【去提现】（G-O06）。按钮集合、顺序、去向仍只来自 `OrderDetailActions`。30701 空态；断网缓存显示提示条 +
/// 【重试】并可下拉刷新（共性第 26 条）；会话换代后清空（共性第 1 条）。
public struct OrderDetailScreen: View {
    @ObservedObject var config: OrderDetailPageConfig
    @ObservedObject var controller: OrderDetailController
    @ObservedObject var mask: AmountMaskStore
    @State var toast: CouliToastMessage?
    /// 底部固定栏所在处的底部安全区高（下内边距取 max(安全区, 16)）。
    @State var bottomInset: CGFloat = 0

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
                OrderDetailSkeleton()
                    .padding(CouliSpacing.s4)
                    .frame(maxWidth: OrderLayout.maxContentWidth)
                    .frame(maxWidth: .infinity)
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
        let split = OrderDetailActionSplit(detail: detail, actions: actions)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                    if snapshot.phase == .stale, let at = snapshot.staleAt {
                        staleBanner(at, blocked: snapshot.blocked || snapshot.refreshing)
                    }
                    statusCard(detail, actions: actions, split: split, snapshot: snapshot)
                    productCard(detail)
                    timelineCard(detail)
                    if let onAskAI = config.onAskAI {
                        askAIRow(onAskAI)
                    }
                }
                .padding(CouliSpacing.s4)
                .frame(maxWidth: OrderLayout.maxContentWidth)
                .couliProbe("orderDetail.content", role: "content")
                .frame(maxWidth: .infinity)
            }
            .refreshable { await controller.refreshAndWait() }
            if !split.bar.isEmpty {
                bottomBar(split.bar)
            }
        }
    }

    /// 详情按钮的出口（位置挪了，去向与次数不变）：【联系客服】先交统一客服出口，没接时照旧经 Router 打开；其余经 Router 打开（无参数）。
    func perform(_ button: OrderActionButton) {
        if button.actionRaw == "contact_cs", config.onContactService() {
            return
        }
        config.onOpen(RouteTarget(route: button.route, params: [:]))
    }
}

/// 详情按钮的视图分区（G-O06；纯视图，按钮集合 / 顺序 / 主次数据仍是 `OrderDetailActions.view` 的结果）：状态固有的【去提现】
/// （actionRaw = withdraw）进底部固定栏，其余（reason.action、扣回【查看流水】）进状态卡内。未知状态（G-O08）卡内不画按钮，
/// 只有【刷新】与「查看流水」文字链（由 `unknownLedger` 给出规则层的 ledger 按钮）。
struct OrderDetailActionSplit {
    let card: [OrderActionButton]
    let bar: [OrderActionButton]
    let unknownLedger: OrderActionButton?

    init(detail: OrderDetail, actions: OrderActionsView) {
        if detail.summary.displayStatus == .unknown {
            card = []
            bar = []
            unknownLedger = actions.buttons.first { $0.actionRaw == "ledger" }
        } else {
            card = actions.buttons.filter { $0.actionRaw != "withdraw" }
            bar = actions.buttons.filter { $0.actionRaw == "withdraw" }
            unknownLedger = nil
        }
    }
}
