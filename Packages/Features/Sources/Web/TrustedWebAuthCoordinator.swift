import BridgeHost
import Foundation
import UIKit
import WebKit

/// 切号时可信容器的通知、隔离、清理与重载（F-X-25，三端口径见 NATIVE/F-X-25/brief.md、invariants.md I1–I7）。
/// 每个 App 组合一份（AppWeb 持有），主线程使用。
///
/// - 判定：`AuthChangeTracker`（Core 纯逻辑）。会话来源由 App 接：登录保存 → `sessionMaybeChanged`（读一次身份快照）；
///   明确清除会话（退出、10404、刷新被拒、切换环境、撤回同意、注销终点）→ `sessionExplicitlyCleared`（不读凭据，I5）；
///   另在每次桥消息、容器登记 / 开始加载、回前台时按会话世代补一次核对（`catchUp`），世代没变不读。
/// - I1：判定为账号变化 / 登出（含明确清除）的同一个同步步骤里：先取下要收 A 的文档 → 持久登记待清理 → 把全部在开的可信容器
///   置为隔离（宿主 dispose：之后桥调用一律 90500、不执行处理器；不补发令牌 / 方法列表 / 其他事件；导航与新加载一律取消）。
///   隔离只在清理全部成功、该容器换成新 WebView 并重新加载之后解除，只对新文档解除（旧宿主、旧 WebView 永不恢复）。
/// - A（I7）：判定时取下「当前主框架可信、已提交、没有在途主框架导航」的文档，隔离后向它们发 `auth.changed`（隔离不影响这一次
///   受控投递），等页面脚本执行完成（或 5 秒超时）后才开始清理。后台、被登录页盖住但仍挂载的容器一起即时投递。
/// - B（I2）：第一遍清理（纵深防护）→ 换新的空 store → 旧文档退役并等卸载 → 最后一遍清理 + 读回（五类各自确认、限时；任一失败
///   整体失败：保持隔离、错误页可重试、标记保留）→ 删标记 → 各容器在新 store 上加载当前入口。
/// - I3 / I4：标记写不进磁盘按失败；冷启动先补清；清理中 / 失败期间新容器直接隔离，成功后一并恢复，任一容器「重试」恢复全部。
@MainActor
public final class TrustedWebAuthCoordinator {
    private enum Phase {
        case idle
        case failed
    }

    private struct NotifyJob {
        let loggedIn: Bool
        let targets: [(controller: TrustedWebController, document: Int)]
    }

    public let dependencies: TrustedWebAuthDependencies
    private let identity: @MainActor () -> WebSessionIdentity
    private let stamp: @MainActor () -> UInt64
    private let pendingStore: TrustedWebPendingStore
    /// 可信 store 里数据的归属（评审 r1 S1-01）：最近一次确认可信 store 已清空、或首次确认身份时的已确认身份。
    let ownerStore: TrustedWebPendingStore
    /// 本协调器退役过、还要等卸载确认的旧 WebView（S0-01；teardown 时也立即退役，r2 S1-R2-01），强持有到卸载确认。
    var retirements: [TrustedWebRetirement] = []
    /// 当前的可信 store（评审 r2 S0-R2-01：每次切号清理事务换新）。新 WebView 一律建在它上面。
    public internal(set) var currentStore: WKWebsiteDataStore
    /// 有旧身份数据、需要清的 store（登记待清时把当前 store 记入；事务成功后清空）。换下的 store 留在这里直到清完。
    var dirtyStores: [WKWebsiteDataStore] = []
    let storeRegistry: TrustedWebStoreRegistry
    /// 本协调器负责冷启动核对（归属比对、残留 store 清理）。生产一个进程只有第一个协调器做（冷启动语义；之后的归属变化都经
    /// 正常事务）；测试依赖的每个协调器都做（测试用同进程重建模拟冷启动）。首次确认身份并比对之后置 false。
    private var coldStartReconcile: Bool
    /// 最近一次读到未知身份时的会话世代（r2 S2-R2-05：同一世代读到未知后，只在回前台或世代变化时重读）。
    private var unknownStamp: UInt64?
    private var tracker = AuthChangeTracker()
    private var lastStamp: UInt64?
    private let controllers = NSHashTable<TrustedWebController>.weakObjects()

    /// 待清理（内存镜像；`persisted` 表示已落盘）。owner 是数据归属的旧身份（未知为 nil）。
    private(set) var pending: (owner: WebSessionIdentity?, persisted: Bool)?
    private var phase = Phase.idle
    private var jobs: [NotifyJob] = []
    private var needsCleanup = false
    private var working = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var foregroundObserver: NSObjectProtocol?

    static let notifyTimeoutNanos: UInt64 = 5_000_000_000

