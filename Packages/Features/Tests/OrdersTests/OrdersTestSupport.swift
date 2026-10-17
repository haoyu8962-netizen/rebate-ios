import Clipboard
import CouliNetwork
import Foundation
import OrderCore
import Session
import XCTest

/// 本地假服务：URLProtocol 桩，不连任何真实地址（基址 .invalid）。可以把某个请求 hold 住（模拟迟到响应），或按传输失败结束。
final class OrdersStub: URLProtocol {
    enum Reply {
        case json(status: Int, headers: [String: String], body: String)
        /// 不回应，直到测试 `release(id, with:)`。
        case hold(String)
        /// 传输失败（断网）。
        case offline
    }

    struct Recorded {
        let method: String
        let path: String
        let query: [String: String]
        let body: String
    }

    private final class Held: @unchecked Sendable {
        let stub: OrdersStub
        let runLoop: CFRunLoop

        init(stub: OrdersStub, runLoop: CFRunLoop) {
            self.stub = stub
            self.runLoop = runLoop
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((Recorded) -> Reply)?
    private nonisolated(unsafe) static var recorded: [Recorded] = []
    private nonisolated(unsafe) static var held: [String: Held] = [:]
    private var holdId: String?

    static func install(_ handler: @escaping (Recorded) -> Reply) {
        lock.withLock {
            self.handler = handler
            recorded = []
            held = [:]
        }
    }

    static var requests: [Recorded] {
        lock.withLock { recorded }
    }

    static func requests(_ path: String) -> [Recorded] {
        requests.filter { $0.path == path }
    }

    static func isHeld(_ id: String) -> Bool {
        lock.withLock { held[id] != nil }
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
        config.protocolClasses = [OrdersStub.self]
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
            method: request.httpMethod ?? "GET", path: url.path, query: query, body: String(
                bytes: body,
                encoding: .utf8
            ) ?? ""
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

    fileprivate func deliver(_ reply: Reply) {
        let url = request.url ?? URL(fileURLWithPath: "/")
        switch reply {
        case let .json(status, headers, text):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .offline, .hold:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }

    override func stopLoading() {
        guard let id = holdId else { return }
        _ = Self.lock.withLock { Self.held.removeValue(forKey: id) }
    }
}

enum OrderFixtures {
    static let trace = "0199a3b4-5c6d-7e8f-9a0b-1c2d3e123456"

    static func envelope(_ code: Int, data: String) -> String {
        "{\"code\":\(code),\"msg\":\"\",\"data\":\(data),\"trace_id\":\"\(trace)\"}"
    }

    static func ok(_ data: String) -> OrdersStub.Reply {
        .json(status: 200, headers: [:], body: envelope(0, data: data))
    }

    static func fail(_ code: Int, headers: [String: String] = [:]) -> OrdersStub.Reply {
        .json(status: 400, headers: headers, body: envelope(code, data: "{}"))
    }

    /// 一行订单（JSON 文本）。
    static func row(
        _ id: String, status: String = "PAID", number: String? = nil, masked: String? = nil, pay: String = "4560",
        est: String = "234", title: String = "\"t\"", other: Bool = false
    ) -> String {
        let no = masked.map { "\"masked_order_no\":\"\($0)\"" } ?? "\"order_no\":\"\(number ?? "37" + id)\""
        return "{\"order_id\":\"\(id)\",\"platform\":\"taobao\",\"title\":\(title),\"image_url\":null,"
            + "\"pay_amount_fen\":\(pay),\"quantity\":1,\(no),\"display_status\":\"\(status)\",\"reason\":null,"
            + "\"est_rebate_fen\":\(est),\"paid_at\":\"2026-10-02T09:31:00+08:00\",\"is_other_product\":\(other)}"
    }

    static func page(_ rows: [String], next: String? = nil, earliest: String? = nil) -> String {
        "{\"items\":[\(rows.joined(separator: ","))],\"next_cursor\":\(next.map { "\"\($0)\"" } ?? "null"),"
            + "\"earliest_visible_date\":\(earliest.map { "\"\($0)\"" } ?? "null")}"
    }

    static func detail(
        _ id: String, status: String = "PAID", number: String? = nil, masked: String? = nil,
        productKey: String? = "tb:9007", actions: String = "[]", reason: String = "null", actual: String = "null",
        priceCompare: String = "false"
    ) -> String {
        let base = row(id, status: status, number: number, masked: masked)
        return String(base.dropLast()).replacingOccurrences(of: "\"reason\":null", with: "\"reason\":\(reason)")
            + ",\"product_key\":\(productKey.map { "\"\($0)\"" } ?? "null"),\"reason_action\":\(actions),"
            + "\"timeline\":[{\"node\":\"paid\",\"at\":\"2026-10-02T09:31:00+08:00\",\"period\":null}],"
            + "\"expected_credit_period\":null,\"credit_overdue\":false,\"actual_fen\":\(actual),\"clawback_fen\":null,"
            + "\"appeal_pending\":false,\"is_price_compare\":\(priceCompare)}"
    }

    struct Track {
        let link: String
        let attempt: String
        let platform: String
        let dismissed: Bool

        init(_ link: String, _ attempt: String, _ platform: String, _ dismissed: Bool) {
            self.link = link
            self.attempt = attempt
            self.platform = platform
            self.dismissed = dismissed
        }
    }

    static func tracks(_ items: [Track]) -> String {
        let rows = items.map {
            "{\"link_id\":\"\($0.link)\",\"attempt_id\":\"\($0.attempt)\",\"platform\":\"\($0.platform)\","
                + "\"jumped_at\":\"2026-10-09T10:00:00+08:00\",\"show_claim_entry\":true,\"dismissed\":\($0.dismissed)}"
        }
        return "{\"items\":[\(rows.joined(separator: ","))]}"
    }
}

