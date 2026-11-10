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
    /// 各卡在视口里的框（只给「视口顶部那张卡」的记录用，不参与绘制）：放在不被观察的盒子里，写入不触发重绘。
    /// 原为 @State：半屏开关的动画期间卡片框逐帧变化 → 写 State → 重算 body → 框再变，动画不断叠加、事件循环不空闲
    /// （APP-08v-a 测试 v3 月份半屏用例复现，评审 r1 后修）。
    @State var cardFrames = OrderCardFrameStore()
    /// 列表视口高与头部高（空态在列表区上下居中用，评审 r1 S2-4）。
    @State var viewportHeight: CGFloat = 0
    @State var headerHeight: CGFloat = 0
    /// 自购子 Tab 顶部待跟单卡区的高（含其下 12；没有卡时 0）：空态居中时一并扣掉（评审 r2 S2-1）。
    @State var pendingHeight: CGFloat = 0
    /// 没有订单时各档空态的自然高度（`EmptyStateDensity.rawValue` → 高）：按剩余高度挑档用（测试 v5 跟进）。
    @State var emptyHeights: [Int: CGFloat] = [:]
    /// 冷启动恢复对齐之后的复核窗口（FU-IOS-NATIVE-TABBAR）：列表伸到系统标签栏下面后，`scrollTo` 之后约 1 秒惰性列表补量行高，SwiftUI
    /// 会把滚动位置重置回顶部（实测 iOS 26.5，列表不伸到标签栏下时不发生）。窗口内列表被重置回顶部且目标不是第一张卡，按同一目标再对齐
    /// 一次；用户拖动或点状态栏回顶即取消，Tab 切回不开（见 `settleRestore`）。
    @State var restoreSettle: OrderRestoreSettle?
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
                    // 项间距由各项自己的下边距给（12）：没有待跟单卡时不多占一个间距（画板筛选行 → 首卡 18）
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            controls
                                .background(GeometryReader { geometry in
                                    Color.clear
                                        .onAppear { headerHeight = geometry.size.height }
                                        .onChange(of: geometry.size.height) { headerHeight = $0 }
                                })
                                .padding(.bottom, CouliSpacing.s3)
                            if snapshot.query.scope == OrderQuery.selfScope, let pending = config.pendingTrack {
                                OrderListPendingSlot(service: pending, texts: texts, onClaim: config.onFindOrder)
                                    .background(GeometryReader { geometry in
                                        Color.clear
                                            .onAppear { pendingHeight = geometry.size.height }
                                            .onChange(of: geometry.size.height) { pendingHeight = $0 }
                                            .onDisappear { pendingHeight = 0 }
                                    })
                            }
                            content
                        }
                        // 只用来显示的列表尾（断网缓存 / 翻页失败提示连同【重试】、翻页加载中、搜索条数、查询范围提示）放在惰性列表之外：
                        // 常驻、不参与惰性估高。已找到的触发条件：这类可变高文字留在惰性列表页脚里时，列表停在中部开半屏，事件循环不空闲
                        // （测试 v3 月份半屏用例；评审 r1 / r2 后修）。惰性列表里只留负责自动翻页的「上拉加载更多」
                        listTail
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
                .modifier(OrderScrollInteraction(onInteract: cancelRestoreSettle))
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { viewportHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { viewportHeight = $0 }
                })
                .refreshable { await controller.refreshAndWait() }
                .onPreferenceChange(OrderCardFramesKey.self) { value in
                    cardFrames.frames = value
                    recordTop()
                }
                .onPreferenceChange(OrderListOffsetKey.self) { value in
                    if let value {
                        config.scrolled(offset: Double(value))
                        settleRestore(offset: value, proxy)
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
        .background(alignment: .top) {
            // 600 内容列（头部 + 列表同一列；窄屏 = 全宽）的测量框
            Color.clear
                .frame(maxWidth: OrderLayout.maxContentWidth)
                .couliProbe("orders.content", role: "column")
                .frame(maxWidth: .infinity)
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

/// 自购子 Tab 顶部的待跟单卡（APP-06v-b）：有卡时与下方隔 12，没卡时不占位。
struct OrderListPendingSlot: View {
    @ObservedObject var service: PendingTrackService
    let texts: OrderTexts
    let onClaim: () -> Void

    var body: some View {
        PendingTrackCardsView(service: service, texts: texts, onClaim: onClaim)
            .padding(.bottom, service.state.cards.isEmpty ? 0 : CouliSpacing.s3)
    }
}

/// 列表视图实例的挂载记号（StateObject：同一视图实例只建一次；Tab 外壳重建视图时新建一个）。
@MainActor
final class OrderListMount: ObservableObject {
    init(_ config: OrderListPageConfig) {
        config.viewMounted()
    }
}

/// 卡片框的存放处（引用类型、不发布变化）。
@MainActor
final class OrderCardFrameStore {
    var frames: [String: CGRect] = [:]
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

/// 列表加载骨架（brief §2.3，按新卡结构）：头行（徽标块 + 右侧时间块）、64 图块 + 右列三行、分隔线、两列数字块、胶囊块。
/// `probe`：测量前缀（只给第一张，`orders.skeleton.0`）。
struct OrderListSkeletonCard: View {
    var probe: String?

    private func block(_ name: String, width: CGFloat? = nil, height: CGFloat) -> some View {
        SkeletonBlock(width: width, height: height).orderProbe(probe.map { "\($0).\(name)" })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            HStack {
                block("badge", width: 56, height: 20)
                Spacer(minLength: CouliSpacing.s2)
                block("time", width: 48, height: 14)
            }
            HStack(alignment: .top, spacing: CouliSpacing.s3) {
                block("image", width: OrderLayout.imageSize, height: OrderLayout.imageSize)
                VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                    block("line1", height: 16)
                    block("line2", width: 64, height: 12)
                    block("line3", width: 160, height: 12)
                }
            }
            Rectangle().fill(CouliColor.borderSubtle).frame(height: 1).orderProbe(probe.map { "\($0).divider" })
            HStack(alignment: .top, spacing: CouliSpacing.s4) {
                block("amount1", width: 72, height: 36).frame(maxWidth: .infinity, alignment: .leading)
                block("amount2", width: 72, height: 36).frame(maxWidth: .infinity, alignment: .leading)
            }
            block("pill", width: 96, height: CouliComponentMetric.tagMinHeight)
        }
        .couliCard()
        .orderProbe(probe.map { "\($0).card" })
    }
}
