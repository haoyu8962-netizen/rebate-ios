import CouliNetwork
import Foundation
import ProductSearch
import Session
import XCTest

/// 本地假服务：URLProtocol 桩，不连任何真实地址（基址 .invalid）。可以把某个请求 hold 住，模拟迟到响应。
final class SearchStubProtocol: URLProtocol {
    enum Reply {
        case json(status: Int, headers: [String: String], body: String)
        /// 不回应，直到测试 `release(id, with:)`；被取消时 `wasStopped(id)` 为 true。
        case hold(String)
    }

    struct Recorded {
        let path: String
        let query: [String: String]
    }

    private final class Held: @unchecked Sendable {
        let stub: SearchStubProtocol
        let runLoop: CFRunLoop

        init(stub: SearchStubProtocol, runLoop: CFRunLoop) {
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

    static var requests: [Recorded] {
        lock.withLock { recorded }
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
        config.protocolClasses = [SearchStubProtocol.self]
        return config
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var query: [String: String] = [:]
        let url = request.url ?? URL(fileURLWithPath: "/")
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let entry = Recorded(path: url.path, query: query)
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

    fileprivate func deliver(_ reply: Reply) {
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

enum SearchFixtures {
    static let trace = "0199a3b4-5c6d-7e8f-9a0b-1c2d3e123456"

    static func envelope(_ code: Int, data: String) -> String {
        "{\"code\":\(code),\"msg\":\"\",\"data\":\(data),\"trace_id\":\"\(trace)\"}"
    }

    static func ok(_ data: String) -> SearchStubProtocol.Reply {
        .json(status: 200, headers: [:], body: envelope(0, data: data))
    }

    static func fail(_ code: Int, data: String = "{}", headers: [String: String] = [:]) -> SearchStubProtocol.Reply {
        .json(status: 400, headers: headers, body: envelope(code, data: data))
    }

    /// 一张搜索卡（JSON 文本）。
    static func card(
        _ key: String, platform: String = "taobao", price: String = "3990", basis: String = "normal",
        keys: String = "[\"price_basis\"]", stale: Bool = false, availability: String = "ok"
    ) -> String {
        "{\"product_key\":\"\(key)\",\"item_ref\":\"ref-\(key)\",\"platform\":\"\(platform)\",\"title\":\"t\","
            + "\"price_fen\":\(price),\"coupon_fen\":1000,\"final_price_fen\":2990,\"est_net_price_fen\":2721,"
            + "\"rebate_min_fen\":269,\"rebate_max_fen\":269,\"rebate_basis\":\"\(basis)\",\"benefit_tags\":[],"
            + "\"is_presale\":false,\"link_id\":\"l1\",\"cta\":{\"text_key\":\"btn.buy.coupon\"},"
            + "\"quoted_at\":\"2026-10-02T09:30:00+08:00\",\"stale\":\(stale),\"age_sec\":12,\"source\":\"s\","
            + "\"disclaimer_keys\":\(keys),\"availability\":\"\(availability)\"}"
    }

    static func page(_ cards: [String], more: Bool) -> String {
        "{\"items\":[\(cards.joined(separator: ","))],\"next_cursor\":\(more ? "\"c2\"" : "null"),"
            + "\"has_more\":\(more),\"fallback_items\":[]}"
    }

    static let disabled = "{\"platform\":\"jd\",\"reason\":\"search_disabled\"}"
}

/// 搜索页的假配置源（ConfigStore 的确认编号语义：issued 单调递增，applied 是被确认的拉取编号）。
@MainActor
final class FakeSearchConfig: SearchConfigSource {
    var current: [String: Any] = ["taobao": "on", "jd": "on", "pdd": "on"]
    var issuedFetchId: UInt64 = 1
    var appliedFetchId: UInt64 = 1
    private(set) var freshRequests = 0
    private var handlers: [UUID: @MainActor () -> Void] = [:]

    func searchStatusLayers() -> [String: Any] {
        ["current": current]
    }

    var confirmedSearchStatus: [String: Any]? {
        current
    }

    func requestFresh() {
        freshRequests += 1
        issuedFetchId += 1
    }

    /// 模拟一次拉取结算：`id` 号拉取被服务端确认（200 或 304），内容换成 `status` 后通知订阅者。
    func confirm(id: UInt64, status: [String: Any]) {
        current = status
        appliedFetchId = max(appliedFetchId, id)
        handlers.values.forEach { $0() }
    }

    func observeSearchConfig(_ handler: @escaping @MainActor () -> Void) -> SearchObservation {
        let id = UUID()
        handlers[id] = handler
        return SearchObservation { [weak self] in
            MainActor.assumeIsolated { self?.handlers[id] = nil }
        }
    }
}

/// 设备凭据占位。
struct SearchStubDevice: DeviceCredentials {
    var deviceId: String? {
        "dev-1"
    }

    var installSecret: String? {
        "placeholder"
    }
}

/// 真实 ApiClient（URLProtocol 假服务）。
func makeSearchClient(privacy: String = PrivacyRaw.full) -> ApiClient {
    ApiClient(
        identity: ClientIdentity(platform: "ios", appVersion: "9.9.9", build: "1", channel: "appstore"),
        context: {
            NetworkContext(
                privacy: privacy, environmentSettled: true, credentialsReadable: true,
                update: UpdateRaw.supported, apiBaseURL: URL(string: "https://api.test.invalid")
            )
        },
        device: SearchStubDevice(),
        tokens: MemorySessionTokens(),
        pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
        configuration: SearchStubProtocol.configuration()
    )
}

/// 可变时钟（限流测试）。
final class SearchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var millis: Int64 = 1_700_000_000_000

    var now: Int64 {
        lock.withLock { millis }
    }

    func advance(_ delta: Int64) {
        lock.withLock { millis += delta }
    }
}

/// 等到条件成立（最多约 5 秒）。
@MainActor
func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<500 {
        if condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("条件未在超时内成立", file: file, line: line)
}

/// 让主线程上的结算跑完（迟到响应被丢弃时没有可等的状态变化）。
@MainActor
func settle() async {
    for _ in 0..<20 {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
