import Combine
import CouliNetwork
import Foundation

/// 待跟单卡执行器要的环境（App 给；都在主线程取值）。
@MainActor
public protocol PendingTrackEnv: OrderOwnerSource {
    /// 本机有没有通知权限的申请记录（PermissionRequester 的拒绝记录；iOS 系统已拒绝也算申请过，I03）。卡内「点过」另由 hub 记。
    var requestedBefore: Bool { get }
    /// 点了卡内【开启通知】且复核后仍应申请：经统一权限入口（PermissionRequester，purposeShown=true：通知行本身就是用途说明，
    /// 共性第 4 条）弹系统框，结束后刷新 hub 的通知状态。
    /// `isValid`：点击时捕获的显示位置有效性（页面仍在、会话世代未变、任务未取消，共性第 31 条）；App 再并上自己在点击时捕获的
    /// 会话 / 隐私 / 环境版本，一路交给 PermissionRequester（开始时、查完状态后、真正弹系统框前都复核）。
    func requestPush(isValid: @escaping @MainActor () -> Bool) async
}

/// 待跟单卡【开启通知】与关闭入口的渲染时票据（APP-08 共性第 42、46 条，iOS R3-03 / RC-05；APP-09 第 63、65 条）：执行器、显示世代
/// （显示位置离开、清空、会话换代都推进）、会话世代、执行器的固定身份、卡片（link_id + attempt_id）与这张卡的有效期（卡片从显示中消失即
/// 结束，再出现是新的一期）都在渲染这一刻固定；回调只用它，持久化「点过」或发请求前先比较，异步等待沿用同一票据。切走再切回、
/// 换代后重新显示、拉取先空后又取回同一 attempt 的卡都会拿到新票据，旧回调不会复活。
public struct PendingTrackTicket: Equatable, Sendable {
    let service: ObjectIdentifier
    let generation: Int
    let epoch: Int
    let owner: OrderOwner
    let life: Int
    public let card: PendingTrackCardView
}

/// 待跟单卡区域的状态。`busy` 是关闭在途的尝试（key：link_id + attempt_id，跨显示位置共享）。
public struct PendingTrackState: Equatable {
    public var cards: [PendingTrackCardView] = []
    public var busy: Set<String> = []
    public var blocked = false
    public var toast: OrderToast?

    public init() {}
}

/// 待跟单卡执行器（订单列表自购子 Tab 顶部、发起购买的页面外跳回前台后，G07）。一个显示位置一份，只在主线程使用。
/// - 拉取 `GET /v1/orders/pending-tracks`：不缓存到磁盘，不显示 jumped_at 推算出的任何时长；`platform` 不为 nil 时只显示同平台那一张；
/// - 归属：会话世代（hub.sessionEpoch 变化即作废）+ 页面仍在 + 本位置最新一次拉取；迟到的只丢弃；
/// - 关闭：按渲染时的卡片项（不取「当前最新」的卡）；在途时各位置按钮忙碌、不重复发；成功的尝试记进 hub（迟到的旧快照不得复活它，
///   同一 link 的新 attempt_id 照常显示）；20001 重拉；传输失败保留并轻提示网络错误；5xxxx 轻提示对应错误文案 + trace6；42901 进共享禁用期；
///   10405 由网络层的强更分流处理（不另写强更逻辑）；
/// - 42901 禁用期内拉取与关闭都不发（执行层），关闭按钮随之禁用；禁用期结束后被拦下的拉取补一次（鸿蒙 H19 同口径）；
/// - 【开启通知】：只有用户点了才申请，执行前按最新的本机记录与系统状态复核；点过之后这一行在各位置立即消失。
@MainActor
public final class PendingTrackService: ObservableObject {
    public static let listOperation = "listPendingTracks"
    public static let networkErrorKey = OrderErrorAction.networkKey

