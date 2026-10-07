import Config
import CouliNetwork
import Foundation
import Privacy

/// 读取本机设备标识（BR-ID-09：iOS 用 identifierForVendor）。只有 `DeviceRegistry` 在确认已同意后、在与清理共用的
/// 同步区里调用（主线程、持有注册表的锁，APP-03b 共性 12）。
public protocol DeviceIdentifierReading: Sendable {
    @MainActor func readIdentifier() -> String?
}

/// 一次注册任务的归属票据：注册表的清理世代 + ApiClient 的作废世代（在开始时一起取下）。撤回同意、切换环境任一
/// 发生后票据失效：不再读标识、不再发送（发送守卫按 ApiClient 世代校验，不会被重新绑定到当前环境）、结果不落盘。
struct RegistrationTicket: Sendable {
    let epoch: UInt64
    let clientEpoch: UInt64?
}

/// 一次注册尝试的结果。
public enum DeviceRegistrationOutcome: String, Sendable, Equatable {
    /// 本次注册成功，凭据已落盘。
    case registered
    /// 本机已有凭据，不需要注册。
    case alreadyRegistered = "already_registered"
    /// 隐私不是已同意、撤回清理未完成或环境未就绪：不读标识、不注册。
    case notAllowed = "not_allowed"
    /// 标识无效或取不到（BR-ID-09）：不求哈希、不发请求，按退避重试重新读取。
    case invalidIdentifier = "invalid_identifier"
    /// 服务端以 20001 拒收该哈希，重读后仍是同一个值：不带原值重试。
    case rejectedHash = "rejected_hash"
    /// 安全存储读不了（可能已注册）：不重新注册。
    case storeUnreadable = "store_unreadable"
    /// 凭据没能写进安全存储：不算注册成功。
    case storeFailed = "store_failed"
    /// 请求失败（网络、服务端错误、本地拒绝）。
    case requestFailed = "request_failed"
    /// 注册期间撤回同意或切换环境：结果丢弃。
    case cancelled

    /// 设备此刻有可用凭据。
    public var hasCredentials: Bool {
        self == .registered || self == .alreadyRegistered
    }
}

/// 设备注册（03 §4.1、§4.2；BR-ID-09、BR-ID-11）。也是 ApiClient 的 `DeviceCredentials`：签名改用真实凭据。
///
/// - 只在隐私已同意、撤回清理已完成、环境就绪时才读设备标识（同意前禁止读取 IDFV，BR-ID-11）；标识按
///   `DeviceIdPolicy` 判定，无效一律不求哈希、不发请求（BR-ID-09），由 PrivacyGate 的退避重试重新读取。
/// - 先持久化再改内存：凭据写进安全存储成功才算注册成功、才在内存里生效；写失败按失败处理。
/// - 存储读失败不等于没有记录：读不出时不重新注册，凭据按没有（签名接口本地 device_not_ready），下次读取再试。
/// - 单飞：初次注册、10402 的重新注册共用一个进行中的注册；10402 时被拒的 device_id 已被换掉就直接重放，
///   同一个被拒的 device_id 只重新注册 1 次（ApiClient 再重放 1 次）。
/// - 20001（data.fields 含 device_hash，Effect reread_device_hash）：重读一次设备标识再注册；被拒的哈希本进程内不再上报
///   （不带原值重试）。TODO(N-21): 被拒哈希是否跨进程记住未规定，现只记在内存。
/// - 撤回同意、切换环境（`DeviceRegistryCleaner`，登记在两个清理注册表）：作废进行中的注册（结果晚到也不落盘），
///   删除安全存储里的凭据；删除失败时内存里继续阻断旧凭据，之后每次读取都重试删除，只在确认删除或被新注册替换后解除。
public final class DeviceRegistry: DeviceCredentials, @unchecked Sendable {
    public static let registerOperation = "registerDevice"

