import Foundation
import Generated

/// 埋点事件构造函数：events.yaml 的生成物（`Generated.TrackerEvents`），业务代码只能调用这里的函数（TECH-21）。
public typealias ClientEvents = TrackerEvents

/// 一个上报批次的发送归属票据（APP-03b iOS R1-05，F-AND-12）：交给 sink 时签发，撤回同意、切换环境（队列清理世代
/// 变化）时作废，并调用 sink 登记的取消动作。接上真实 sink（TODO(N-20)）时：sink 只登记、不做同步 IO 地完成交接；
/// 实际发送前核对 `isValid`，并以 `clientTicket` 经 `ApiClient.send(_:ticket:)` 发送（ApiClient 按它做调用归属守卫）。
public final class TrackerUploadTicket: @unchecked Sendable {
    /// 签发时队列的清理世代。
    public let generation: UInt64
    /// 签发时 ApiClient 的作废世代（撤回同意、切换环境时 +1）；没有接 ApiClient 时为 nil。
    public let clientTicket: UInt64?
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var cancelHandlers: [@Sendable () -> Void] = []

    init(generation: UInt64, clientTicket: UInt64?) {
        self.generation = generation
        self.clientTicket = clientTicket
    }

    /// 仍可发送（没被作废）。
    public var isValid: Bool {
        lock.withLock { !cancelled }
    }

    /// sink 登记它安排的发送任务的取消动作；票据已作废时立即调用。
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if cancelled {
                return true
            }
            cancelHandlers.append(handler)
            return false
        }
        if runNow {
            handler()
        }
    }

    /// sink 的发送已结束（成功或失败）：队列不再持有它。
    public func finish() {
        lock.withLock {
            finished = true
            cancelHandlers.removeAll()
        }
    }

    var isOutstanding: Bool {
        lock.withLock { !cancelled && !finished }
    }

    func cancel() {
        let handlers: [@Sendable () -> Void] = lock.withLock {
            cancelled = true
            let all = cancelHandlers
            cancelHandlers.removeAll()
            return all
        }
        handlers.forEach { $0() }
    }
}

/// 埋点队列（03 §4.7）：采集、持久化、批量上报。
///
/// - 只在隐私「已同意」时采集与上报；未同意、基本模式不采集、不上报（BR-ID-11）。隐私离开「已同意」（撤回同意）时
///   立即清空队列（先清内存再写文件；写失败时下次创建队列、以及之后每次隐私变化都再清一次），之后再同意也不会复活。
///   创建队列时隐私不是「已同意」也先清掉文件里的旧事件。
/// - 公共字段：event_id、name、client_at（ISO 8601 带时区）、session_id、device_id、user_id（游客为空，采集时定下，
///   登录后不回写）、platform、app_version、channel、page、spm、trace_id；事件自身字段与公共字段同级。
/// - device_id 采集时还没有（设备尚未注册）的，上报前补上当前的；仍没有就先不上报。
/// - 队列持久化（离线可恢复），上限 500 条：满了拒收新事件（TODO(N-21): 溢出丢旧还是丢新未规定，这里丢新）。
/// - 每满 10 条触发一次上报（另由 `TrackerUploadTimer` 每 10 秒触发）；每批最多 10 条，sink 返回 true 才从队列移除
///   （先写文件再改内存；写文件失败时保留在队列，下次重发，服务端按 event_id 去重）。失败即停，等下一次触发。
/// - 强更检查没有结果（检查中、未知）时只入队不上报（`canUpload` 为 false）。
/// - 上报经可注入的 sink（[事件 JSON]、发送票据 → 是否全部成功）。清理世代变化时作废并取消已交接批次的票据。TODO(N-20): openapi 里没有 /v1/events，生产 sink 是空实现。
///
/// 不是线程安全的：生产代码只在主线程使用（App 的 AppTracker 是 @MainActor）。
public final class TrackerQueue {
    public static let capacity = 500
    public static let batchSize = 10
    public static let consented = "consented"

    private let readFile: () throws -> String?
    private let writeFile: (String?) throws -> Void
    private let sink: ([String], TrackerUploadTicket) -> Bool
    private let clientTicket: () -> UInt64?
    /// 已交给 sink、还没结束的批次票据：清理世代变化时全部作废并取消。
    private var outstanding: [TrackerUploadTicket] = []
    private let userId: () -> String?
    private let currentDeviceId: () -> String?
    private let platform: String
    private let appVersion: String
    private let channel: String?
    private let sessionId: String
    private let clock: () -> Int64
    private let canUpload: () -> Bool
    private let newEventId: () -> String

