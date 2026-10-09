import Combine
import Foundation
import ProductSearch
import Trade

/// 搜索页用到的文案键（三端同名）。契约 texts.default.json 已有的（error.*、external_page.retry）直接取；其余是 App 草稿表
/// SearchDraftTexts 里「待定稿，不得提审」的键（TODO(N-27)）。本模块不出现中文，文案一律经 `SearchTexts` 取。
public enum SearchKeys {
    public static let back = "search.back"
    public static let placeholder = "search.placeholder"
    public static let clear = "search.clear"
    public static let submit = "search.submit"
    public static let historyTitle = "search.history.title"
    public static let historyClear = "search.history.clear"
    public static let tabsLabel = "search.tabs"
    public static let filterCoupon = "search.filter.coupon"
    public static let filterPrice = "search.filter.price"
    public static let filterPriceRange = "search.filter.price_range"
    public static let filterPriceMinOnly = "search.filter.price_min_only"
    public static let filterPriceMaxOnly = "search.filter.price_max_only"
    public static let sheetMin = "search.filter.sheet.min"
    public static let sheetMax = "search.filter.sheet.max"
    public static let sheetNote = "search.filter.sheet.note"
    public static let sheetReset = "search.filter.sheet.reset"
    public static let sheetConfirm = "search.filter.sheet.confirm"
    public static let sheetInvalid = "search.filter.sheet.invalid"
    public static let sheetClose = "search.filter.sheet.close"
    public static let emptyTitle = "search.empty.title"
    public static let emptyMessage = "search.empty.message"
    public static let fallbackTitle = "search.fallback.title"
    public static let fallbackNote = "search.fallback.note"
    public static let unavailableTitle = "search.unavailable.title"
    public static let loadMore = "search.load_more"
    public static let loading = "search.loading"
    public static let end = "search.end"
    public static let staleNotice = "search.stale_notice"
    public static let disclaimerTitle = "card.disclaimer_title"
    public static let disclaimerClose = "card.disclaimer_close"
    public static let retry = "external_page.retry"
    /// 比价原因行与相似商品入口（APP-06b，契约 no_rebate.price_compare*）。
    public static let compareReason = "no_rebate.price_compare"
    public static let similar = "no_rebate.price_compare.similar"
    /// 购买超时条（ProductBuyTimeout，契约 buy.timeout；APP-06b 共性第 29 条）。
    public static let buyTimeout = "buy.timeout"

    public static func sort(_ raw: String) -> String {
        "search.sort." + raw
    }
}

/// 搜索页要持久化的页面状态（共性 20：进程被系统回收后恢复）：查询条件、输入框文字、价格面板草稿与是否打开、滚动锚点。
/// App 按路由身份（RouteDestination）保存到场景状态里（SceneStorage），重建时先恢复条件、再加载结果、最后恢复位置。
public struct SearchPageState: Codable, Equatable, Sendable {
    public var conditions: SearchConditions
    public var input: String
    public var priceDraftMin: String?
    public var priceDraftMax: String?
    public var priceSheetOpen: Bool
    /// 列表视口顶部的那张结果卡的序号（滚动锚点）；没有结果时为 nil。
    public var scrollAnchor: Int?
    /// 锚点卡顶边相对视口顶边的偏移（pt，负数表示卡的上部已滚出视口；R3-01）。旧数据没有时按 0（卡顶对齐视口顶）。
    public var scrollOffset: Double?

    public init(
        conditions: SearchConditions = SearchConditions(), input: String = "", priceDraftMin: String? = nil,
        priceDraftMax: String? = nil, priceSheetOpen: Bool = false, scrollAnchor: Int? = nil,
        scrollOffset: Double? = nil
    ) {
        self.conditions = conditions
        self.input = input
        self.priceDraftMin = priceDraftMin
        self.priceDraftMax = priceDraftMax
        self.priceSheetOpen = priceSheetOpen
        self.scrollAnchor = scrollAnchor
        self.scrollOffset = scrollOffset
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// 解不出来（版本变化、数据损坏）时返回 nil，页面按路由参数从头打开。
    public static func decode(_ data: Data?) -> SearchPageState? {
        data.flatMap { try? JSONDecoder().decode(SearchPageState.self, from: $0) }
    }
}

/// 滚动恢复的目标（R3-01、共性 33）：哪一轮查询（queryRound）的哪张顶部卡、卡顶相对视口顶边的偏移（pt）。
public struct SearchScrollTarget: Equatable, Sendable {
    public let round: Int
    public let index: Int
    public let offset: Double

