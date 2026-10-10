import Combine
import CouliNetwork
import Foundation

/// 订单详情的阶段。
public enum OrderDetailPhase: String, Sendable {
    case loading
    case content
    /// 传输失败、显示缓存（顶部提示条 + 刷新入口，共性第 26 条）。
    case stale
    /// 30701：范围外、不属于本人、不存在都显示空态（不重试）。
    case empty
    case error
    /// 会话换代后清空（共性第 1 条）：不显示任何旧会话的订单号与金额，不再加载。
    case cleared
}

public struct OrderDetailSnapshot: Equatable {
    public var phase: OrderDetailPhase = .loading
    public var detail: OrderDetail?
    public var error: OrderErrorView?
    public var staleAt: Int64?
    /// 缓存态刷新 / 下拉刷新在途（保留已显示的内容）。
    public var refreshing = false
    public var blocked = false
    public var toast: OrderToast?
    /// 复制成功（polite 播报一次）或失败的提示。
    public var copyToast: OrderToast?

    public init() {}
}

/// 订单详情执行器（OrderDetail 路由；APP-08）。一个路由目的地一份。
/// - 归属：页面（出栈的同步出口 `leave` 作废并取消）+ 会话（`sessionChanged` 同步清空已显示的快照并作废，共性第 1 条）+ 本页最新一次加载；
/// - 30701 显示空态，不重试；42901 进共享禁用期；5xxxx 带 trace6；传输失败有缓存时显示缓存（stale，可刷新，共性第 26 条）；
/// - 成功时写详情缓存（每账号最近 30 条），并交给列表替换那一行（G17）；
/// - 订单号复制只经统一写入口（`copy` 由 App 接 ClipboardWriter：先记 hash，记不上不写，APP-07 第 23、25 条）；分享单没有这条路径。
@MainActor
public final class OrderDetailController: ObservableObject {
    public static let operation = "getOrder"

    @Published public private(set) var snapshot = OrderDetailSnapshot() {
        didSet {
            if snapshot.detail != oldValue.detail {
                detailRevision += 1
            }
        }
    }

    /// 已显示的详情内容每换一次加一（【复制】票据的「详情版本」）。
    public private(set) var detailRevision = 0
    public let orderId: String
    public let gate: OrderRateGate
    private let api: OrderApi
    private weak var env: OrderListEnv?
    private let cache: OrderCacheStore?
    private let requests = OrderInFlight()
    private var left = false
    private var cleared = false
    private var started = false
    private var seq = 0
    private var toastSeq = 0
    private var subscriptions: Set<AnyCancellable> = []
    /// 本页详情请求成功（列表替换那一行，G17）。
    public var onLoaded: ((OrderDetail) -> Void)?
    /// 订单号写剪贴板（App 接统一写入口）；返回 false = 记 hash 失败没写。
    public var copy: ((String) -> Bool)?
    /// 固定身份（构造时一次性取得，APP-09 共性第 65 条，iOS RC-01）：详情、【复制】票据、缓存读写都只用它；之后只与当前会话比较。
    public let owner: OrderOwner

    public init(api: OrderApi, orderId: String, gate: OrderRateGate, env: OrderListEnv, cache: OrderCacheStore?) {
        self.api = api
        self.orderId = orderId
        self.gate = gate
        self.env = env
        self.cache = cache
        owner = env.currentOwner()
        snapshot.blocked = gate.blocked
        gate.$blocked.dropFirst().sink { [weak self] blocked in
            MainActor.assumeIsolated {
                guard let self, !self.left else { return }
                self.snapshot.blocked = blocked
            }
        }.store(in: &subscriptions)
    }

    public var inFlight: Int {
        requests.count
    }

    public var isLeft: Bool {
        left
    }

    /// 固定身份仍是当前会话（只比较）。会话已换代而 App 还没清空这一页时：不发请求、不结算、不读写缓存、不出【复制】票据。
    public var ownerCurrent: Bool {
        guard let env else { return false }
        return env.isCurrent(owner)
    }

    /// 页面出现：只在第一次加载（被盖住再回来不重载）。
    public func start() {
        guard !started, !left, !cleared, ownerCurrent else { return }
        started = true
        load(keep: false)
    }

