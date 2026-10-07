import ClientCore
import Config
import CouliNetwork
import Foundation
import Generated
import Privacy
import Router
import Session

/// App 的埋点（03 §4.7；APP-03b）：持有 Core 的 `TrackerQueue` 与 10 秒定时上报。
///
/// - 隐私：结论是「已同意」且撤回清理已完成才采集与上报；离开「已同意」立即清空队列（PrivacyController 的状态观察）。
///   撤回同意、切换环境的清理注册表里也登记了清队列（`TrackerQueueCleaner`）。
/// - 强更检查没有结果（检查中、未知）时只入队不上报；有了结果立即补一次上报。
/// - user_id 取会话里登录时保存的账号（凭据可读时）；游客为空，事件只带 device_id。
/// - TODO(N-20): openapi 里没有 /v1/events，生产 sink 是空实现（返回 false：事件留在队列里，不冒充已上报）。
@MainActor
final class AppTracker {
    static let fileName = "tracker-queue.json"

    /// 冷启动时环境与隐私都就绪后才创建（`startIfReady`）；之前为 nil（不读、不写队列文件）。
    private(set) var queue: TrackerQueue?
    let cleaner: TrackerQueueCleaner
    private var timer: TrackerUploadTimer?
    private let makeQueue: () -> TrackerQueue
    private let ticker: any RepeatingTicker
    private let privacy: PrivacyController
    private let environmentReady: @MainActor () -> Bool

    init(
        privacy: PrivacyController,
        update: AppUpdate,
        network: AppNetwork,
        cleaner preRegistered: TrackerQueueCleaner? = nil,
        environmentReady: @escaping @MainActor () -> Bool,
        credentialsReadable: @escaping @MainActor () -> Bool = {
            PrivacyWithdrawalCleanup.runner.credentialsReadable
        },
        file: ClientFile = ClientFile(name: AppTracker.fileName),
        withdrawalRegistry: EnvironmentSwitchCleanerRegistry = PrivacyWithdrawalCleanup.registry,
        environmentRegistry: EnvironmentSwitchCleanerRegistry = .shared,
        sink: @escaping ([String], TrackerUploadTicket) -> Bool = AppTracker.productionSink,
        ticker: any RepeatingTicker = MainRunLoopTicker()
    ) {
        let identity = AppNetwork.identity
        let registry = network.registry
        let readable = credentialsReadable
        // 冷启动里清理器已在启动对账之前登记（`AppLaunchCleanup`）；没有时（测试组合）在这里登记。
        let cleaner = preRegistered ?? Self.registerQueueCleaner(
            file: file, withdrawalRegistry: withdrawalRegistry, environmentRegistry: environmentRegistry
        )
        let queueFile = cleaner.file
        let marker = cleaner.marker
        self.privacy = privacy
        self.ticker = ticker
        self.environmentReady = environmentReady
        makeQueue = { [weak privacy, weak update, client = network.client] in
            TrackerQueue(
                readFile: queueFile.read,
                writeFile: queueFile.write,
                sink: { _ in false },
                privacy: privacy.map { Self.privacyRaw($0.state, readable: readable()) }
                    ?? PrivacyDecision.basicMode.rawValue,
                // 经过会话隔离判断的账号：隔离中、读取失败时为空（APP-03b 共性 9）。
                userId: { readable() ? client.isolatedAccount : nil },
                currentDeviceId: { readable() ? registry.deviceId : nil },
                platform: identity.platform,
                appVersion: identity.appVersion,
                channel: identity.channel,
                sessionId: UUID().uuidString.lowercased(),
                clock: { Int64(Date().timeIntervalSince1970 * 1000) },
                canUpload: { update.map { Self.updateKnown($0.routerStatus) } ?? false },
                // 持久化的「待清理」标记：删队列文件失败时置上，确认清空前不加载、不上报旧队列（共性 11）。
                readClearMarker: { FileManager.default.fileExists(atPath: marker.url.path) },
                writeClearMarker: { pending in try marker.write(pending ? "1" : nil) },
                // 交给 sink 前的发送守卫：撤回同意、切换环境共用（共性 16）。
                uploadGuard: { readable() && environmentReady() },
                // 批次带发送票据交给 sink：撤回同意、切换环境时作废并取消已交接的发送（R1-05，F-AND-12）。
                ticketedSink: sink,
                clientTicket: { client.invalidationTicket }
            )
        }
        self.cleaner = cleaner
        privacy.observeState { [weak self] state in
            guard let self else {
                return
            }
            if let queue {
                queue.onPrivacyChanged(state: Self.privacyRaw(state, readable: readable()))
            } else {
                startIfReady()
            }
        }
        update.observeRouterStatus { [weak self] status in
            if Self.updateKnown(status) {
                self?.queue?.flush()
            }
        }
    }