    public init(round: Int, index: Int, offset: Double) {
        self.round = round
        self.index = index
        self.offset = offset
    }
}

/// 搜索页的配置（App 组合：执行器、历史、文案、跳转出口）。
@MainActor
public final class SearchPageConfig: ObservableObject {
    public let controller: SearchController
    public let history: SearchHistory
    public let texts: SearchTexts
    /// 路由参数（routes.json Search：q、platform 都可选）。
    public let initialQuery: String?
    public let initialPlatform: String?
    /// 进程被回收前保存的页面状态（有就按它恢复，不再按路由参数从头打开；共性 20）。
    public let restored: SearchPageState?
    /// 输入框文字与价格区间面板未提交的草稿：放在随路由目的地存活的配置里，返回本页、界面重建后不丢（共性 17），
    /// 并随页面状态持久化（共性 20）。
    @Published public var input = ""
    @Published public var priceDraftMin: String?
    @Published public var priceDraftMax: String?
    @Published public var showsPriceSheet = false
    /// 视口顶部那张结果卡的序号（页面按实际视口记录，随页面状态持久化）。
    @Published public var scrollAnchor: Int?
    /// 锚点卡顶边相对视口顶边的偏移（pt，R3-01）。滚动中每帧都会变：不发布（不让整页每帧重画），变化后稍后合并保存。
    public private(set) var scrollOffset: Double?
    /// 待恢复的滚动位置（进程回收后重建时设一次）。列表上的恢复任务（SearchScrollTracker）按它执行，结束（到位、已到最远处、
    /// 用户拖动）时清掉；新一轮查询、出栈时这里直接清掉。有目标期间不记录视口顶部的卡。
    public private(set) var restoreTarget: SearchScrollTarget?
    /// 恢复发起的那一轮查询（queryRound）：这一轮不算「新查询」，不重置锚点。
    private var restoreRound: Int?
    /// 页面已真正出栈（`leave()`）：之后不再记录视口顶部的卡。
    private var departed = false
    public var onBack: () -> Void = {}
    /// 打开商品详情（经 Router 打开 ProductDetail：platform、product_key、item_ref）。
    public var onOpenProduct: (_ platform: String, _ productKey: String, _ itemRef: String?) -> Void = { _, _, _ in }
    /// 列表卡的【购买】（APP-06b：App 交给本页的 OpenPurchaseController.buy；点击前已核对平台购买状态）。
    public var onBuy: (_ item: [String: Any]) -> Void = { _ in }
    /// 【看看相似商品】（BR-PRICE-08；比价无返利弹窗关闭后卡片原因行上的入口，共性第 15 条）。
    public var onSimilar: (_ item: [String: Any]) -> Void = { _ in }
    /// 本页的购买执行器（APP-06b）：卡片按钮的加载 / 限流、超时条（共性第 29 条）；浮层由 App 盖在页面之上。
    /// 它的每次发布都转成本页的发布，让卡片按钮跟着重画。
    public var purchaseController: OpenPurchaseController? {
        didSet {
            purchaseRelay = purchaseController?.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    private var purchaseRelay: AnyCancellable?
    /// 页面状态变化（去重后）：App 写入场景状态（共性 20）。
    public var onStateChange: (SearchPageState) -> Void = { _ in }
    /// 平台购买状态的配置源（features.platform_status，R2-01）：列表卡购买按钮同样按它置灰。
    public let purchase: PurchaseStatusSource?
    /// 购买状态配置变化计数（订阅到变化就加一，让页面重画卡片按钮）。
    @Published public private(set) var purchaseRevision = 0
    private var purchaseObservation: SearchObservation?
    /// 最近一次记下滚动锚点时的查询轮次（新一轮查询开始时重置锚点，R2-02）。
    private var anchorRound: Int?
    private var started = false
    private var lastSaved: SearchPageState?
    private var observation: AnyCancellable?
    private var offsetSave: DispatchWorkItem?
    private var offsetSaveGeneration = 0

    public init(
        controller: SearchController,
        history: SearchHistory,
        texts: SearchTexts,
        initialQuery: String?,
        initialPlatform: String?,
        restored: SearchPageState? = nil,
        purchase: PurchaseStatusSource? = nil
    ) {
        self.controller = controller
        self.history = history
        self.texts = texts
        self.initialQuery = initialQuery
        self.initialPlatform = initialPlatform
        self.restored = restored
        self.purchase = purchase
        purchaseObservation = purchase?.observePurchaseStatus { [weak self] in
            self?.purchaseRevision += 1
        }
        // 本页或执行器任何发布都可能改变要保存的状态：在本轮发布结束后取一次快照，去重后交给 App。
        observation = objectWillChange.merge(with: controller.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.persist() }
            }
    }

    /// 页面第一次出现：有保存的状态就恢复（先条件，再结果，再位置），否则按路由参数打开。
    /// 返回 true 表示应把焦点放到输入框（没有关键词的新页面）。
    @discardableResult
    public func start() -> Bool {
        guard !started else { return false }
        started = true
        if let restored {
            input = restored.input
            priceDraftMin = restored.priceDraftMin
            priceDraftMax = restored.priceDraftMax
            showsPriceSheet = restored.priceSheetOpen
            scrollAnchor = restored.scrollAnchor
            scrollOffset = restored.scrollOffset
            controller.restore(restored.conditions, minimumItems: restored.scrollAnchor.map { $0 + 1 } ?? 0)
            let round = controller.snapshot.queryRound
            restoreRound = round
            restoreTarget = restored.scrollAnchor.map {
                SearchScrollTarget(round: round, index: $0, offset: restored.scrollOffset ?? 0)
            }
            persist()
            return false
        }
        input = initialQuery ?? ""
        controller.open(query: initialQuery, platform: initialPlatform)
        persist()
        if let query = initialQuery, !SearchQuery.normalizeKeyword(query).isEmpty {
            history.record(query)
            return false
        }
        return true
    }

    /// 此刻要保存的页面状态。
    public func state() -> SearchPageState {
        SearchPageState(
            conditions: controller.snapshot.conditions,
            input: input,
            priceDraftMin: priceDraftMin,
            priceDraftMax: priceDraftMax,
            priceSheetOpen: showsPriceSheet,
            scrollAnchor: scrollAnchor,
            scrollOffset: scrollAnchor == nil ? nil : scrollOffset
        )
    }

    /// 恢复任务结束（到位、已到最远处、用户拖动、新查询）：清掉同一个目标，之后照常记录视口顶部的卡。
    public func endRestore(_ target: SearchScrollTarget) {
        if restoreTarget == target {
            restoreTarget = nil
        }
    }

    /// 页面真正出栈：恢复目标作废，延迟保存取消（出栈后保存内容由 App 删除）。
    public func leave() {
        departed = true
        restoreTarget = nil
        offsetSave?.cancel()
        offsetSave = nil
    }

    /// 立即保存最新页面状态（R3F-03）：取消还没执行的延迟保存，同步交给 App。进后台、列表被详情盖住（冻结记录）前调用。
    public func flushState() {
        offsetSave?.cancel()
        offsetSave = nil
        persist()
    }

    /// 某个平台此刻的购买状态原始取值（每次现取）；没有配置源为 nil。
    public func purchaseStatusRaw(platform: String) -> String? {
        purchase?.purchaseStatus(platform: platform)
    }

    /// 列表卡购买按钮点击前再核对一次（R2-01）：平台不是 on 时不处理。
    public func buyAllowed(platform: String) -> Bool {
        purchase?.purchase(platform: platform).allowsBuy ?? true
    }

    /// 视口顶部的结果卡变化（R3-01，共性 17、20、29）：页面按列表坐标系里各卡的实际位置算出视口顶部那张卡（第一张底边
    /// 还在视口顶边以下的卡）及其顶边偏移，交给这里记下。页面被详情盖住时不再上报（冻结），只有新一轮查询（`persist`
    /// 里按 queryRound 判断）或路由真正出栈（App 删除保存内容）时才重置。恢复位置还没完成时不改。
    public func topResultCardChanged(index: Int, offset: Double) {
        // 已出栈（R3I-03，共性 42）：恢复随出栈取消，迟到的排版 / 补页上报不再改写锚点。
        guard controller.snapshot.phase == .content, restoreTarget == nil, !departed else { return }
        let rounded = offset.rounded()
        let offsetChanged = scrollOffset != rounded
        scrollOffset = rounded
        if scrollAnchor != index {
            // 发布会触发一次保存，偏移已先写好，一起保存。
            scrollAnchor = index
        } else if offsetChanged {
            scheduleOffsetSave()
        }
    }

    /// 同一张卡内滚动只改偏移：合并到停下后再保存一次（不每帧写场景状态）。进后台、被盖住时由 `flushState` 立即保存。
    private func scheduleOffsetSave() {
        offsetSave?.cancel()
        offsetSaveGeneration += 1
        let generation = offsetSaveGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                // 执行前核对：仍是当前这一次延迟保存（没被 flushState / leave 取消、没被新的替换）。
                guard let self, self.offsetSave != nil, self.offsetSaveGeneration == generation else { return }
                self.offsetSave = nil
                self.persist()
            }
        }
        offsetSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// 新一轮查询开始（queryRound 变了、且不是恢复发起的那一轮）：锚点重置，列表从顶部开始。
    private func resetAnchorOnNewQuery() {
        let round = controller.snapshot.queryRound
        guard round != anchorRound else { return }
        if anchorRound != nil, round != restoreRound {
            scrollAnchor = nil
            scrollOffset = nil
        }
        // 恢复目标只属于它那一轮查询：轮次变了（用户开始新查询）就作废。
        if let target = restoreTarget, target.round != round {
            restoreTarget = nil
        }
        anchorRound = round
    }

    private func persist() {
        guard started else { return }
        resetAnchorOnNewQuery()
        let current = state()
        guard current != lastSaved else { return }
        lastSaved = current
        onStateChange(current)
    }
}
