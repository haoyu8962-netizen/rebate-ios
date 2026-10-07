import CouliNetwork
import Foundation
import Generated
@testable import Login
import Router
import Session
import XCTest

/// 本地假服务：URLProtocol 桩，不连任何真实地址（基址 .invalid）。可以把某个请求 hold 住，模拟迟到响应。
final class LoginStubProtocol: URLProtocol {
    enum Reply {
        case json(status: Int, headers: [String: String], body: String)
        /// 不回应，直到测试 `release(id, with:)`；被取消时 `wasStopped(id)` 为 true。
        case hold(String)
    }

    struct Recorded {
        let path: String
        let headers: [String: String]
        let body: String
    }

    private final class Held: @unchecked Sendable {
        let stub: LoginStubProtocol
        let runLoop: CFRunLoop

        init(stub: LoginStubProtocol, runLoop: CFRunLoop) {
            self.stub = stub
            self.runLoop = runLoop
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((Recorded) -> Reply)?
    private nonisolated(unsafe) static var recorded: [Recorded] = []
    private nonisolated(unsafe) static var held: [String: Held] = [:]
    private nonisolated(unsafe) static var stopped: Set<String> = []
    private var holdId: String?

    static func install(_ handler: @escaping (Recorded) -> Reply) {
        lock.withLock {
            self.handler = handler
            recorded = []
            held = [:]
            stopped = []
        }
    }

    static func requests(path: String) -> [Recorded] {
        lock.withLock { recorded.filter { $0.path == path } }
    }

    static func isHeld(_ id: String) -> Bool {
        lock.withLock { held[id] != nil }
    }

    static func wasStopped(_ id: String) -> Bool {
        lock.withLock { stopped.contains(id) }
    }

    static func release(_ id: String, with reply: Reply) {
        guard let entry = lock.withLock({ held.removeValue(forKey: id) }) else { return }
        CFRunLoopPerformBlock(entry.runLoop, CFRunLoopMode.commonModes.rawValue) {
            entry.stub.deliver(reply)
        }
        CFRunLoopWakeUp(entry.runLoop)
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LoginStubProtocol.self]
        return config
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 {
                    break
                }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let entry = Recorded(
            path: request.url?.path ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            body: String(data: body, encoding: .utf8) ?? ""
        )
        let reply: Reply? = Self.lock.withLock {
            Self.recorded.append(entry)
            return Self.handler?(entry)
        }
        if case let .hold(id) = reply {
            holdId = id
            Self.lock.withLock { Self.held[id] = Held(stub: self, runLoop: CFRunLoopGetCurrent()) }
            return
        }
        deliver(reply ?? .json(status: 500, headers: [:], body: ""))
    }

    private func deliver(_ reply: Reply) {
        let url = request.url ?? URL(fileURLWithPath: "/")
        guard case let .json(status, headers, text) = reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard let id = holdId else { return }
        Self.lock.withLock {
            Self.held[id] = nil
            Self.stopped.insert(id)
        }
    }
}

enum Paths {
    static let sms = "/v1/auth/sms-codes"
    static let login = "/v1/auth/login/sms"
    static let refresh = "/v1/auth/refresh"
    static let logout = "/v1/auth/logout"
}

func envelope(_ code: Int, data: String = "{}") -> String {
    "{\"code\":\(code),\"msg\":\"\",\"data\":\(data),\"trace_id\":\"trace-0000-a1b2c3\"}"
}

func okReply(_ data: String = "{}") -> LoginStubProtocol.Reply {
    .json(status: 200, headers: [:], body: envelope(0, data: data))
}

func failReply(_ code: Int, data: String = "{}", headers: [String: String] = [:]) -> LoginStubProtocol.Reply {
    .json(status: 400, headers: headers, body: envelope(code, data: data))
}

/// 登录响应（令牌用无意义的短占位串，不像密钥）。
func loginData(scope: String, isNew: Bool = false, invite: String? = nil) -> String {
    let bind = invite.map { ",\"invite_bind\":\($0)" } ?? ""
    return "{\"user_id\":\"u1\",\"is_new_user\":\(isNew),\"tokens\":{\"access_token\":\"at-1\","
        + "\"refresh_token\":\"rt-1\",\"session_scope\":\"\(scope)\"}\(bind)}"
}

func refreshData(scope: String) -> String {
    "{\"access_token\":\"at-2\",\"refresh_token\":\"rt-2\",\"session_scope\":\"\(scope)\"}"
}

/// 设备凭据占位（签名接口要求已注册设备）。
struct StubDevice: DeviceCredentials {
    var deviceId: String? {
        "dev-1"
    }

    var installSecret: String? {
        "placeholder"
    }
}

/// 可变状态（测试与假时钟共用）。
final class MutableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) {
        stored = value
    }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// 一套与生产同样组合的登录环境：真实 ApiClient（URLProtocol 假服务）、真实 Router（内存 pending_action）、
/// 生产出口 RouterLoginHost。`stateChanged` 照 AppRouting 的做法：resumePending=true 时协调启动（可能恢复待办），
/// false 时只同步强更页。
@MainActor
final class LoginHarness {
    let tokens: MemorySessionTokens
    let update: MutableBox<RouterLoginHost.Update>
    let clock: MutableBox<Int64>
    let client: ApiClient
    let router: Router
    let pending: PendingActionStore
    let host: RouterLoginHost
    let service: LoginService
    private(set) var stateChanges: [Bool] = []
    private let forceUpdateHooksBox: MutableBox<Int>
    /// 刷新成功通知收到的会话世代（共性 14）。
    let refreshedGenerations: MutableBox<[UInt64]>
    /// 刷新成功通知带的刷新来源（共性 19）。
    let refreshOrigins: MutableBox<[SessionRefreshOrigin]>