    enum Cache: Equatable {
        /// 还没读过（或上次读取失败）。
        case unknown
        /// 读过：有或没有凭据。
        case known(DeviceIdentity?)
        /// 清除时删除失败：内存里作废，读不到凭据；删除成功或被新注册替换后解除。
        case revoked
    }

    enum Read {
        case none
        case identity(DeviceIdentity)
        case unreadable
    }

    /// 进行中的一次注册：绑定发起时的清理世代，只有同一世代的等待者能并入（APP-03b 共性 24）；等待者在 `lock` 里登记。
    final class Flight: @unchecked Sendable {
        let epoch: UInt64
        var waiters: [CheckedContinuation<DeviceRegistrationOutcome, Never>] = []

        init(epoch: UInt64) {
            self.epoch = epoch
        }
    }

    /// 一个被拒 device_id 的 10402 重新注册窗口：复用结果、入队、结算都在 `lock` 里（APP-03b 共性 22）。
    final class ReRegisterWindow: @unchecked Sendable {
        var waiters: [CheckedContinuation<Bool, Never>] = []
    }

    /// 当前任务正在执行注册请求（注册单飞的任务里为 true）：注册请求自身的 10402 不再递归进入它所在的注册窗口
    /// （否则等待自己结束，永久挂起；APP-03b 共性 21）。
    @TaskLocal static var registering = false

    let store: DeviceIdentityStore
    let reader: any DeviceIdentifierReading
    let platform: String
    let context: @Sendable () async -> NetworkContext
    /// 读标识前最后一次同步的放行检查（App：隐私已同意、凭据可读、环境就绪），在主线程、与清理共用的锁里调用。
    let admitRead: @MainActor @Sendable () -> Bool
    let lock = NSLock()
    var cache = Cache.unknown
    /// 撤回同意、切换环境时 +1：进行中的注册作废。
    var epoch: UInt64 = 0
    var flight: Flight?
    /// 服务端以 20001 拒收过的哈希（本清理世代内逐个排除，退避重试也不再上报；清理时清空）。
    var rejectedHashes: Set<String> = []
    /// 10402 重新注册的完整结果：按被拒的 device_id（本清理世代内）保存，晚到的同一 device_id 的 10402 直接复用，
    /// 失败也复用；后续尝试交给退避流程（`onNeedsRegistration`）。
    var reRegisterResults: [String: Bool] = [:]
    /// 进行中的 10402 重新注册窗口（按被拒的 device_id）：窗口结束时先存结果、再移除、再唤醒等待者。
    var reRegisterWindows: [String: ReRegisterWindow] = [:]
    /// 本清理世代里已交给退避链恢复的被拒 device_id：同一个只通知一次（窗口失败与预算用尽共用，共性 4、25）。
    var recoveryRequested: Set<String> = []
    /// 被服务端以 10402 拒绝的 device_id：收到 10402 时立即隔离——`credentials` 不再交出它（registerDevice 与其他请求
    /// 都不带这个旧设备头），`registerIfNeeded` 也不把它当成已注册；被新注册替换后解除。
    var rejectedDeviceIds: Set<String> = []
    /// 10402 重新注册失败时调用（App 接到 PrivacyGate 重新发起带退避的设备注册）。
    public var onNeedsRegistration: (@Sendable () -> Void)? {
        get { lock.withLock { needsRegistration } }
        set { lock.withLock { needsRegistration = newValue } }
    }

    var needsRegistration: (@Sendable () -> Void)?
    weak var client: ApiClient?
    var requestCount = 0

    public init(
        store: DeviceIdentityStore,
        reader: any DeviceIdentifierReading,
        platform: String,
        context: @escaping @Sendable () async -> NetworkContext,
        admitRead: @escaping @MainActor @Sendable () -> Bool = { true }
    ) {
        self.store = store
        self.reader = reader
        self.platform = platform
        self.context = context
        self.admitRead = admitRead
    }

