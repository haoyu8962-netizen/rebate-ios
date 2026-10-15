import Combine
import CouliNetwork
import Foundation
import Router
import Session

/// 当前会话的手机号绑定状态（APP-05b 共性第 2、8、12、13 条；BR-ID-01、BR-ID-02）：
/// - 只在内存、按登录世代（ApiClient.sessionGeneration）记：短信登录保存时记已绑；第三方新号记未绑；第三方老用户、冷启动、换代之后都是
///   「未知」，守卫按「已登录未绑手机」处理（未知不当已绑，主动打开与待办恢复同一口径）；
/// - 绑定状态有自己的更新世代 `epoch`：绑定成功时推进；getMe 发起时取 `ticket`，返回时世代没变才应用——绑定前发出的旧查询不能覆盖
///   绑定结果（鸿蒙 R3-01、Android R1-02）；
/// - 不落盘：进程重启后一律未知（iOS 没有持久化登录世代，rule-gaps iOS I05）。只在主线程使用。
@MainActor
public final class PhoneBindingStore: ObservableObject {
    /// 一次 getMe 查询发起时的依据：会话世代与绑定状态的更新世代。
    public struct Ticket: Equatable, Sendable {
        public let generation: UInt64
        public let epoch: UInt64
    }

    private var entry: (generation: UInt64, bound: Bool)?
    /// 绑定状态的更新世代（绑定成功时 +1）。
    public private(set) var epoch: UInt64 = 0
    /// 状态每变一次加一（页面与守卫据此刷新）。
    @Published public private(set) var version = 0

    public init() {}

    /// `generation` 这一代会话的绑定状态；nil = 未知（没查清，或已换代）。
    public func bound(generation: UInt64) -> Bool? {
        guard let entry, entry.generation == generation else { return nil }
        return entry.bound
    }

    /// 本次登录直接给出的结论（短信登录 = 已绑；第三方新号 = 未绑）。
    public func record(_ bound: Bool, generation: UInt64) {
        entry = (generation, bound)
        version &+= 1
    }

    /// 绑定成功（共享结算）：推进更新世代，之前发出的 getMe 一律作废。
    public func recordBindSucceeded(generation: UInt64) {
        epoch &+= 1
        record(true, generation: generation)
    }

    /// getMe 发起时取一次。
    public func ticket(generation: UInt64) -> Ticket {
        Ticket(generation: generation, epoch: epoch)
    }

    /// getMe 查清：更新世代没变才应用（调用方另外核对会话世代仍是发起时那一代）。返回是否应用。
    @discardableResult
    public func apply(_ bound: Bool, ticket: Ticket) -> Bool {
        guard ticket.epoch == epoch else { return false }
        record(bound, generation: ticket.generation)
        return true
    }
}

/// 守卫的会话状态（APP-05b 共性第 13 条）：没有会话 → 游客；deletion_only → 受限；full 时只有确认 phone_bound=true 才是「已绑手机」，
/// 其余（未绑、未知）都是「已登录未绑手机」。
public enum SessionGuardState {
    public static func of(scope: String?, phoneBound: Bool?) -> SessionState {
        guard let scope else { return .guest }
        if scope == Session.SessionScope.deletionOnly {
            return .restricted
        }
        return phoneBound == true ? .phoneBound : .loggedIn
    }
}

/// 一次手机号绑定状态查询的结果。
public enum PhoneBindingQueryOutcome: Equatable, Sendable {
    /// 查清（已应用到 `PhoneBindingStore`）。
    case bound(Bool)
    /// 查询失败（网络、5xxxx、42901、本地限流、坏数据）：状态仍未知。
    case failed
    /// 发起后会话已换代、绑定状态已被更新（结果作废）。
    case stale
}