    /// - identity：此刻的会话身份（凭据可读性与会话同一次读出；暂时读不出为 unknown）。
    /// - stamp：会话世代（登录、清会话、作废时变化，刷新不变；只读内存，不读凭据）。
    public init(
        dependencies: TrustedWebAuthDependencies,
        identity: @escaping @MainActor () -> WebSessionIdentity,
        stamp: @escaping @MainActor () -> UInt64
    ) {
        self.dependencies = dependencies
        self.identity = identity
        self.stamp = stamp
        pendingStore = TrustedWebPendingStore(file: dependencies.pendingFile)
        ownerStore = TrustedWebPendingStore(file: Self.ownerFile(dependencies.pendingFile))
        storeRegistry = TrustedWebStoreRegistry(file: TrustedWebStoreRegistry.file(nextTo: dependencies.pendingFile))
        currentStore = dependencies.dataStore
        coldStartReconcile = !dependencies.isProduction || TrustedWebDataStore.claimColdStart()
        // 冷启动首次确认身份只记基线，不发事件（D06 / D07）。
        let initial = identity()
        if initial.known {
            lastStamp = stamp()
        }
        _ = tracker.observe(initial)
        let earlyUnpersisted = TrustedWebDataStore.takeUnpersistedEarlyClear()
        if case let .pending(owner) = pendingStore.load() {
            // 上次进程留下的待清理（清理失败、清理中被杀）：在任何可信页面加载前先补清；这是存储事务，不是身份事件（I3）。
            pending = (owner, true)
            dirtyStores = [currentStore]
            needsCleanup = true
            kick()
        } else if earlyUnpersisted {
            // 启动对账阶段的明确清除没能写盘（S2-02）：内存接手，事务开始前再试落盘。
            pending = (nil, false)
            dirtyStores = [currentStore]
            needsCleanup = true
            kick()
        }
        if !initial.known {
            unknownStamp = stamp()
        }
        if coldStartReconcile {
            if initial.known {
                coldStartReconcile = false
                reconcileOwner(initial)
            } else {
                // 冷启动读不出身份（r2 S2-R2-04）：有归属记录就按归属不明处理，先补清再放行页面。
                reconcileUnknownOwner()
            }
            startStoreCleanup(sweepAll: true)
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.unknownStamp = nil
                self?.catchUp()
            }
        }
    }

    // MARK: - 只读投影

    /// 待清理记录的数据归属（诊断与测试）；没有待清理、或归属未知时为 nil。
    public var pendingOwner: WebSessionIdentity? {
        pending?.owner
    }

    public var hasPendingClear: Bool {
        pending != nil
    }

    /// 只等待、不触发任何工作：调用之前已发生的会话变化的通知、清理、恢复页面的提交都结算后返回。
    /// 没有需要做的、或全部成功为 true；清理失败 / 仍有待清理为 false。
    public func whenSettled() async -> Bool {
        if isIdle {
            return pending == nil
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    // MARK: - 会话来源

    /// 会话可能变了（登录保存、回前台、世代变化）：读一次身份快照判定。未知快照不覆盖最近确认的身份（D08）。
    public func sessionMaybeChanged() {
        let current = stamp()
        let previous = tracker.confirmed
        let next = identity()
        // 读到未知不推进世代（S2-01）：之后的核对还会再读，不会把这一代的变化漏掉；同一世代只在回前台时重读（S2-R2-05）。
        if next.known {
            lastStamp = current
            unknownStamp = nil
        } else {
            unknownStamp = current
        }
        let decision = tracker.observe(next)
        apply(decision, owner: previous)
        if coldStartReconcile, previous == nil, next.known {
            coldStartReconcile = false
            reconcileOwner(next)
        }
    }

    /// 明确清除了会话（I5）：不读凭据，按「变成游客」判定并直接登记待清理。
    public func sessionExplicitlyCleared() {
        lastStamp = stamp()
        let previous = tracker.confirmed
        let decision = tracker.explicitlyCleared()
        apply(decision, owner: previous)
    }

    /// 补一次核对：会话世代变了、或还没确认过身份时才读（每次桥消息、容器登记 / 开始加载、回前台）。
    public func catchUp() {
        let now = stamp()
        guard now != lastStamp || tracker.confirmed == nil else { return }
        guard now != unknownStamp else { return }
        sessionMaybeChanged()
    }

    // MARK: - 容器

    func register(_ controller: TrustedWebController) {
        controllers.add(controller)
        catchUp()
        guard pending != nil else { return }
        controller.authIsolate()
        if phase == .failed {
            controller.authFailed()
        }
    }

    /// 容器的「重试」（错误页按钮）：失败后重新跑一次清理事务；成功时恢复全部受影响的容器（I4）。进行中不重复触发。
    func retry() {
        guard pending != nil, !working else { return }
        phase = .idle
        needsCleanup = true
        for controller in live where controller.isAuthIsolated {
            controller.authRetrying()
        }
        kick()
    }

    /// 容器的恢复导航已提交 / 结束、或容器已销毁：看看有没有等结算的。
    func commitSettled() {
        resolveWaitersIfIdle()
    }

    // MARK: - 判定 → 动作

    func apply(_ decision: AuthChangeDecision, owner previous: WebSessionIdentity?) {
        // 先取下要收 A 的文档（隔离会停掉在途导航，必须在它之前判断「是否有在途主框架导航」）。
        let targets = decision.notifies
            ? live.compactMap { controller in controller.authEventDocument().map { (controller, $0) } }
            : []
        if decision.reloads {
            registerPending(owner: previous)
            for controller in live {
                controller.authIsolate()
            }
            needsCleanup = true
            phase = .idle
        }
        if let loggedIn = decision.loggedIn {
            jobs.append(NotifyJob(loggedIn: loggedIn, targets: targets))
        }
        if decision.notifies || decision.reloads {
            kick()
        }
    }

    /// 持久登记待清理（I3）：已有待清理时保留最早的归属，只补落盘。写不进去时内存里照样登记（保持隔离），事务开始前再试。
    private func registerPending(owner: WebSessionIdentity?) {
        if !dirtyStores.contains(where: { $0 === currentStore }) {
            dirtyStores.append(currentStore)
        }
        let current = pending ?? (owner, false)
        pending = current
        guard !current.persisted else { return }
        pending = (current.owner, persistPending(current.owner))
    }

    private func persistPending(_ owner: WebSessionIdentity?) -> Bool {
        do {
            try pendingStore.save(owner: owner)
            return true
        } catch {
            return false
        }
    }

    private var live: [TrustedWebController] {
        controllers.allObjects.filter { !$0.isTornDown }
    }

    private var isIdle: Bool {
        !working && jobs.isEmpty && !needsCleanup && !live.contains { $0.awaitingAuthCommit }
    }

    private func kick() {
        guard !working else { return }
        working = true
        Task { @MainActor [weak self] in
            await self?.work()
        }
    }

    private func work() async {
        while true {
            if !jobs.isEmpty {
                let job = jobs.removeFirst()
                await deliver(job)
                continue
            }
            if needsCleanup {
                needsCleanup = false
                await runTransaction()
                continue
            }
            break
        }
        working = false
        resolveWaitersIfIdle()
    }

    private func resolveWaitersIfIdle() {
        guard isIdle, !waiters.isEmpty else { return }
        let result = pending == nil
        let resumed = waiters
        waiters = []
        for waiter in resumed {
            waiter.resume(returning: result)
        }
    }
}

extension TrustedWebAuthCoordinator {
    // MARK: - A：auth.changed

    /// 并行投递，等全部页面脚本执行完成（或超时）再继续；页面挂住不阻塞清理超过 5 秒。
    private func deliver(_ job: NotifyJob) async {
        guard !job.targets.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = OnceGate<Void>(continuation)
            let timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.notifyTimeoutNanos)
                guard !Task.isCancelled else { return }
                gate.resume(())
            }
            let remaining = Countdown(job.targets.count) {
                if gate.resume(()) {
                    timer.cancel()
                }
            }
            for target in job.targets {
                target.controller.deliverAuthChanged(loggedIn: job.loggedIn, document: target.document) {
                    remaining.tick()
                }
            }
        }
    }

    // MARK: - B：清理事务

    private func runTransaction() async {
        guard let current = pending else { return }
        if !current.persisted {
            guard persistPending(current.owner) else {
                fail()
                return
            }
            pending = (current.owner, true)
        }
        // 第一遍（纵深防护，结果不作数，r2 S2-R2-01）：旧文档还在，它可能随时写回；权威确认是旧文档卸载之后的最后一遍。
        _ = await clearAll(stores: dirtyStores, documents: live.map(\.webView))
        // 换 store（r2 S0-R2-01）：新文档只用新的空 store，旧文档 / keepalive / sendBeacon / 迟到 IPC 的写入只落进旧 store。
        guard rotateStoreIfDirty() else {
            fail()
            return
        }
        // 旧文档退役（新 WebView 建在新 store 上），等卸载（超时按失败），再在旧 store 上做最后一遍清理与读回（S0-01，纵深防护）。
        for controller in live where controller.isAuthIsolated {
            controller.authRetireDocument()
        }
        guard await waitRetired(), await clearAll(stores: dirtyStores, documents: []) else {
            fail()
            return
        }
        // 清理期间又有新的账号变化（已重新登记、需要再清一遍）：不恢复，交给下一轮。
        guard !needsCleanup else { return }
        do {
            try pendingStore.remove()
        } catch {
            // I2 字面上的例外（S2-08）：标记删不掉不影响已确认清空的数据，方向是多清——下次冷启动会把新身份的数据也补清一次（幂等）。
        }
        pending = nil
        dirtyStores = []
        phase = .idle
        recordOwner(tracker.confirmed)
        startStoreCleanup(sweepAll: false)
        for controller in live where controller.isAuthIsolated {
            controller.authRestore()
        }
    }

    private func fail() {
        phase = .failed
        for controller in live where controller.isAuthIsolated {
            controller.authFailed()
        }
    }

    private func clearAll(stores: [WKWebsiteDataStore], documents: [WKWebView]) async -> Bool {
        for store in stores {
            for kind in TrustedWebDataKind.allCases {
                guard await clear(kind, in: store, documents: documents) else {
                    return false
                }
            }
        }
        return true
    }
}
