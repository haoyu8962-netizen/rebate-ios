import CouliNetwork
import Foundation
import Session
@testable import Trade
import TradeJump
import XCTest

/// 本地假服务（URLProtocol，不连任何真实地址）+ 真实 ApiClient 的集成测试（任务书 §2 第 9 项）：
/// 超时同键重试拿到同一 attempt_id；取消后的迟到响应只更新卡片；授权后新键；改价确认；fallback 顺序与每步 link_jump 同一 attempt_id；
/// auth_jump 不上报 link_jump；授权管理 30153。
final class TradeStubProtocol: URLProtocol {
    struct Recorded: @unchecked Sendable {
        let path: String
        let method: String
        let headers: [String: String]
        let body: [String: Any]
    }

    struct Reply: Sendable {
        var code = 0
        var data = "{}"
        var headers: [String: String] = [:]
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: (@Sendable (Recorded) -> Reply)?
    private nonisolated(unsafe) static var recorded: [Recorded] = []
    private let stoppedLock = NSLock()
    private nonisolated(unsafe) var stopped = false

    static func install(_ handler: @escaping @Sendable (Recorded) -> Reply) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    static var requests: [Recorded] {
        lock.withLock { recorded }
    }

    static func requests(_ suffix: String) -> [Recorded] {
        requests.filter { $0.path.hasSuffix(suffix) }
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TradeStubProtocol.self]
        return config
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let entry = Recorded(
            path: url.path, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:], body: body
        )
        let reply: Reply = Self.lock.withLock {
            Self.recorded.append(entry)
            return Self.handler?(entry) ?? Reply(code: 50001)
        }
        let trace = TradeFixtures.trace
        let text = "{\"code\":\(reply.code),\"msg\":\"\",\"data\":\(reply.data),\"trace_id\":\"\(trace)\"}"
        let response = HTTPURLResponse(
            url: url, statusCode: reply.code == 0 ? 200 : 400, httpVersion: "HTTP/1.1", headerFields: reply.headers
        )
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            guard !stoppedLock.withLock({ stopped }) else { return }
            client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stoppedLock.withLock { stopped = true }
    }
}

private struct StubDevice: DeviceCredentials {
    var deviceId: String? {
        "dev-1"
    }

    var installSecret: String? {
        "placeholder"
    }
}

@MainActor
final class TradeIntegrationTests: XCTestCase {
    private var controller: OpenPurchaseController!
    // MainActor 的替身不能在 XCTestCase 的（非隔离）初始化里创建：在 makeController 里建。
    private var sink: FakeSink!
    private var ports: FakePorts!
    private var env: FakeEnv!
    private var webCode: FakeWebCode!

    private func makeClient() -> ApiClient {
        ApiClient(
            identity: ClientIdentity(platform: "ios", appVersion: "9.9.9", build: "1", channel: "appstore"),
            context: {
                NetworkContext(
                    privacy: PrivacyRaw.full, environmentSettled: true, credentialsReadable: true,
                    update: UpdateRaw.supported, apiBaseURL: URL(string: "https://api.test.invalid")
                )
            },
            device: StubDevice(),
            tokens: MemorySessionTokens(access: "at", refresh: "rt", scope: "full", account: "u1"),
            pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
            configuration: TradeStubProtocol.configuration()
        )
    }

    private func makeController(timeoutMillis: Int64 = 8000, browserMillis: Int64 = 50) -> OpenPurchaseController {
        let client = makeClient()
        sink = FakeSink()
        ports = FakePorts()
        env = FakeEnv(card: TradeFixtures.card())
        webCode = FakeWebCode()
        let executor = TradeJumpExecutor(ports: ports, baichuan: UnavailableBaichuan(), sink: sink)
        return OpenPurchaseController(
            api: client, executor: executor, ports: ports, env: env, pending: MemoryPurchasePending(),
            counter: AuthSheetCounter(), tips: JumpTipService(api: client) { "u1" }, webCode: webCode,
            baichuan: UnavailableBaichuan(), timeoutMillis: timeoutMillis, browserNoticeMillis: browserMillis
        )
    }