    /// 接上发请求的 ApiClient（ApiClient 创建时要用本对象作 `DeviceCredentials`，所以创建后再接）。
    public func bind(client: ApiClient) {
        lock.withLock { self.client = client }
    }

    // MARK: - DeviceCredentials

    public var deviceId: String? {
        credentials?.deviceId
    }

    public var installSecret: String? {
        credentials?.installSecret
    }

    /// 一次读出（同一份凭据）。读取失败、作废中、已被 10402 拒绝（隔离中）都按没有。
    public var credentials: (deviceId: String, installSecret: String)? {
        let usable: DeviceIdentity? = lock.withLock { usableLocked() }
        return usable.map { ($0.deviceId, $0.installSecret) }
    }

    /// 调用方持有 `lock`：此刻可用（读得到且未被 10402 隔离）的凭据。
    func usableLocked() -> DeviceIdentity? {
        guard case let .identity(identity) = readLocked(), !rejectedDeviceIds.contains(identity.deviceId) else {
            return nil
        }
        return identity
    }

    /// 发出过的注册请求数（测试与诊断）。
    public var registerRequests: Int {
        lock.withLock { requestCount }
    }

    // MARK: - 注册

    /// 同意后的设备注册步骤（PrivacyGate.onConsented 第一步；失败由闸门按 1s、2s、4s…上限 60s 退避重试）。
    /// 已有凭据直接返回；存储读不了不重新注册。
    public func registerIfNeeded() async -> DeviceRegistrationOutcome {
        // 发起时的清理世代：之后的检查、并入或发起单飞都按它核对（所有注册路径同一套世代核对，共性 24）。
        let startEpoch = lock.withLock { epoch }
        guard await allowed() else {
            return .notAllowed
        }
        // 已有凭据且未被隔离才算已注册；世代已变返回 nil。
        let existing: (read: Read, rejected: Bool)? = lock.withLock {
            guard epoch == startEpoch else {
                return nil
            }
            let read = readLocked()
            if case let .identity(identity) = read {
                return (read, rejectedDeviceIds.contains(identity.deviceId))
            }
            return (read, false)
        }
        guard let existing else {
            return .cancelled
        }
        switch existing.read {
        case .identity where !existing.rejected:
            return .alreadyRegistered
        case .identity, .none:
            return await joinOrStart(epoch: startEpoch)
        case .unreadable:
            return .storeUnreadable
        }
    }

    /// 撤回同意、切换环境：作废进行中的注册，删除凭据。删除失败抛错（清理器据此保留待清理标记），内存里继续阻断。
    public func invalidateAndClear() throws {
        var detached: [CheckedContinuation<DeviceRegistrationOutcome, Never>] = []
        defer {
            // 旧 flight 的等待者一律按「已取消」结算（锁外唤醒）；旧 flight 自己结束时不再有等待者可交付。
            detached.forEach { $0.resume(returning: .cancelled) }
        }
        try lock.withLock {
            epoch &+= 1
            // 摘掉旧 flight：新世代的注册不会并入它，它晚到的成功也交不到新等待者手里（共性 24）。
            if let running = flight {
                detached = running.waiters
                running.waiters.removeAll()
                flight = nil
            }
            rejectedHashes.removeAll()
            reRegisterResults.removeAll()
            // 旧窗口结束时按世代不符结算（结果 false、不存、不通知退避），不再被新世代的 10402 复用。
            reRegisterWindows.removeAll()
            rejectedDeviceIds.removeAll()
            recoveryRequested.removeAll()
            do {
                try store.clear()
                cache = .known(nil)
            } catch {
                cache = .revoked
                throw error
            }
        }
    }

    // MARK: - 内部

    func allowed() async -> Bool {
        let state = await context()
        return state.environmentSettled && state.privacy == PrivacyRaw.full && state.credentialsReadable
    }

