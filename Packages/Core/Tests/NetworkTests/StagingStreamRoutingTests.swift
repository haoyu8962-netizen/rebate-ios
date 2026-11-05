import Foundation
import Generated
@testable import Network
import SecureStore
import Session
import XCTest

/// FU-X-STAGING-HOSTS-ios D10-598 ①：stream 分流（S 组，照安卓 S01–S09、鸿蒙 S 组）。
/// `NetworkContext.streamBaseURL` 非空时，只有 pathTemplate 以 `/v1/agent/` 开头的操作发往 stream 入口；其余（含刷新令牌）一律走 api。
/// 本文件自带记录主机名的 URLProtocol（共用的 StubURLProtocol 不记主机），基址都是测试值。
final class StagingStreamRoutingTests: XCTestCase {
    static let api = URL(string: "https://api.stream-test.couli.invalid")!
    static let stream = URL(string: "https://stream.stream-test.couli.invalid")!

    private func client(_ context: StreamTestContext, tokens: MemorySessionTokens = MemorySessionTokens(
        access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A"
    )) -> ApiClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamHostProbe.self]
        return ApiClient(
            identity: ClientIdentity(
                appId: "couli", platform: "ios", appVersion: "1.2.0", build: "120", channel: "app_store"
            ),
            context: { context.current },
            device: TestDevice(),
            tokens: tokens,
            pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
            configuration: configuration,
            clock: { 1_790_661_600_000 },
            sleeper: { _ in },
            nonce: { "b5a8f07b9dda63c3f78ed24c341d25b3" }
        )
    }

    static let agentOperations: Set<String> = [
        "createAgentSession", "getCurrentAgentSession", "listAgentSessionMessages", "sendAgentMessage",
        "cancelAgentRun", "setAgentMessageFeedback", "reportAgentMessage",
    ]

    /// 路径参数统一填测试值。
    private func call(_ operation: ApiOperation) -> ApiCall {
        var params: [String: String] = [:]
        let names = operation.pathTemplate.split(separator: "{").dropFirst()
            .compactMap { $0.split(separator: "}").first }
        for name in names {
            params[String(name)] = "p1"
        }
        return ApiCall(
            operationId: operation.operationId, pathParams: params,
            body: operation.method == "GET" ? nil : "{}"
        )
    }

    /// S01 契约里 `/v1/agent/` 开头的操作正好是那 7 个（多一个少一个都红）。
    func testAgentPrefixedOperationsAreExactlySeven() {
        let agent = Set(ApiOperations.all.values.filter { $0.pathTemplate.hasPrefix("/v1/agent/") }.map(\.operationId))
        XCTAssertEqual(agent, Self.agentOperations)
    }

    /// S02 stream 非空：每个 agent 操作写出的 URL 都在 stream 主机、路径以 /v1/agent/ 开头。
    func testAgentOperationsGoToStreamWhenSet() async throws {
        StreamHostProbe.install { _ in (200, envelope(0, data: "{}")) }
        let client = client(StreamTestContext(api: Self.api, stream: Self.stream))
        for id in Self.agentOperations.sorted() {
            _ = await client.send(call(try XCTUnwrap(ApiOperations.byId(id))))
        }
        let seen = StreamHostProbe.requests
        XCTAssertEqual(seen.count, Self.agentOperations.count, "每个 agent 操作都应写出一次")
        for request in seen {
            XCTAssertEqual(request.host, Self.stream.host, request.path)
            XCTAssertTrue(request.path.hasPrefix("/v1/agent/"), request.path)
        }
    }

    /// S04 stream 为 nil：agent 操作仍走 api。
    func testAgentOperationsStayOnApiWithoutStream() async throws {
        StreamHostProbe.install { _ in (200, envelope(0, data: "{}")) }
        let client = client(StreamTestContext(api: Self.api, stream: nil))
        for id in Self.agentOperations.sorted() {
            _ = await client.send(call(try XCTUnwrap(ApiOperations.byId(id))))
        }
        XCTAssertEqual(StreamHostProbe.requests.count, Self.agentOperations.count)
        XCTAssertEqual(Set(StreamHostProbe.requests.map(\.host)), [try XCTUnwrap(Self.api.host)])
    }

    /// S05 不给 stream（prod 的写法）时 NetworkContext 的 stream 为 nil；端点两参数构造见 AppTests StagingHostsEnvironmentTests。
    func testContextWithoutStreamHasNilStream() {
        let context = NetworkContext(
            privacy: PrivacyRaw.full, environmentSettled: true, credentialsReadable: true,
            update: UpdateRaw.supported, apiBaseURL: Self.api
        )
        XCTAssertNil(context.streamBaseURL)
    }

    /// S06 stream 非空：全部非 agent 操作逐个发一遍，写出的都落在 api；至少 30 个真的写出，含 getConfig 与 registerDevice。
    func testEveryNonAgentOperationStaysOnApi() async throws {
        StreamHostProbe.install { _ in (200, envelope(0, data: "{}")) }
        let client = client(StreamTestContext(api: Self.api, stream: Self.stream))
        let others = ApiOperations.all.values.filter { !Self.agentOperations.contains($0.operationId) }
            .sorted { $0.operationId < $1.operationId }
        var written: Set<String> = []
        for operation in others {
            let before = StreamHostProbe.requests.count
            _ = await client.send(call(operation))
            if StreamHostProbe.requests.count > before {
                written.insert(operation.operationId)
            }
        }
        let hosts = Set(StreamHostProbe.requests.map(\.host))
        XCTAssertEqual(hosts, [try XCTUnwrap(Self.api.host)], "非 agent 操作被分到了 stream")
        XCTAssertGreaterThanOrEqual(written.count, 30, "真正写出的非 agent 操作太少：\(written.count)")
        XCTAssertTrue(written.contains("getConfig"))
        XCTAssertTrue(written.contains("registerDevice"))
    }

    /// S07 按 pathTemplate 判断：查询串里带 `/v1/agent/` 的非 agent 请求不分流。
    func testQueryContainingAgentPathDoesNotRoute() async throws {
        StreamHostProbe.install { _ in (200, envelope(0, data: "{\"items\":[],\"next_cursor\":null}")) }
        let client = client(StreamTestContext(api: Self.api, stream: Self.stream))
        _ = await client.send(ApiCall(operationId: "searchProducts", query: "q=%2Fv1%2Fagent%2Fsessions&x=/v1/agent/"))
        XCTAssertEqual(StreamHostProbe.requests.map(\.host), [try XCTUnwrap(Self.api.host)])
    }

    /// S08 agent 请求遇 10002：第一发去 stream，刷新去 api，重放回 stream；重放的 Idempotency-Key 与第一发相同且非空。
    func testAgentReplayAfterRefreshReturnsToStreamWithSameKey() async throws {
        StreamHostProbe.install { request in
            if request.path == "/v1/auth/refresh" {
                return (200, envelope(0, data: refreshData(access: "access-2")))
            }
            return request.header("Authorization") == "Bearer access-2" ? (200, envelope(0, data: "{}"))
                : (401, envelope(10002))
        }
        let client = client(StreamTestContext(api: Self.api, stream: Self.stream))
        let result = await client.send(ApiCall(operationId: "createAgentSession", body: "{}"))
        XCTAssertTrue(result.isSuccess, "\(result)")
        let seen = StreamHostProbe.requests
        XCTAssertEqual(seen.map(\.path), ["/v1/agent/sessions", "/v1/auth/refresh", "/v1/agent/sessions"])
        XCTAssertEqual(
            seen.map(\.host),
            [try XCTUnwrap(Self.stream.host), try XCTUnwrap(Self.api.host), try XCTUnwrap(Self.stream.host)]
        )
        let first = seen.first?.header(HeaderNames.idempotencyKey)
        XCTAssertNotNil(first)
        XCTAssertFalse(first?.isEmpty ?? true)
        XCTAssertEqual(seen.last?.header(HeaderNames.idempotencyKey), first, "重放要沿用第一发的幂等键")
    }

    /// S09 切换环境：两个基址一起换（agent 去新 stream，非 agent 去新 api）。
    func testSwitchingContextMovesBothBases() async throws {
        StreamHostProbe.install { _ in (200, envelope(0, data: "{}")) }
        let context = StreamTestContext(api: Self.api, stream: Self.stream)
        let client = client(context)
        _ = await client.send(ApiCall(operationId: "getCurrentAgentSession"))
        let newApi = try XCTUnwrap(URL(string: "https://api.other.couli.invalid"))
        let newStream = try XCTUnwrap(URL(string: "https://stream.other.couli.invalid"))
        context.current = StreamTestContext.make(api: newApi, stream: newStream)
        _ = await client.send(ApiCall(operationId: "getCurrentAgentSession"))
        _ = await client.send(ApiCall(operationId: "getConfig"))
        XCTAssertEqual(
            StreamHostProbe.requests.map(\.host),
            [try XCTUnwrap(Self.stream.host), try XCTUnwrap(newStream.host), try XCTUnwrap(newApi.host)]
        )
    }
}