    @Published public private(set) var state = PendingTrackState()
    public private(set) var platform: String?
    private let api: OrderApi
    let hub: OrderSessionHub
    weak var env: PendingTrackEnv?
    private let fetches = OrderInFlight()
    private let closes = OrderInFlight()
    private var items: [PendingTrack] = []
    var left = false
    private var fetchSeq = 0
    private var deferredFetch = false
    private var ownDismissing: Set<String> = []
    private var toastSeq = 0
    /// 显示世代：会话换代、清空、作废时加一（票据的「页面 / 卡片版本」）。
    public internal(set) var generation = 0
    /// 卡内【开启通知】的待执行申请（页面出栈、会话换代、离开显示位置时同步取消，共性第 31 条）。
    var pushTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    /// 固定身份（构造时一次性取得；会话换代通知里随清空一起重建，APP-09 共性第 65 条）：拉取结算、票据、通知行的登录判断都只用它。
    public private(set) var owner: OrderOwner
    /// 固定身份对应的会话世代（与 `owner` 同时取得、同时重建）；票据只用它，不在渲染时读 hub 的当前世代。
    var boundEpoch: Int
    /// 每张在显示中的卡的有效期编号（key → 期号）：卡从显示中消失即删除，再出现给新的期号（共性第 46 条）。
    var cardLives: [String: Int] = [:]
    var lifeSeq = 0
    /// 显示位置的挂载计数（视图 onAppear / onDisappear）；从没挂过视图（执行层单测、外跳场景还没渲染）按在显示中。
    var displayCount = 0
    var everDisplayed = false