    /// 错误态的【重试】（30701 不给重试）。
    @discardableResult
    public func retry() -> Bool {
        guard !left, !cleared, ownerCurrent, !gate.active, snapshot.phase == .error else { return false }
        load(keep: false)
        return true
    }

    /// 缓存态的【重试】与下拉刷新（共性第 26 条）：遵守共享禁用期；成功后更新内容与缓存、提示条消失。
    @discardableResult
    public func refresh() -> Bool {
        guard !left, !cleared, ownerCurrent, !gate.active, [.content, .stale].contains(snapshot.phase) else {
            return false
        }
        load(keep: true)
        return true
    }

    /// `.refreshable` 用：发出后只等**本次**请求轮次结束（共性第 30 条）。页面出栈 / 会话换代 / 被新一轮取代 / 刷新任务被取消都立即返回，
    /// 不依赖已被取消的响应；`Task.sleep` 的取消错误不吞掉。
    public func refreshAndWait() async {
        guard refresh() else { return }
        let round = seq
        while waitingRefresh(round) {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
        }
    }

    /// 本轮刷新是否还值得等（测试也用来核对退出条件）。
    func waitingRefresh(_ round: Int) -> Bool {
        !Task.isCancelled && !left && !cleared && seq == round && snapshot.refreshing
    }

    private func load(keep: Bool) {
        requests.cancelAll()
        seq += 1
        let current = seq
        snapshot.toast = nil
        if keep {
            snapshot.refreshing = true
        } else {
            snapshot.phase = .loading
            snapshot.error = nil
        }
        if gate.active {
            settle(.localReject(reason: LocalRejectReason.sendBlocked), keep: keep)
            return
        }
        let call = ApiCall(operationId: Self.operation, pathParams: ["order_id": orderId])
        requests.send(api, call, gate: gate, owner: owner) { [weak self] result in
            guard let self, !left, !cleared, ownerCurrent, current == seq else { return }
            settle(result, keep: keep)
        }
    }

    private func settle(_ result: ApiResult, keep: Bool) {
        snapshot.refreshing = false
        switch result {
        case let .success(data, traceId, _):
            loaded(data, traceId: traceId, keep: keep)
        case let .localReject(reason) where reason == LocalRejectReason.sendBlocked:
            fail(OrderErrorView(actionRaw: OrderErrorKind.retryAfter, textKey: "error.42901",
                                disableMs: gate.remainingMillis), keep: keep)
        case let .localReject(reason) where reason == LocalRejectReason.callCancelled:
            break
        case .localReject:
            fail(
                OrderErrorAction.view(
                    target: OrderErrorAction.detail,
                    result: result,
                    hasCache: false,
                    filtered: false
                ),
                keep: keep
            )
        default:
            failed(result, keep: keep)
        }
    }

    private func loaded(_ data: Data?, traceId: String?, keep: Bool) {
        guard let object = JSONPick.parse(data) as? [String: Any], let detail = OrderJSON.detail(object),
              detail.summary.orderId == orderId
        else {
            fail(OrderErrorView(actionRaw: OrderErrorKind.errorTrace6, textKey: "error.50001", showTrace6: true,
                                traceId: traceId), keep: keep)
            return
        }
        snapshot.detail = detail
        snapshot.staleAt = nil
        snapshot.error = nil
        snapshot.phase = .content
        if let env, ownerCurrent {
            cache?.writeDetail(account: owner.account, detail: detail, fetchedAt: env.now())
        }
        onLoaded?(detail)
    }

    /// 服务端错误或传输失败：30701 空态；42901 进共享禁用期；传输失败有缓存时显示缓存（stale）；其余错误态（带 trace6）。
    private func failed(_ result: ApiResult, keep: Bool) {
        let cached = ownerCurrent ? cache?.readDetail(account: owner.account, orderId: orderId) : nil
        let view = OrderErrorAction.view(
            target: OrderErrorAction.detail, result: result, hasCache: cached != nil, filtered: false
        )
        if view.actionRaw == OrderErrorKind.retryAfter {
            gate.start(view.disableMs ?? ErrorActionMapper.defaultRetryAfterMillis)
        }
        if view.actionRaw == OrderErrorKind.empty30701 {
            snapshot.detail = nil
            snapshot.staleAt = nil
            snapshot.error = view
            snapshot.phase = .empty
            return
        }
        guard view.actionRaw == OrderErrorKind.showStale, let cached else {
            fail(view, keep: keep)
            return
        }
        if keep, snapshot.phase == .content {
            toast(OrderErrorView(actionRaw: OrderErrorKind.networkError, textKey: OrderErrorAction.networkKey))
            return
        }
        snapshot.detail = cached.detail
        snapshot.staleAt = cached.fetchedAt
        snapshot.phase = .stale
        if keep {
            toast(OrderErrorView(actionRaw: OrderErrorKind.networkError, textKey: OrderErrorAction.networkKey))
        }
    }

