import Combine
import CouliNetwork
import Foundation

/// 详情页的阶段。
public enum ProductPhase: String, Sendable {
    case loading
    case content
    case error
}

/// 详情页的状态。
public struct ProductSnapshot {
    public var phase: ProductPhase = .loading
    /// getProduct 的 data（ProductCard）。
    public var product: [String: Any]?
    public var view: ProductDetailView?
    /// 错误态：30141 下架、30143 信息失效等的码与文案键（没有外壳 code 为 -1）。
    public var error: SearchResultView?
    public var shownSeq: Int64?
    /// 42901 限时禁用中：【重试】置灰，到期恢复（共性 4）。
    public var retryBlocked = false
    /// 本平台的购买状态（features.platform_status，R2-01）：随配置变化更新；不是 on 时购买按钮置灰、不发购买意图。
    public var purchase: PlatformPurchase = .on

    public init() {}
}

/// 商品详情执行器（APP-06a）：getProduct（product_key 路径参数、item_ref 原样透传，BR-PROD-11）→ ProductDetailState。
/// 与搜索同一套归属规则：重新加载、离开页面都让旧请求失效并取消，迟到响应只丢弃。
/// 购买只到「发出购买意图」为止（TODO(APP-06b)：open 流程）。
@MainActor
public final class ProductDetailController: ObservableObject {
    @Published public private(set) var snapshot = ProductSnapshot()

    private let api: SearchApi
    private let context: @MainActor () -> [String: Any]
    private let purchaseSource: PurchaseStatusSource?
    private var purchaseObservation: SearchObservation?
    private var session = SearchSession()
    private let block: RetryBlock
    private let requests = InFlightRequests()
    /// 购买结果写回后的权威卡重取（APP-06b：补齐价格字段、30144 重新加载）：与页面加载分开作废，离开页面时一并取消。
    private let patchRequests = InFlightRequests()
    private var patchSeq: Int64 = 0
    private var left = false
    private var started = false
    public let platform: String
    public let productKey: String
    public let itemRef: String?

    /// context：{loggedIn, privacy}（ProductDetailState.map 的第二个参数），每次结算时现取。
    /// purchase：平台购买状态的配置源（R2-01，03 §7.4、BR-PROD-10）；订阅它的变化，出栈时注销。
    public init(
        api: SearchApi,
        platform: String,
        productKey: String,
        itemRef: String?,
        purchase: PurchaseStatusSource? = nil,
        context: @escaping @MainActor () -> [String: Any],
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.api = api
        self.platform = platform
        self.productKey = productKey
        self.itemRef = itemRef
        self.context = context
        purchaseSource = purchase
        block = RetryBlock(clock: clock)
        snapshot.purchase = purchase?.purchase(platform: platform) ?? .on
        purchaseObservation = purchase?.observePurchaseStatus { [weak self] in
            self?.purchaseChanged()
        }
    }

    public var inFlightCount: Int {
        requests.count
    }

    /// 页面打开：只在第一次生效（被别的页面盖住再回来不重新加载）。
    public func start() {
        guard !started, !left else { return }
        started = true
        fetch()
    }

    /// 以进程内的卡片种子显示（APP-07 G09：剪贴板 parse 只有 1 张卡）：直接进内容态，不发 getProduct；卡上的 link_id 原样留给购买
    /// （entry_source=parse，AC-S1-02-TB）。只在第一次生效，之后的 `start()` 不再加载。
    public func startSeeded(_ product: [String: Any]) {
        guard !started, !left else { return }
        started = true
        snapshot.product = product
        snapshot.view = ProductDetailState.map(product, context: context())
        snapshot.phase = .content
        snapshot.error = nil
    }

    /// 【重试】：只在错误态、限流期外生效。
    @discardableResult
    public func retry() -> Bool {
        guard snapshot.phase == .error, !block.active, !left else { return false }
        fetch()
        return true
    }

    /// 页面真正出栈：作废并取消在途请求，之后的迟到响应只丢弃。
    public func leave() {
        left = true
        session.leave()
        requests.cancelAll()
        patchRequests.cancelAll()
        block.cancelTimer()
        purchaseObservation?.cancel()
        purchaseObservation = nil
    }