    /// 服务端：按 Idempotency-Key 记 attempt_id（同键重放返回同一个）。
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts: [String: String] = [:]
        private var seen: Set<String> = []

        func attempt(for key: String) -> (id: String, first: Bool) {
            lock.withLock {
                let first = seen.insert(key).inserted
                if let id = attempts[key] {
                    return (id, first)
                }
                let id = "attempt-\(attempts.count + 1)"
                attempts[key] = id
                return (id, first)
            }
        }
    }

    private nonisolated static func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }

    private nonisolated static func tipsRead() -> String {
        json(["jump_tip": ["taobao": "2026-10-01T00:00:00+08:00", "pdd": "x"]])
    }

    private nonisolated static func openData(_ attempt: String, steps: [[String: Any]],
                                             extra: [String: Any] = [:]) -> String {
        var data = TradeFixtures.open(attempt: attempt, steps: steps)
        data.merge(extra) { $1 }
        return json(data)
    }

    func testTimeoutRetryUsesSameKeyAndGetsSameAttemptId() async {
        let server = Server()
        TradeStubProtocol.install { request in
            if request.path.hasSuffix("/me/tips") {
                return .init(data: Self.tipsRead())
            }
            guard request.path.hasSuffix("/open") else { return .init() }
            let (id, first) = server.attempt(for: request.headers["Idempotency-Key"] ?? "")
            return .init(data: Self.openData(id, steps: [["type": "scheme", "value": "app://x"]]), delay: first ? 3 : 0)
        }
        controller = makeController(timeoutMillis: 300)
        ports.launchResults = [true]
        controller.buy(env.card, spm: "ProductDetail.bottom.buy")
        await eventually { self.controller.state.phase == .timeout }
        controller.retryAfterTimeout()
        await eventually { self.sink.events.count == 1 }
        let opens = TradeStubProtocol.requests("/open")
        XCTAssertEqual(opens.count, 2)
        XCTAssertEqual(opens[0].headers["Idempotency-Key"], opens[1].headers["Idempotency-Key"], "超时重试同键")
        XCTAssertEqual(opens[0].path, opens[1].path)
        XCTAssertEqual(TJSON.string(sink.events[0]["attempt_id"]), "attempt-1", "同键重放拿到同一个 attempt_id")
        XCTAssertEqual(opens[0].body["spm"] as? String, "ProductDetail.bottom.buy")
    }

    func testCancelThenLateResponseUpdatesCardWithoutJump() async {
        TradeStubProtocol.install { request in
            guard request.path.hasSuffix("/open") else { return .init(data: Self.tipsRead()) }
            return .init(
                data: Self.openData("a", steps: [["type": "scheme", "value": "app://x"]], extra: ["new_link_id": "L2"]),
                delay: 0.4
            )
        }
        controller = makeController()
        ports.launchResults = [true]
        controller.buy(env.card, spm: nil)
        await eventually { TradeStubProtocol.requests("/open").count == 1 }
        controller.cancelLoading()
        await eventually { TJSON.string(self.env.card["link_id"]) == "L2" }
        await settle()
        XCTAssertTrue(ports.launched.isEmpty)
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testAuthorizationThenNewKeyAndPriceChangeConfirm() async {
        let bound = Locked(false)
        TradeStubProtocol.install { request in
            if request.path.hasSuffix("/me/tips") {
                return .init(data: Self.tipsRead())
            }
            if request.path.hasSuffix("/taobao/bindings") {
                bound.set(true)
                return .init(data: Self.json(["platform": "taobao", "status": "active"]))
            }
            guard request.path.hasSuffix("/open") else { return .init() }
            if !bound.get() {
                return .init(code: 30101, data: Self.json([
                    "auth_url": "https://o.test/a", "state": "st1", "auth_methods": ["web_code"],
                ]))
            }
            return .init(data: Self.openData(
                "a2", steps: [["type": "scheme", "value": "app://x"]],
                extra: ["price_changed": true, "new_final_price_fen": 4990, "new_link_id": "L2"]
            ))
        }
        controller = makeController()
        controller.buy(env.card, spm: nil)
        await eventually { self.controller.state.dialog == .authSheet(platform: "taobao", busy: false) }
        controller.authorize()
        await eventually { self.controller.state.dialog != nil && self.controller.state.dialog?.isSheet == false }
        let opens = TradeStubProtocol.requests("/open")
        XCTAssertEqual(opens.count, 2)
        XCTAssertNotEqual(opens[0].headers["Idempotency-Key"], opens[1].headers["Idempotency-Key"], "授权后新键")
        let bind = TradeStubProtocol.requests("/taobao/bindings")[0]
        XCTAssertEqual(bind.body["auth_method"] as? String, "web_code")
        XCTAssertEqual(
            controller.state.dialog, .confirmPrice(oldFen: 4678, newFen: 4990, rebateGone: false, coupon: false)
        )
        XCTAssertEqual(TJSON.string(env.card["link_id"]), "L2")
    }

    func testFallbackOrderReportsEveryStepWithSameAttemptAndAuthJumpDoesNot() async {
        TradeStubProtocol.install { request in
            if request.path.hasSuffix("/me/tips") {
                return .init(data: Self.tipsRead())
            }
            return .init(data: Self.openData("a9", steps: [
                ["type": "sdk", "value": "https://s.test"], ["type": "scheme", "value": "app://x"],
                ["type": "universal_link", "value": "https://u.test"], ["type": "copy_tpwd", "value": "TPWD"],
            ]))
        }
        controller = makeController()
        ports.launchResults = [false, false]
        controller.buy(env.card, spm: nil)
        await eventually { self.sink.events.count == 4 }
        XCTAssertEqual(sink.events.map { TJSON.string($0["step"]) }, ["sdk", "scheme", "universal_link", "copy_tpwd"])
        XCTAssertEqual(
            sink.events.map { TJSON.string($0["result"]) }, ["sdk_init_failed", "failed", "failed", "copied"]
        )
        XCTAssertEqual(Set(sink.events.compactMap { TJSON.string($0["attempt_id"]) }), ["a9"])
        XCTAssertEqual(ports.copied, ["TPWD"])

        // 30111 的授权跳转用同一执行器，但不上报 link_jump
        TradeStubProtocol.install { request in
            guard request.path.hasSuffix("/open") else { return .init(data: Self.tipsRead()) }
            return .init(code: 30111, data: Self.json(["auth_jump": [
                "primary": ["type": "universal_link", "value": "https://auth.test"], "fallbacks": [],
                "expire_at": TradeFixtures.future(),
            ]]))
        }
        controller = makeController()
        env.card = TradeFixtures.card(key: "pdd:x", platform: "pdd")
        ports.launchResults = [true]
        controller.buy(env.card, spm: nil)
        await eventually { self.controller.state.dialog != nil }
        controller.authorize()
        await eventually { self.ports.launched.count == 1 }
        await settle()
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testAuthManage30153ShowsBlockedRow() async {
        TradeStubProtocol.install { request in
            if request.path.hasSuffix("/unions/bindings") {
                return .init(data: Self.json(["items": [["platform": "taobao", "status": "unbound"]]]))
            }
            if request.path.hasSuffix("/auth-url") {
                return .init(code: 30153)
            }
            return .init()
        }
        let client = makeClient()
        let ports = FakePorts()
        let manage = AuthManageController(
            api: client, executor: TradeJumpExecutor(ports: ports, baichuan: UnavailableBaichuan(), sink: FakeSink()),
            ports: ports, webCode: FakeWebCode(), baichuan: UnavailableBaichuan()
        )
        manage.load()
        await eventually { manage.state.phase == .content }
        manage.authorize("taobao")
        await eventually { manage.state.rows.first?.blocked == true }
        XCTAssertFalse(manage.state.rows.first?.canAuthorize ?? true)
        XCTAssertTrue(TradeStubProtocol.requests("/open").isEmpty)
    }
}

/// 线程安全的小盒子。
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.withLock { value }
    }

    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }
}