/// 手机号绑定状态的查询（GET /v1/me 的 phone_bound；共性第 2、8、12、14 条）：
/// - 发起时一次取得请求归属，带它发送（网络层只比较，会话换代零发送）；同一会话在途不重复，后来的调用方等同一次结果；
/// - 与「我的」、钱包实名查询、桥 auth.getUser 共用 getMe 的读取截止时间（APP-12 共性第 32、33 条）：发送前检查，42901 写回同一截止时间；
/// - 返回时核对会话世代与绑定状态的更新世代，都没变才应用。
@MainActor
public final class PhoneBindingSync {
    public typealias Completion = (PhoneBindingQueryOutcome) -> Void

    let client: ApiClient
    public let store: PhoneBindingStore
    /// getMe 的共享读取截止时间（App 接 MeGates.read）；nil = 没接（用自己的一份）。
    public var readGate: RetryAfterGate?
    private let ownGate = RetryAfterGate()
    /// 此刻的请求归属（App：ApiClient.currentOwnership + 撤回清理是否完成）。
    public var ownership: () -> RequestOwnership
    private var inFlight: (generation: UInt64, waiters: [Completion])?
    /// 实际发出的查询次数（测试观察）。
    public private(set) var queries = 0

    public init(client: ApiClient, store: PhoneBindingStore) {
        self.client = client
        self.store = store
        ownership = { [client] in client.currentOwnership(credentialsReadable: true) }
    }

    var gate: RetryAfterGate {
        readGate ?? ownGate
    }

    /// 这一代会话正在查询。
    public func querying(generation: UInt64) -> Bool {
        inFlight?.generation == generation
    }

    /// 查一次当前会话的 phone_bound；`completion` 在主线程回调一次。没有会话或已查清时直接按现状回调。
    public func query(_ completion: @escaping Completion = { _ in }) {
        let owner = ownership()
        guard owner.account != nil, client.isolatedSessionScope == Session.SessionScope.full else {
            completion(.failed)
            return
        }
        if let inFlight, inFlight.generation == owner.generation {
            self.inFlight?.waiters.append(completion)
            return
        }
        guard !gate.active else {
            completion(.failed)
            return
        }
        let ticket = store.ticket(generation: owner.generation)
        inFlight = (owner.generation, [completion])
        queries += 1
        let probe = gate.probe()
        let client = client
        Task { @MainActor [weak self] in
            let result = await client.send(
                ApiCall(operationId: "getMe"), isValid: { true }, sendAllowed: probe.allowed, expected: owner
            )
            self?.arrived(result, owner: owner, ticket: ticket)
        }
    }

    private func arrived(_ result: ApiResult, owner: RequestOwnership, ticket: PhoneBindingStore.Ticket) {
        guard inFlight?.generation == owner.generation else { return }
        let waiters = inFlight?.waiters ?? []
        inFlight = nil
        let outcome = settle(result, owner: owner, ticket: ticket)
        for waiter in waiters {
            waiter(outcome)
        }
    }

    private func settle(_ result: ApiResult, owner: RequestOwnership, ticket: PhoneBindingStore.Ticket)
        -> PhoneBindingQueryOutcome {
        // 限流结算也是结算（APP-12 共性第 34 条）：先核对发起时的会话仍是当前，旧会话的 42901 不限流新会话
        guard client.sessionGeneration == owner.generation else { return .stale }
        // 同账号同世代但作用域已从 full 变成 deletion_only（编排补充，鸿蒙 RC-01）：发起时的归属已失效，迟到结果不记手机号状态
        guard client.isolatedSessionScope == Session.SessionScope.full else { return .stale }
        switch result {
        case let .success(data, _, _):
            let object = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            guard let number = object["phone_bound"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                return .failed
            }
            return store.apply(number.boolValue, ticket: ticket) ? .bound(number.boolValue) : .stale
        case let .failure(code, _, _, _, effect, _):
            if code == 42901 {
                gate.start(effect.disableMillis ?? ErrorActionMapper.defaultRetryAfterMillis)
            }
            return .failed
        default:
            return .failed
        }
    }
}
