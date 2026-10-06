import Foundation
@testable import Network
import Session
import XCTest

/// 记录回调。
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var forceUpdates: [String?] = []
    private var sleeps: [Int64] = []
    private var effects: [ErrorEffect] = []

    func forceUpdate(_ min: String?) {
        lock.withLock { forceUpdates.append(min) }
    }

    func sleep(_ millis: Int64) {
        lock.withLock { sleeps.append(millis) }
    }

    func effect(_ effect: ErrorEffect) {
        lock.withLock { effects.append(effect) }
    }

    var effectCalls: [ErrorEffect] {
        lock.withLock { effects }
    }

    var forceUpdateCalls: [String?] {
        lock.withLock { forceUpdates }
    }

    var sleepCalls: [Int64] {
        lock.withLock { sleeps }
    }
}

struct Harness {
    let client: ApiClient
    let state: TestState
    let tokens: MemorySessionTokens
    let pending: PendingKeyStore
    let backend: MemoryPendingKeyBackend
    let recorder: Recorder
}

/// `sessionStore` 非 nil 时 ApiClient 用它（例如生产 `SecureSessionTokens`），`Harness.tokens` 不再是 ApiClient 的存储。
func makeHarness(
    tokens: MemorySessionTokens = MemorySessionTokens(
        access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A"
    ),
    device: any DeviceCredentials = TestDevice(),
    clock: @escaping @Sendable () -> Int64 = { 1_790_661_600_000 },
    nonce: @escaping @Sendable () -> String = { "b5a8f07b9dda63c3f78ed24c341d25b3" },
    onSleep: (@Sendable () -> Void)? = nil,
    asyncSleep: (@Sendable () async -> Void)? = nil,
    sessionStore: (any SessionTokens)? = nil
) -> Harness {
    let state = TestState()
    let recorder = Recorder()
    let backend = MemoryPendingKeyBackend()
    let pending = PendingKeyStore(backend: backend, clock: { 0 })
    let client = ApiClient(
        identity: ClientIdentity(
            appId: "couli",
            platform: "ios",
            appVersion: "1.2.0",
            build: "120",
            channel: "app_store"
        ),
        context: { state.read() },
        device: device,
        tokens: sessionStore ?? tokens,
        pendingKeys: pending,
        hooks: NetworkHooks(
            onForceUpdate: { recorder.forceUpdate($0) },
            onEffect: { recorder.effect($0) }
        ),
        configuration: StubURLProtocol.configuration(),
        clock: clock,
        sleeper: { millis in
            recorder.sleep(millis)
            onSleep?()
            await asyncSleep?()
        },
        nonce: nonce
    )
    return Harness(
        client: client, state: state, tokens: tokens, pending: pending, backend: backend, recorder: recorder
    )
}

extension ApiResult {
    var effect: ErrorEffect? {
        switch self {
        case let .failure(_, _, _, _, effect, _), let .sessionCleared(effect):
            effect
        default:
            nil
        }
    }

    var rejectReason: String? {
        notSentReason
    }

    var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }

    var key: String? {
        switch self {
        case let .success(_, _, key), let .failure(_, _, _, _, _, key):
            key
        case let .transportFailure(_, _, key, _):
            key
        case let .abandoned(key):
            key
        case .localReject, .sessionCleared, .sessionNotSaved:
            nil
        }
    }
}

/// 跨 @Sendable 闭包共享的可变引用（测试用）。
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// 测试里手动放行的异步闸门。
actor AsyncGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened {
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        opened = true
        let all = waiting
        waiting.removeAll()
        all.forEach { $0.resume() }
    }
}