    /// `saveGate`：给了就在写令牌处放一个可控同步点（`GatedSessionTokens`，APP-05a 共性 24 的交错测试）。
    init(saveGate: SaveGate? = nil) {
        let tokens = MemorySessionTokens()
        let update = MutableBox<RouterLoginHost.Update>(.supported)
        let clock = MutableBox<Int64>(1_700_000_000_000)
        self.tokens = tokens
        self.update = update
        self.clock = clock
        let networkUpdate: @Sendable () -> String = {
            switch update.value {
            case .supported: UpdateRaw.supported
            case .below: UpdateRaw.below
            case .unknown, .checking: UpdateRaw.unknown
            }
        }
        let routerRef = MutableBox<Router?>(nil)
        let refreshed = MutableBox<[UInt64]>([])
        refreshedGenerations = refreshed
        let origins = MutableBox<[SessionRefreshOrigin]>([])
        refreshOrigins = origins
        let forceHook = MutableBox(0)
        forceUpdateHooksBox = forceHook
        client = ApiClient(
            identity: ClientIdentity(platform: "ios", appVersion: "9.9.9", build: "1", channel: "appstore"),
            context: {
                NetworkContext(
                    privacy: PrivacyRaw.full, environmentSettled: true, credentialsReadable: true,
                    update: networkUpdate(), apiBaseURL: URL(string: "https://api.test.invalid")
                )
            },
            device: StubDevice(),
            tokens: saveGate.map { GatedSessionTokens(inner: tokens, gate: $0) } ?? tokens,
            pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
            hooks: NetworkHooks(onForceUpdate: { _ in
                // 生产：AppUpdate.on10405 → below → AppRouting.syncForceUpdate 把导航栈换成强更页。
                await MainActor.run {
                    forceHook.value += 1
                    update.value = .below
                    routerRef.value?.enterForceUpdate()
                }
            }, sessionRefreshed: { generation, origin in
                refreshed.value.append(generation)
                origins.value.append(origin)
            }),
            configuration: LoginStubProtocol.configuration()
        )
        let client = client
        let pending = PendingActionStore(backend: MemoryPendingBackend())
        self.pending = pending
        router = Router(pendingStore: pending) {
            let scope = client.isolatedSessionScope
            let routerUpdate: UpdateState = switch update.value {
            case .supported: .ok
            case .below: .belowMin
            case .unknown: .unknown
            case .checking: .checking
            }
            return GuardState(
                privacyState: .consented, updateState: routerUpdate,
                sessionState: RouterLoginHost.sessionState(scope: scope),
                environmentSettled: true, appVersion: "9.9.9", isDebugBuild: false
            )
        }
        routerRef.value = router
        let changes = MutableBox<(Bool) -> Void>({ _ in })
        host = RouterLoginHost(
            router: router,
            update: { update.value },
            markBelow: { update.value = .below },
            stateChanged: { resume in changes.value(resume) }
        )
        service = LoginService(client: client, host: host, clock: { clock.value })
        host.watchLoginPage(service)
        changes.value = { [unowned self] resume in
            stateChanges.append(resume)
            if update.value == .below {
                router.enterForceUpdate()
            }
            if resume {
                router.launchConditionsChanged(
                    readiness: LaunchReadiness(environmentSettled: true, privacy: .consented,
                                               update: .finished(router.currentGuardState.update)),
                    shellReady: true, now: clock.value
                )
            }
        }
    }

    var forceUpdateHookCalls: Int {
        forceUpdateHooksBox.value
    }

    /// 游客点「订单」：守卫登记 pending_action（OrderList）并推入 Login。
    func guestOpensOrders() {
        router.open(RouteRequest(route: "OrderList", from: .inApp))
    }

    var routes: [String?] {
        router.path.map(\.route)
    }

    /// 已登录（直接写入会话）。
    func seedSession(scope: String = Session.SessionScope.full) throws {
        try tokens.save(access: "at-0", refresh: "rt-0", scope: scope, account: "u1")
    }

    func advance(seconds: Int64) {
        clock.value += seconds * 1000
    }
}

/// 写令牌处的可控同步点（APP-05a 共性 24）：ApiClient 在会话锁里核对完登录尝试、调用 `save` 时先报到（`entered`），
/// 等测试放行（`proceed`）才真正写入；事件按发生顺序记下。
final class SaveGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] {
        lock.withLock { recorded }
    }

    func record(_ event: String) {
        lock.withLock { recorded.append(event) }
    }

    /// 等到 ApiClient 停在写令牌之前（在后台线程上等，不占主线程）。
    func waitEntered() async {
        let entered = entered
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                entered.wait()
                continuation.resume()
            }
        }
    }
}

/// 带同步点的会话存储：读、删直接转给内层；写入前在 `SaveGate` 报到并等放行。
final class GatedSessionTokens: SessionTokens, @unchecked Sendable {
    private let inner: MemorySessionTokens
    private let gate: SaveGate

    init(inner: MemorySessionTokens, gate: SaveGate) {
        self.inner = inner
        self.gate = gate
    }

    func readSession() throws -> SessionSnapshot? {
        try inner.readSession()
    }

    func save(access: String, refresh: String, scope: String, account: String?) throws {
        gate.entered.signal()
        gate.proceed.wait()
        try inner.save(access: access, refresh: refresh, scope: scope, account: account)
        gate.record("saved")
    }

    func clear() throws {
        try inner.clear()
    }
}

/// 等到条件成立（最多约 5 秒）。
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<500 {
        if condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("条件未在超时内成立", file: file, line: line)
}

func bodyObject(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}