    /// 此刻能否购买：详情映射允许（有按钮文案键、不是下架或价格不可用），且平台购买状态为 on。
    public var canBuy: Bool {
        snapshot.phase == .content && snapshot.view?.buyEnabled == true && snapshot.purchase.allowsBuy
    }

    /// 发出购买意图（APP-06a 只到这里）。TODO(APP-06b)：open 购买（8 秒超时、同键重试、可取消加载层）。
    /// 发出前再按此刻的配置核对一次平台购买状态（R2-01：配置刚变、界面还没刷新时也不放行）。
    public func buyIntent() -> Bool {
        guard !left else { return false }
        purchaseChanged()
        return canBuy
    }

    /// 用购买结果更新这张卡（APP-06b，BR-PRICE-12：open 响应的新价格、new_link_id、无返利状态，30141 下架）：重新映射详情模型
    /// （下架、价格未知时购买按钮立即置灰，APP-06b 共性第 28 条）。不是内容态、已离开时不改。
    public func updateProduct(_ transform: ([String: Any]) -> [String: Any]) {
        guard !left, snapshot.phase == .content, let product = snapshot.product else { return }
        let next = transform(product)
        snapshot.product = next
        snapshot.view = ProductDetailState.map(next, context: context())
    }

    /// 按这张卡的 product_key + item_ref 重取权威商品卡（APP-06b 共性第 7、9、17、26 条），到达时用 `merge`（此刻的卡, 重取到的卡）
    /// 决定落到页面上的卡（补齐只填未知字段且核对卡片版本；30144 整卡替换但不覆盖之后写入的购买结果）。不进加载态、不打断弹层；
    /// 失败、离开页面时什么都不做（卡片保持原样，价格未知就按未知展示）。
    /// `expected`：发起补齐的购买尝试固定的请求归属（`PurchaseAttempt.source.request`，r3f NEW-03），交网络层只比较；换号后零发送。
    public func refetch(
        expected: RequestOwnership? = nil, merge: @escaping ([String: Any], [String: Any]) -> [String: Any]
    ) {
        guard !left, !productKey.isEmpty else { return }
        patchSeq += 1
        let seq = patchSeq
        let query = itemRef.map { "item_ref=" + SearchQuery.encode($0) }
        let call = ApiCall(operationId: "getProduct", pathParams: ["product_key": productKey], query: query)
        patchRequests.send(api, call, seq: seq, expected: expected) { [weak self] result in
            guard let self, !left, case let .success(data, _, _) = result, let fresh = JSON.parse(data) else { return }
            updateProduct { merge($0, fresh) }
        }
    }

    /// 配置变化（或发购买意图前）：按此刻的配置更新购买状态；离开页面后不再更新。
    public func purchaseChanged() {
        guard !left, let source = purchaseSource else { return }
        let current = source.purchase(platform: platform)
        if snapshot.purchase != current {
            snapshot.purchase = current
        }
    }

    private func fetch() {
        guard !productKey.isEmpty else { return }
        let seq = session.begin(kind: "detail")
        requests.cancelAll()
        snapshot.phase = .loading
        snapshot.error = nil
        let query = itemRef.map { "item_ref=" + SearchQuery.encode($0) }
        let call = ApiCall(operationId: "getProduct", pathParams: ["product_key": productKey], query: query)
        requests.send(api, call, seq: seq) { [weak self] result in
            self?.settled(result, seq: seq)
        }
    }

    private func settled(_ result: ApiResult, seq: Int64) {
        guard !left, session.accept(seq) else { return }
        snapshot.shownSeq = seq
        if case let .success(data, _, _) = result, let product = JSON.parse(data) {
            snapshot.product = product
            snapshot.view = ProductDetailState.map(product, context: context())
            snapshot.phase = .content
            snapshot.error = nil
        } else {
            let envelope = SearchResults.envelope(result)
            snapshot.error = envelope.map(SearchResultState.map) ?? SearchResults.transportError(result)
            snapshot.phase = .error
            let millis = SearchResults.disableMillis(result)
            if millis > 0 {
                snapshot.retryBlocked = true
                block.start(millis) { [weak self] in
                    guard let self, !left else { return }
                    snapshot.retryBlocked = false
                }
            }
        }
    }
}