    private var privacy: String
    private var events: [String] = []
    /// 清队列时删文件失败：之后再试；确认清空前不加载、不采集、不上报旧队列。
    private var clearPending = false
    /// 持久化的「待清理」标记（读：是否在；写：置上 / 去掉）。删文件失败时置上，下次创建队列先清理再说。
    private let readClearMarker: () -> Bool
    private let writeClearMarker: (Bool) throws -> Void
    /// 交给 sink 之前的外部发送守卫（App：隐私已同意、凭据可读、环境就绪；撤回与切换环境共用）。
    private let uploadGuard: () -> Bool
    /// 清理世代：清队列、隐私变化时 +1。取出的批次交给 sink 前再核对，撤回后不提交（APP-03b 共性 16）。
    private var generation: UInt64 = 0

    /// 生产入口：device_id 每次取当前值（设备注册后才有）。
    public init(
        readFile: @escaping () throws -> String?,
        writeFile: @escaping (String?) throws -> Void,
        sink: @escaping ([String]) -> Bool,
        privacy: String,
        userId: @escaping () -> String?,
        currentDeviceId: @escaping () -> String?,
        platform: String,
        appVersion: String,
        channel: String?,
        sessionId: String,
        clock: @escaping () -> Int64,
        canUpload: @escaping () -> Bool,
        newEventId: @escaping () -> String = { UUID().uuidString.lowercased() },
        readClearMarker: @escaping () -> Bool = { false },
        writeClearMarker: @escaping (Bool) throws -> Void = { _ in },
        uploadGuard: @escaping () -> Bool = { true },
        ticketedSink: (([String], TrackerUploadTicket) -> Bool)? = nil,
        clientTicket: @escaping () -> UInt64? = { nil }
    ) {
        self.readFile = readFile
        self.writeFile = writeFile
        // 只收批次的 sink：同步返回即结束，票据随即释放。
        self.sink = ticketedSink ?? { batch, ticket in
            defer { ticket.finish() }
            return sink(batch)
        }
        self.clientTicket = clientTicket
        self.privacy = privacy
        self.userId = userId
        self.currentDeviceId = currentDeviceId
        self.platform = platform
        self.appVersion = appVersion
        self.channel = channel
        self.sessionId = sessionId
        self.clock = clock
        self.canUpload = canUpload
        self.newEventId = newEventId
        self.readClearMarker = readClearMarker
        self.writeClearMarker = writeClearMarker
        self.uploadGuard = uploadGuard
        clearPending = readClearMarker()
        if privacy == Self.consented, !clearPending {
            events = (try? readFile()).flatMap(Self.decode) ?? []
        } else {
            // 未同意，或上次清理没完成（持久化标记在）：先清；清不掉就不加载旧队列。
            clearQueue()
        }
    }

    /// 固定 device_id（向量测试的接线形状）。
    public convenience init(
        readFile: @escaping () throws -> String?,
        writeFile: @escaping (String?) throws -> Void,
        sink: @escaping ([String]) -> Bool,
        privacy: String,
        userId: @escaping () -> String?,
        deviceId: String?,
        platform: String,
        appVersion: String,
        sessionId: String,
        clock: @escaping () -> Int64,
        canUpload: @escaping () -> Bool
    ) {
        self.init(
            readFile: readFile, writeFile: writeFile, sink: sink, privacy: privacy, userId: userId,
            currentDeviceId: { deviceId }, platform: platform, appVersion: appVersion, channel: nil,
            sessionId: sessionId, clock: clock, canUpload: canUpload
        )
    }

    /// 队列里的事件数。
    public var queueSize: Int {
        events.count
    }

    /// 已交给 sink、仍在发送中的批次票据数（诊断与测试）。
    public var outstandingTickets: Int {
        outstanding.count
    }

    /// 采集一条事件；返回是否接受（未同意、基本模式、队列已满、条件必填字段缺失时不接受）。
    @discardableResult
    public func track(event: TrackEvent) -> Bool {
        guard settlePendingClear(), privacy == Self.consented, event.missingRequired.isEmpty,
              events.count < Self.capacity,
              let packet = encode(event)
        else {
            return false
        }
        let next = events + [packet]
        guard persist(next) else {
            return false
        }
        events = next
        if events.count.isMultiple(of: Self.batchSize) {
            flush()
        }
        return true
    }