struct OrdersStubDevice: DeviceCredentials {
    var deviceId: String? {
        "dev-1"
    }

    var installSecret: String? {
        "placeholder"
    }
}

/// 真实 ApiClient（URLProtocol 假服务），已登录（订单接口 auth=login）。
/// `tokens` 不为 nil 时用它（测试据此在底层换会话）。
func makeOrdersClient(account: String = "user-a", tokens: MemorySessionTokens? = nil) -> ApiClient {
    ApiClient(
        identity: ClientIdentity(platform: "ios", appVersion: "9.9.9", build: "1", channel: "appstore"),
        context: {
            NetworkContext(
                privacy: PrivacyRaw.full, environmentSettled: true, credentialsReadable: true,
                update: UpdateRaw.supported, apiBaseURL: URL(string: "https://api.test.invalid")
            )
        },
        device: OrdersStubDevice(),
        tokens: tokens ?? MemorySessionTokens(access: "at-1", refresh: "rt-1", scope: "full", account: account),
        pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
        configuration: OrdersStub.configuration(),
        sleeper: { _ in }
    )
}

/// 列表 / 详情执行器的环境。
@MainActor
final class FakeOrderEnv: OrderListEnv, PendingTrackEnv {
    var account: String? = "user-a"
    var nowMs: Int64 = 1_791_000_000_000
    var member = true
    var requestedBefore = false
    var pushRequests = 0
    /// 真正弹出系统框的次数（模拟 PermissionRequester：等完系统状态后复核 isValid 才弹）。
    var systemPrompts = 0
    /// App 侧的会话 / 隐私 / 环境版本（点击时捕获，变化即失效）。
    var appTicket = 0
    /// 固定身份里的网络归属（iOS RC-01；nil = 不比较，原有测试不变）。
    var request: RequestOwnership?
    /// 为 true 时把申请挂在「等系统通知状态」，直到 `finishStatusWait()`。
    var holdStatus = false
    private var statusWaiter: CheckedContinuation<Void, Never>?

    func now() -> Int64 {
        nowMs
    }

    func requestPush(isValid: @escaping @MainActor () -> Bool) async {
        pushRequests += 1
        guard isValid() else { return }
        if holdStatus {
            await withCheckedContinuation { statusWaiter = $0 }
        }
        guard isValid() else { return }
        systemPrompts += 1
    }

    func currentOwner() -> OrderOwner {
        OrderOwner(account: account, key: "\(account ?? "-")#\(appTicket)", member: member, request: request)
    }

    func isCurrent(_ owner: OrderOwner) -> Bool {
        currentOwner() == owner
    }

    var waitingStatus: Bool {
        statusWaiter != nil
    }

    func finishStatusWait() {
        statusWaiter?.resume()
        statusWaiter = nil
    }
}

/// 可变时钟（限流测试）。
final class OrdersClock: @unchecked Sendable {
    private let lock = NSLock()
    private var millis: Int64 = 1_700_000_000_000

    var now: Int64 {
        lock.withLock { millis }
    }

    func advance(_ delta: Int64) {
        lock.withLock { millis += delta }
    }
}

/// 计数的系统剪贴板（只计次数与最后写入内容）。
@MainActor
final class CountingClipboard: SystemClipboard {
    var changeCount = 0
    var writes: [String] = []

    func detectLink(_ completion: @escaping @MainActor (Bool) -> Void) {
        completion(false)
    }

    func write(_ text: String) {
        writes.append(text)
        changeCount += 1
    }
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("orders-tests-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.appendingPathComponent("orders", isDirectory: true)
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

/// 让主线程上的结算跑完。
@MainActor
func settle() async {
    for _ in 0..<20 {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// 测试便利：按此刻渲染出的票据关闭 / 申请（等同视图在这一刻渲染并立即点击）。
@MainActor
extension PendingTrackService {
    @discardableResult
    func dismiss(_ card: PendingTrackCardView) -> Bool {
        dismiss(ticket(for: card))
    }

    func requestNotification(_ card: PendingTrackCardView) {
        requestNotification(ticket(for: card))
    }
}

/// FU-IOS-0712 R1-01：缓存与恢复记录的读写改为必须带固定身份的登录世代（`loginEpoch:`）。这些执行层旧用例用的是不按登录世代分区的存储
/// （`partitionedByLoginEpoch == false`，只按账号），世代不参与分区；这里保留它们原来的调用写法（世代传 nil），断言不变。
@MainActor
extension OrderCacheStore {
    func readList(account: String?, scope: String) -> CachedOrderList? {
        readList(account: account, loginEpoch: nil, scope: scope)
    }

    func writeList(account: String?, scope: String, data: OrderListData, fetchedAt: Int64) {
        writeList(account: account, loginEpoch: nil, scope: scope, data: data, fetchedAt: fetchedAt)
    }

    func readDetail(account: String?, orderId: String) -> CachedOrderDetail? {
        readDetail(account: account, loginEpoch: nil, orderId: orderId)
    }

    func writeDetail(account: String?, detail: OrderDetail, fetchedAt: Int64) {
        writeDetail(account: account, loginEpoch: nil, detail: detail, fetchedAt: fetchedAt)
    }

    func reconcileOwner(account: String?) {
        reconcileOwner(account: account, loginEpoch: nil)
    }
}

@MainActor
extension OrderPageRestorer {
    func decide(account: String?) -> OrderPageRecord? {
        decide(account: account, loginEpoch: nil)
    }

    func persist(conditions: OrderConditions, anchor: String?, account: String?) {
        persist(conditions: conditions, anchor: anchor, account: account, loginEpoch: nil)
    }
}