    /// 登记埋点队列的清理器（撤回同意、切换环境两个注册表）。冷启动时必须在撤回清理重试与启动环境对账（创建
    /// EnvironmentStore）之前调用：此时队列还没创建，清理器直接删队列文件与临时文件（APP-03b 共性 23，iOS R1-03）。
    static func registerQueueCleaner(
        file: ClientFile = ClientFile(name: AppTracker.fileName),
        withdrawalRegistry: EnvironmentSwitchCleanerRegistry = PrivacyWithdrawalCleanup.registry,
        environmentRegistry: EnvironmentSwitchCleanerRegistry = .shared
    ) -> TrackerQueueCleaner {
        let cleaner = TrackerQueueCleaner(file: file)
        withdrawalRegistry.replace(cleaner)
        environmentRegistry.replace(cleaner)
        return cleaner
    }

    /// 冷启动流程里显式启动（共性 15）：环境已就绪、隐私已有结论后创建队列（读旧队列）、开始每 10 秒上报，并立即
    /// 提交一次冷启动前留下的队列。只启动一次。
    func startIfReady() {
        guard queue == nil, environmentReady(), privacy.state.decision != .notDecided else {
            return
        }
        let created = makeQueue()
        queue = created
        cleaner.queue = created
        let started = TrackerUploadTimer(queue: created, ticker: ticker)
        timer = started
        started.start()
        created.flush()
    }

    /// 采集一条事件（只接受 `ClientEvents` 的生成函数构造的事件）。
    @discardableResult
    func track(_ event: TrackEvent) -> Bool {
        queue?.track(event: event) ?? false
    }

    /// TODO(N-20): /v1/events 未定义，先不上报。接通时：只登记交接、发送前核对 `ticket.isValid`，经
    /// `ApiClient.send(_:ticket:)` 以 `ticket.clientTicket` 发送，并用 `ticket.onCancel` 登记取消、结束时 `finish()`。
    /// 空实现也明确结束票据（APP-03b 共性 26）：同步拒收，不留在发送中。
    nonisolated static func productionSink(_: [String], _ ticket: TrackerUploadTicket) -> Bool {
        ticket.finish()
        return false
    }

    /// 结论是「已同意」且凭据可读（撤回清理已完成）才算已同意；撤回清理未完成按基本模式。
    static func privacyRaw(_ state: PrivacyGateState, readable: Bool) -> String {
        guard readable else {
            return PrivacyDecision.basicMode.rawValue
        }
        return state.decision == .consented ? TrackerQueue.consented : state.decision.rawValue
    }

    /// 强更检查有了结论（ok、低于推荐、低于最低）才上报；检查中、未知只入队（03 §4.7）。
    static func updateKnown(_ status: UpdateCheckStatus) -> Bool {
        switch status {
        case .finished(.ok), .finished(.belowRecommended), .finished(.belowMin):
            true
        case .finished(.unknown), .finished(.checking), .checking:
            false
        }
    }
}

/// 埋点队列的清理项（撤回同意、切换环境）。队列已创建时清队列（内存 + 文件 + 标记）；还没创建时直接删文件，
/// 删不掉就置持久化的待清理标记（下次创建队列时先清）。
@MainActor
final class TrackerQueueCleaner: EnvironmentSwitchCleaning {
    static let name = "Tracker.queue"

    let cleanerName = TrackerQueueCleaner.name
    /// 环境与隐私就绪、队列创建后才绑定（`AppTracker.startIfReady`）。
    var queue: TrackerQueue?
    let file: ClientFile
    /// 持久化的「待清理」标记（同目录 `<队列文件名>.clearing`）。
    let marker: ClientFile

    init(file: ClientFile) {
        self.file = file
        marker = file.sibling(file.url.lastPathComponent + ".clearing")
    }

    func cleanForEnvironmentSwitch() throws {
        if let queue {
            try queue.clearForCleanup()
            return
        }
        do {
            try file.write(nil)
            try? marker.write(nil)
        } catch {
            try? marker.write("1")
            throw error
        }
    }
}