    public init(api: OrderApi, hub: OrderSessionHub, env: PendingTrackEnv, platform: String? = nil) {
        self.api = api
        self.hub = hub
        self.env = env
        self.platform = platform
        owner = env.currentOwner()
        boundEpoch = hub.sessionEpoch
        state.blocked = hub.gate.blocked
        hub.gate.$blocked.dropFirst().sink { [weak self] blocked in
            MainActor.assumeIsolated { self?.gateChanged(blocked) }
        }.store(in: &subscriptions)
        Publishers.Merge4(
            hub.$closed.map { _ in () }, hub.$dismissing.map { _ in () },
            hub.$pushRowUsed.map { _ in () }, hub.$notification.map { _ in () }
        ).dropFirst(4).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.republishSoon() }
        }.store(in: &subscriptions)
        // @Published 在 willSet 时发出：新世代取订阅收到的值（此刻 hub.sessionEpoch 还是旧值）
        hub.$sessionEpoch.dropFirst().sink { [weak self] epoch in
            MainActor.assumeIsolated { self?.sessionChanged(epoch) }
        }.store(in: &subscriptions)
    }

    /// 在途的拉取个数（测试核对作废）。
    public var inFlight: Int {
        fetches.count + closes.count
    }

    /// 拉一次（`onlyPlatform` 只给发起购买的页面：外跳回到前台后，只显示同平台那一张；nil 沿用上次）。
    public func refresh(onlyPlatform: String? = nil) {
        guard !left, ownerCurrent else { return }
        if let onlyPlatform {
            platform = onlyPlatform
        }
        // 42901 禁用期内不发（执行层拦截；会话级共享，重进页面也一样）；期满补拉一次
        guard !hub.gate.active else {
            deferredFetch = true
            return
        }
        deferredFetch = false
        fetchSeq += 1
        let seq = fetchSeq
        fetches.cancelAll()
        fetches
            .send(api, ApiCall(operationId: Self.listOperation), gate: hub.gate, owner: owner) { [weak self] result in
                guard let self, !left, ownerCurrent, seq == fetchSeq else { return }
                switch result {
                case let .success(data, _, _):
                    guard let parsed = OrderJSON.pendingTracks(JSONPick.parse(data)) else { return }
                    items = parsed
                    publish()
                case .failure:
                    hub.gate.start(OrderErrorAction.disableMillis(result))
                    if OrderErrorAction.disableMillis(result) > 0 {
                        deferredFetch = true
                    }
                case let .localReject(reason) where reason == LocalRejectReason.sendBlocked:
                    deferredFetch = true
                default:
                    // 拉不到时保持原样（不清掉已显示的卡，也不显示推算出的卡）
                    break
                }
            }
    }

    /// 通知权限或会话变了（回到前台、申请结束）：按新状态重算通知行。
    public func recompute() {
        guard !left else { return }
        publish()
    }

    func republishSoon() {
        guard !left else { return }
        // @Published 在 willSet 时发出：等这一轮赋值完成后再读 hub 的新值
        Task { @MainActor [weak self] in self?.recompute() }
    }

    private func currentCards() -> [PendingTrackCardView] {
        // 固定身份已不是当前会话：不显示（App 的换代通知随后清空并重建）
        guard ownerCurrent else { return [] }
        let requested = hub.pushRowUsed || (env?.requestedBefore ?? true)
        let all = PendingTrackCards.cards(
            items, session: owner.member ? PendingTrackRaw.member : PendingTrackRaw.guest,
            notification: hub.notification, requestedBefore: requested
        ).filter { !hub.closed.contains($0.key) }
        guard let platform else { return all }
        return all.filter { $0.platform == platform }
    }

    func publish() {
        var next = state
        next.cards = currentCards()
        // 忙碌从会话级的在途关闭派生（共性第 14 条）：期间另一轮查询重建了同一尝试的卡片仍是忙碌；结果回来时统一清掉
        next.busy = hub.dismissing
        next.blocked = hub.gate.blocked
        updateLives(next.cards)
        state = next
    }

    private func gateChanged(_ blocked: Bool) {
        guard !left else { return }
        state.blocked = blocked
        if !blocked, deferredFetch {
            refresh()
        }
    }

    /// 关闭票据里的卡（渲染时的卡片项）。票据失效、禁用中、在途中（任一位置）、卡片已不是当前显示的那一张都不发，返回 false。
    @discardableResult
    public func dismiss(_ ticket: PendingTrackTicket) -> Bool {
        let card = ticket.card
        guard ticketValid(ticket), !hub.gate.active,
              state.cards.contains(where: { $0.linkId == card.linkId && $0.attemptId == card.attemptId }),
              hub.beginDismiss(card.key)
        else { return false }
        ownDismissing.insert(card.key)
        publish()
        let call = ApiCall(
            operationId: PendingTrackDismiss.operation, pathParams: ["link_id": card.linkId],
            body: PendingTrackDismiss.body(card.attemptId)
        )
        closes.send(api, call, gate: hub.gate, owner: ticket.owner) { [weak self] result in
            self?.dismissed(card, result)
        }
        return true
    }

    private func dismissed(_ card: PendingTrackCardView, _ result: ApiResult) {
        // 结果回来一律清掉这次尝试的忙碌（期间另一轮查询重建了同一尝试的卡片也一样），失败后用户能再点
        ownDismissing.remove(card.key)
        hub.endDismiss(card.key)
        guard !left, let (action, disable) = Self.dismissAction(result) else {
            publish()
            return
        }
        switch action {
        case PendingDismissAction.hide:
            // 只隐藏这一张（按尝试）；不影响其他平台，也不在本地「退回」显示更早的尝试
            hub.markClosed(card.key)
            items.removeAll { $0.linkId == card.linkId && $0.attemptId == card.attemptId }
            publish()
        case PendingDismissAction.refetch:
            publish()
            refresh()
        case PendingDismissAction.disable:
            hub.gate.start(disable ?? ErrorActionMapper.defaultRetryAfterMillis)
            publish()
        case PendingDismissAction.forceUpdate:
            // 10405：网络层已交 AppUpdate.on10405 进强更（已有分流，APP-07 第 20、21 条）；卡片保持原样
            publish()
        case PendingDismissAction.errorToast:
            let view = OrderErrorAction.view(target: OrderErrorAction.detail, result: result, hasCache: false,
                                             filtered: false)
            toast(OrderErrorAction.networkKey, error: view)
        default:
            toast(OrderErrorAction.networkKey, error: nil)
        }
    }

    /// 关闭的结果 → 动作；本地作废、发送前闸门拦下（没有写出）为 nil（只刷新显示）。
    static func dismissAction(_ result: ApiResult) -> (String, Int64?)? {
        switch result {
        case .success:
            PendingTrackDismiss.action(kind: "ok", code: nil, disableMs: 0)
        case let .failure(code, _, _, _, effect, _):
            PendingTrackDismiss.action(
                kind: "error", code: NonForcedUpdate.pageCode(code: code, effect: effect),
                disableMs: OrderErrorAction.disableMillis(result)
            )
        case let .localReject(reason)
            where reason == LocalRejectReason.callCancelled || reason == LocalRejectReason.sendBlocked:
            nil
        default:
            PendingTrackDismiss.action(kind: "transport", code: nil, disableMs: 0)
        }
    }

    /// 卡内【开启通知】：先核对渲染时的票据（失效即零动作：不记「点过」、不申请）；再按最新的本机记录与系统状态复核（别的位置刚点过、
    /// 或系统里已开启：只重算、不申请，共性第 25 条）；仍应申请时先记「点过」（各位置这一行随即消失），再经统一权限入口弹系统框。
    /// 异步等待的复核沿用同一票据（会话世代、App 侧版本都取票据里的，不在执行时重新捕获，共性第 42 条）。
    public func requestNotification(_ ticket: PendingTrackTicket) {
        let card = ticket.card
        guard ticketValid(ticket),
              state.cards.contains(where: { $0.key == card.key && $0.notificationRow }) else { return }
        guard currentCards().contains(where: { $0.key == card.key && $0.notificationRow }) else {
            publish()
            return
        }
        guard let env else { return }
        hub.markPushRowUsed()
        publish()
        pushTask?.cancel()
        pushTask = Task { @MainActor [weak self, weak env] in
            await env?.requestPush(isValid: { [weak self] in self?.pushStillValid(ticket) ?? false })
            self?.recompute()
        }
    }

    /// 等待结束后的复核（沿用点击时的票据，其中的身份与期号都不重新捕获）：申请任务没被取消、票据仍对得上（含显示位置仍在、
    /// 这张卡仍在同一期、固定身份仍是当前会话）。
    func pushStillValid(_ ticket: PendingTrackTicket) -> Bool {
        !Task.isCancelled && ticketValid(ticket)
    }

    public func consumeToast() {
        state.toast = nil
    }

    private func toast(_ key: String, error: OrderErrorView?) {
        toastSeq += 1
        state.toast = OrderToast(key: key, error: error, id: toastSeq)
        publish()
    }

    /// 会话换代：作废在途请求，清掉旧账号的卡（不把旧账号的卡显示给新账号）。
    private func sessionChanged(_ epoch: Int) {
        generation += 1
        pushTask?.cancel()
        pushTask = nil
        fetchSeq += 1
        fetches.cancelAll()
        closes.cancelAll()
        ownDismissing = []
        items = []
        cardLives = [:]
        deferredFetch = false
        guard !left, let env else { return }
        // 随清空一起为新会话重建固定身份（A 类：换代通知里一次读取）
        owner = env.currentOwner()
        boundEpoch = epoch
        state = PendingTrackState()
        state.blocked = hub.gate.blocked
    }

    /// 清掉显示（发起页离开外跳场景时不留旧卡）。
    public func clear() {
        generation += 1
        pushTask?.cancel()
        pushTask = nil
        fetchSeq += 1
        fetches.cancelAll()
        items = []
        publish()
    }

    /// 撤回同意 / 切换环境（同步出口，共性第 38 条）：作废执行器（同 `leave`），并同步清空已显示的卡片（页面可能还在栈里、仍在显示）。
    public func discard() {
        leave()
        items = []
        cardLives = [:]
        state = PendingTrackState()
    }

    /// 页面出栈（同步出口）：作废并取消在途请求，之后迟到的响应一律丢弃；本位置在途的关闭释放忙碌。
    public func leave() {
        guard !left else { return }
        left = true
        generation += 1
        pushTask?.cancel()
        pushTask = nil
        fetches.cancelAll()
        closes.cancelAll()
        for key in ownDismissing {
            hub.endDismiss(key)
        }
        ownDismissing = []
        subscriptions.removeAll()
    }
}