    /// 调用方持有 `lock`。
    func readLocked() -> Read {
        switch cache {
        case let .known(identity):
            return identity.map(Read.identity) ?? .none
        case .revoked:
            // 作废中：每次读取都重试删除，删掉才解除；没删掉时绝不交出旧凭据。
            if (try? store.clear()) != nil {
                cache = .known(nil)
            }
            return .none
        case .unknown:
            do {
                let identity = try store.read()
                cache = .known(identity)
                return identity.map(Read.identity) ?? .none
            } catch DeviceIdentityReadError.corrupted {
                // 损坏的条目不能用：尽力删除，删掉才确认没有。
                if (try? store.clear()) != nil {
                    cache = .known(nil)
                }
                return .none
            } catch {
                return .unreadable
            }
        }
    }

    /// 并入或发起单飞注册，只在调用方的清理世代仍是当前世代时：世代已变按「已取消」；只并入同一世代的 flight。
    func joinOrStart(epoch expected: UInt64) async -> DeviceRegistrationOutcome {
        var started: (Flight, RegistrationTicket)?
        var reused = false
        return await withCheckedContinuation { continuation in
            let stale: Bool = lock.withLock {
                guard epoch == expected else {
                    return true
                }
                if let running = flight, running.epoch == expected {
                    running.waiters.append(continuation)
                    return false
                }
                // 新建 flight 前在同一把锁里复核：被拒的凭据已被别的注册（退避注册或窗口）替换为可用凭据时直接复用，
                // 不再注册（APP-03b 共性 4、22、25；iOS R3-01）。
                if usableLocked() != nil {
                    reused = true
                    return false
                }
                let created = Flight(epoch: expected)
                created.waiters.append(continuation)
                flight = created
                started = (created, RegistrationTicket(epoch: expected, clientEpoch: client?.invalidationTicket))
                return false
            }
            if stale {
                continuation.resume(returning: .cancelled)
            } else if reused {
                continuation.resume(returning: .alreadyRegistered)
            } else if let (created, ticket) = started {
                Task { await self.runFlight(created, ticket: ticket) }
            }
        }
    }

    /// 结算前再核对一次原始票据（清理世代、ApiClient 作废世代）与放行状态：凭据保存成功之后、结算之前发生清理时，
    /// 结果按「已取消」交付（被摘掉的旧 flight 此时已没有等待者）。
    func runFlight(_ running: Flight, ticket: RegistrationTicket) async {
        var outcome = await Self.$registering.withValue(true) {
            await performRegistration(ticket: ticket, rereadAllowed: true)
        }
        if outcome != .cancelled, await !allowed() {
            outcome = .cancelled
        }
        let waiters: [CheckedContinuation<DeviceRegistrationOutcome, Never>] = lock.withLock {
            if flight === running {
                flight = nil
            }
            if !ticketCurrentLocked(ticket) {
                outcome = .cancelled
            }
            let all = running.waiters
            running.waiters.removeAll()
            return all
        }
        for waiter in waiters {
            waiter.resume(returning: outcome)
        }
    }

    /// 调用方持有 `lock`：票据的清理世代与 ApiClient 作废世代都仍是当前的。
    func ticketCurrentLocked(_ ticket: RegistrationTicket) -> Bool {
        guard epoch == ticket.epoch else {
            return false
        }
        guard let issued = ticket.clientEpoch, let current = client?.invalidationTicket else {
            return true
        }
        return issued == current
    }

    func isCurrent(_ value: UInt64) -> Bool {
        lock.withLock { epoch == value }
    }
}

/// 设备凭据的清理项（撤回同意、切换环境；与 Privacy 的占位项同名，App 用 `replaceCredentialCleaner` 替换）。
@MainActor
public final class DeviceRegistryCleaner: EnvironmentSwitchCleaning {
    public let cleanerName = CredentialAccount.deviceIdentityCleanerName
    private let registry: DeviceRegistry

    public init(registry: DeviceRegistry) {
        self.registry = registry
    }

    public func cleanForEnvironmentSwitch() throws {
        try registry.invalidateAndClear()
    }
}