/// 记录完整 URL 与请求头的本地假服务。
final class StreamHostProbe: URLProtocol, @unchecked Sendable {
    struct Seen {
        let host: String
        let path: String
        let query: String?
        let headers: [String: String]

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var seen: [Seen] = []
    private nonisolated(unsafe) static var handler: ((Seen) -> (Int, String))?

    static func install(_ handler: @escaping (Seen) -> (Int, String)) {
        lock.withLock {
            seen = []
            self.handler = handler
        }
    }

    static var requests: [Seen] {
        lock.withLock { seen }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let entry = Seen(
            host: url.host ?? "", path: url.path(percentEncoded: true), query: url.query(percentEncoded: true),
            headers: request.allHTTPHeaderFields ?? [:]
        )
        let (status, body) = Self.lock.withLock { () -> (Int, String) in
            Self.seen.append(entry)
            return Self.handler?(entry) ?? (200, envelope(0, data: "{}"))
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])
        client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 可切换的网络上下文。
final class StreamTestContext: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NetworkContext

    init(api: URL?, stream: URL?) {
        value = StreamTestContext.make(api: api, stream: stream)
    }

    static func make(api: URL?, stream: URL?) -> NetworkContext {
        NetworkContext(
            privacy: PrivacyRaw.full, environmentSettled: true, credentialsReadable: true,
            update: UpdateRaw.supported, apiBaseURL: api, streamBaseURL: stream
        )
    }

    var current: NetworkContext {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