    private func fail(_ view: OrderErrorView, keep: Bool) {
        if keep, snapshot.detail != nil {
            toast(view)
            return
        }
        snapshot.detail = nil
        snapshot.error = view
        snapshot.phase = .error
    }

    /// 渲染【复制】时取出票据（共性第 41 条，iOS R3-02 / RC-01）：执行器、执行器的固定身份（不是此刻的会话）、详情版本、订单号在此刻固定。
    /// 分享单（脱敏）、没有内容、固定身份已不是当前会话（会话通知还没处理时重画旧页面）返回 nil。
    public func copyTicket() -> OrderDetailCopyTicket? {
        guard !left, !cleared, ownerCurrent, let detail = snapshot.detail else { return nil }
        let number = OrderNumberDisplay.view(detail.summary)
        guard number.copyable, let text = number.text else { return nil }
        return OrderDetailCopyTicket(
            controller: ObjectIdentifier(self), owner: owner, revision: detailRevision,
            orderId: detail.summary.orderId, orderNo: text
        )
    }

    /// 复制订单号（只给自购单）：执行前核对渲染时的票据（仍是本页、没出栈 / 清空、票据身份就是本页固定身份且仍是当前会话、详情版本没变、
    /// 单号一致），任一不符零写入；
    /// 通过后经统一写入口。
    public func copyOrderNo(_ ticket: OrderDetailCopyTicket?, rendered: String) {
        guard let ticket, ticket.controller == ObjectIdentifier(self), !left, !cleared,
              ticket.owner == owner, ownerCurrent, ticket.revision == detailRevision, ticket.orderNo == rendered,
              let detail = snapshot.detail, detail.summary.orderId == ticket.orderId
        else { return }
        let number = OrderNumberDisplay.view(detail.summary)
        guard number.copyable, number.text == ticket.orderNo, let copy else { return }
        toastSeq += 1
        let ok = copy(ticket.orderNo)
        snapshot.copyToast = OrderToast(
            key: ok ? "order_detail.copy.done" : "order_detail.copy.failed", error: nil, id: toastSeq
        )
    }

    public func consumeToast() {
        snapshot.toast = nil
    }

    public func consumeCopyToast() {
        snapshot.copyToast = nil
    }

    private func toast(_ view: OrderErrorView) {
        toastSeq += 1
        snapshot.toast = OrderToast(key: view.textKey ?? OrderErrorAction.networkKey, error: view, id: toastSeq)
    }

    /// 会话换代（共性第 1 条）：同步作废请求并清空已显示的快照（订单号、金额都不再显示），不再加载；App 另把栈里的详情页移出。
    public func sessionChanged() {
        guard !left else { return }
        cleared = true
        requests.cancelAll()
        seq += 1
        snapshot = OrderDetailSnapshot()
        snapshot.phase = .cleared
    }

    /// 页面出栈（同步出口）：作废并取消在途请求，响应回来后不改任何状态。
    public func leave() {
        guard !left else { return }
        left = true
        requests.cancelAll()
        seq += 1
        // 同步结束刷新状态：等待方不再依赖已被取消的响应（共性第 30 条）
        snapshot.refreshing = false
        subscriptions.removeAll()
    }
}

/// 详情【复制】的渲染时票据（共性第 41 条）：不可变值，回调只用它。
public struct OrderDetailCopyTicket: Equatable, Sendable {
    let controller: ObjectIdentifier
    let owner: OrderOwner
    let revision: Int
    public let orderId: String
    public let orderNo: String
}
