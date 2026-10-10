import DesignSystem
import Generated
import OrderCore
import SwiftUI

/// 订单列表（OrderList 路由，订单 Tab 根；设计稿 Orders、OrdersShare、OrdersEmpty、OrdersShareEmpty、OrdersSearch*、OrdersFilter*、
/// OrdersStale、AdaptNarrowOrders、A11yHitOrders）：标题「订单」+ 右上常驻「未跟单？去找回」（G06）；子 Tab「自购 / 分享」；搜索框
/// （提交才搜，G11）；状态分组胶囊（横滑、选中项滚入可见区）；【平台】【月份】半屏单选 + 眼睛（G21）；自购子 Tab 顶部待跟单卡（G07）；
/// 列表卡整卡可点进详情，卡内【复制】是独立目标；末行出现时翻页；底部「上拉加载更多」/ 翻页错误 + trace6 +【重试】/ 搜索结果条数 /
/// earliest_visible_date 提示（AC-S1-73）。整页可下拉刷新；大屏内容限宽居中。
public struct OrdersScreen: View {
    @ObservedObject var config: OrderListPageConfig
    @ObservedObject var controller: OrderListController
    @ObservedObject var mask: AmountMaskStore
    @State var toast: CouliToastMessage?
    @State var frames: [String: CGRect] = [:]
    @AccessibilityFocusState var platformFocused: Bool
    @AccessibilityFocusState var monthFocused: Bool
    @FocusState var searchFocused: Bool
    /// 本视图实例的挂载记号：初始值只在实例第一次安装时求值（早于第一次排版），据此告诉配置「新视图挂上了」（共性第 37 条）。
    @StateObject private var mount: OrderListMount

    public init(config: OrderListPageConfig) {
        self.config = config
        controller = config.controller
        mask = config.mask
        _mount = StateObject(wrappedValue: OrderListMount(config))
    }

    var texts: OrderTexts {
        config.texts
    }

    var snapshot: OrderListSnapshot {
        controller.snapshot
    }

    public var body: some View {
        VStack(spacing: 0) {
            titleBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: CouliSpacing.s3) {
                        controls
                        if snapshot.query.scope == OrderQuery.selfScope, let pending = config.pendingTrack {
                            PendingTrackCardsView(service: pending, texts: texts, onClaim: config.onFindOrder)
                        }
                        content
                    }
                    .padding(.horizontal, CouliSpacing.s4)
                    .padding(.bottom, CouliSpacing.s6)
                    .frame(maxWidth: OrderLayout.maxContentWidth)
                    .frame(maxWidth: .infinity)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(
                            key: OrderListOffsetKey.self, value: geometry.frame(in: .named(OrderListSpace.name)).minY
                        )
                    })
                }
                .coordinateSpace(name: OrderListSpace.name)
                .refreshable { await controller.refreshAndWait() }
                .onPreferenceChange(OrderCardFramesKey.self) { value in
                    frames = value
                    recordTop()
                }
                .onPreferenceChange(OrderListOffsetKey.self) { value in
                    if let value {
                        config.scrolled(offset: Double(value))
                    }
                }
                .onChange(of: controller.snapshot) { _ in
                    restoreStep(proxy)
                    config.onStateChange()
                }
                .onAppear { restoreStep(proxy) }
            }
            .accessibilityIdentifier("orders.list")
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .onAppear {
            controller.start()
            config.pendingTrack?.refresh()
        }
        .couliToast($toast)
        .onChange(of: config.toastKey) { value in
            guard let value else { return }
            toast = value.couli(texts)
            config.toastKey = nil
        }
        .onChange(of: controller.snapshot.toast) { value in
            guard let value else { return }
            toast = value.couli(texts)
            controller.consumeToast()
        }
        .couliSheet(
            isPresented: config.sheet == .platform, dismissOnScrim: { config.sheet = nil },
            restoreFocusTo: $platformFocused, sheet: { platformSheet }
        )
        .couliSheet(
            isPresented: config.sheet == .month, dismissOnScrim: { config.sheet = nil }, restoreFocusTo: $monthFocused,
            sheet: { monthSheet }
        )
    }
}

/// 列表视图实例的挂载记号（StateObject：同一视图实例只建一次；Tab 外壳重建视图时新建一个）。
@MainActor
final class OrderListMount: ObservableObject {
    init(_ config: OrderListPageConfig) {
        config.viewMounted()
    }
}

/// 列表视口坐标系（ScrollView 自身的框：0 就是视口顶边）。
enum OrderListSpace {
    static let name = "orders.list.viewport"
}

/// 各订单卡在列表视口坐标系里的框（order_id → 框）。
struct OrderCardFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 列表骨架（GUIDE 未出稿，按卡片结构自画）。
struct OrderCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            SkeletonBlock(width: 60, height: 20)
            HStack(spacing: CouliSpacing.s3) {
                SkeletonBlock(width: OrderLayout.imageSize, height: OrderLayout.imageSize)
                VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                    SkeletonBlock(height: 16)
                    SkeletonBlock(width: 80, height: 14)
                }
            }
            SkeletonBlock(height: 40)
        }
        .couliCard()
    }
}