    /// 上报（每批最多 10 条，失败即停）。未同意、强更检查没有结果时不上报。
    public func flush() {
        guard settlePendingClear() else {
            return
        }
        while privacy == Self.consented, canUpload(), !events.isEmpty {
            let taken = generation
            let count = min(Self.batchSize, events.count)
            guard let batch = withDeviceId(Array(events.prefix(count))) else {
                return
            }
            // 交给 sink 前再核对一次原始世代与发送守卫：取出之后撤回同意或切换环境的批次不提交。
            guard taken == generation, privacy == Self.consented, uploadGuard() else {
                return
            }
            let ticket = TrackerUploadTicket(generation: taken, clientTicket: clientTicket())
            outstanding.append(ticket)
            let accepted = sink(batch, ticket)
            // 票据生命周期（APP-03b 共性 26）：sink 同步拒收的批次立即结束票据；已结束（含同步完成）的票据立即移除，
            // 只保留确实还在发送中的。否则定时重试每次失败都会留下一张票据，持续累积。
            if !accepted {
                ticket.finish()
            }
            outstanding.removeAll { !$0.isOutstanding }
            guard accepted else {
                return
            }
            let remaining = Array(events.dropFirst(count))
            guard persist(remaining) else {
                return
            }
            events = remaining
        }
    }

    /// 隐私状态变化（consented / not_decided / basic_mode）：离开「已同意」立即清空队列。
    public func onPrivacyChanged(state: String) {
        if state != privacy {
            advanceGeneration()
        }
        privacy = state
        if state != Self.consented || clearPending {
            clearQueue()
        }
    }

    /// 撤回同意、切换环境的清理：清空队列与文件。删文件失败抛错（内存已清，持久化的待清理标记置上，之后重试）。
    public func clearForCleanup() throws {
        events = []
        advanceGeneration()
        do {
            try writeFile(nil)
        } catch {
            markClearPending()
            throw error
        }
        clearPending = false
        try? writeClearMarker(false)
    }

    // MARK: - 内部

    /// 清理世代 +1，并作废、取消已交给 sink 的批次（交接之后撤回同意或切换环境的发送不再继续）。
    private func advanceGeneration() {
        generation &+= 1
        let tickets = outstanding
        outstanding.removeAll()
        tickets.forEach { $0.cancel() }
    }

    private func clearQueue() {
        try? clearForCleanup()
    }

    private func markClearPending() {
        clearPending = true
        try? writeClearMarker(true)
    }

    /// 有未完成的清理时先重试；仍清不掉返回 false（不采集、不上报）。
    private func settlePendingClear() -> Bool {
        if clearPending || readClearMarker() {
            clearQueue()
        }
        return !clearPending
    }

    private func persist(_ next: [String]) -> Bool {
        let text = next.isEmpty ? nil : Self.encodeFile(next)
        guard next.isEmpty || text != nil else {
            return false
        }
        return (try? writeFile(text)) != nil
    }

    private func encode(_ event: TrackEvent) -> String? {
        var object: [String: Any] = [:]
        for (key, value) in event.fields {
            switch value {
            case let .string(text): object[key] = text
            case let .integer(number): object[key] = number
            case let .boolean(flag): object[key] = flag
            }
        }
        object["event_id"] = newEventId()
        object["name"] = event.name
        object["client_at"] = Self.timestamp(clock())
        object["session_id"] = sessionId
        if let device = currentDeviceId(), !device.isEmpty {
            object["device_id"] = device
        }
        if let user = userId(), !user.isEmpty {
            object["user_id"] = user
        }
        object["platform"] = platform
        object["app_version"] = appVersion
        if let channel, !channel.isEmpty {
            object["channel"] = channel
        }
        object["page"] = event.page
        if let spm = event.spm {
            object["spm"] = spm
        }
        if let trace = event.traceId {
            object["trace_id"] = trace
        }
        return ConfigDocument.encode(object)
    }

    /// 没有 device_id 的事件补上当前的；当前也没有时返回 nil（先不上报）。
    private func withDeviceId(_ batch: [String]) -> [String]? {
        var result: [String] = []
        for packet in batch {
            guard var object = ConfigDocument.parse(packet)?.object else {
                continue
            }
            if (object["device_id"] as? String)?.isEmpty ?? true {
                guard let device = currentDeviceId(), !device.isEmpty else {
                    return nil
                }
                object["device_id"] = device
                result.append(ConfigDocument.encode(object) ?? packet)
            } else {
                result.append(packet)
            }
        }
        return result
    }
}

extension TrackerQueue {
    static func timestamp(_ millis: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }

    fileprivate static func encodeFile(_ events: [String]) -> String? {
        ConfigDocument.encode(["v": 1, "events": events])
    }

    fileprivate static func decode(_ text: String?) -> [String]? {
        guard let root = ConfigDocument.parse(text), root.object["v"] as? Int == 1,
              let events = root.object["events"] as? [String]
        else {
            return nil
        }
        return Array(events.prefix(capacity))
    }
}
