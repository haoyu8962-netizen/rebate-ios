import ClientCore
import CouliNetwork
import Foundation
import SecureStore
import Session
import XCTest

/// 本地假服务（URLProtocol 桩）：不连任何真实地址，基址用 .invalid。
final class CoreStubProtocol: URLProtocol {
    enum Reply {
        case json(status: Int, headers: [String: String], body: String)
        case error(URLError.Code)
        /// 先不回应，直到 `release(with:)`（模拟服务端还没回）。
        case hold
    }

    struct Recorded {
        let method: String
        let path: String
        let query: String?
        let headers: [String: String]
        let body: String

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        }
    }

    private final class Held: @unchecked Sendable {
        let stub: CoreStubProtocol
        let runLoop: CFRunLoop

        init(stub: CoreStubProtocol, runLoop: CFRunLoop) {
            self.stub = stub
            self.runLoop = runLoop
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((Recorded) -> Reply)?
    private nonisolated(unsafe) static var recorded: [Recorded] = []
    private nonisolated(unsafe) static var held: [Held] = []
    private nonisolated(unsafe) static var heldWaiters: [CheckedContinuation<Void, Never>] = []

    static func install(_ handler: @escaping (Recorded) -> Reply) {
        lock.withLock {
            self.handler = handler
            recorded = []
            held = []
            heldWaiters = []
        }
    }

    static var requests: [Recorded] {
        lock.withLock { recorded }
    }

    static func requests(path: String) -> [Recorded] {
        requests.filter { $0.path == path }
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CoreStubProtocol.self]
        return config
    }

    /// 等到有一个请求被 hold 住。
    static func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if !held.isEmpty {
                    return true
                }
                heldWaiters.append(continuation)
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    /// 回应最早被 hold 住的请求（在它原来的线程上交付）。
    static func release(with reply: Reply) {
        let entry: Held? = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
        guard let entry else {
            return
        }
        CFRunLoopPerformBlock(entry.runLoop, CFRunLoopMode.commonModes.rawValue) {
            entry.stub.deliver(reply)
        }
        CFRunLoopWakeUp(entry.runLoop)
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
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
            method: request.httpMethod ?? "GET",
            path: url.path(percentEncoded: true),
            query: url.query(percentEncoded: true),
            headers: request.allHTTPHeaderFields ?? [:],
            body: String(bytes: body, encoding: .utf8) ?? ""
        )
        let reply: Reply? = Self.lock.withLock {
            Self.recorded.append(entry)
            return Self.handler?(entry)
        }
        if case .hold = reply {
            let waiters: [CheckedContinuation<Void, Never>] = Self.lock.withLock {
                Self.held.append(Held(stub: self, runLoop: CFRunLoopGetCurrent()))
                let all = Self.heldWaiters
                Self.heldWaiters = []
                return all
            }
            waiters.forEach { $0.resume() }
            return
        }
        deliver(reply ?? .error(.cannotConnectToHost))
    }

    fileprivate func deliver(_ reply: Reply) {
        let url = request.url ?? URL(fileURLWithPath: "/")
        switch reply {
        case .hold:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        case let .json(status, headers, text):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .error(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

/// 外壳响应。
func coreEnvelope(_ code: Int, data: String = "null") -> String {
    "{\"code\":\(code),\"msg\":\"\",\"data\":\(data),\"trace_id\":\"trace-core-0001\"}"
}

func coreOK(_ data: String = "{}", headers: [String: String] = [:]) -> CoreStubProtocol.Reply {
    .json(status: 200, headers: headers, body: coreEnvelope(0, data: data))
}

func coreFail(_ code: Int, status: Int = 400, data: String = "{}") -> CoreStubProtocol.Reply {
    .json(status: status, headers: [:], body: coreEnvelope(code, data: data))
}

/// 测试可变的网络状态。
final class CoreTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = NetworkContext(
        privacy: PrivacyRaw.full, environmentSettled: true, credentialsReadable: true,
        update: UpdateRaw.supported, apiBaseURL: URL(string: "https://api.test.couli.invalid")
    )

    /// 每次读状态时先调用（参数为第几次读取，从 1 开始），用来在注册流程的两步之间撤回同意等。
    var onRead: (@Sendable (Int) -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue; reads = 0 } }
    }

    private var hook: (@Sendable (Int) -> Void)?
    private var reads = 0

    var context: NetworkContext {
        let (count, current) = lock.withLock { () -> (Int, (@Sendable (Int) -> Void)?) in
            reads += 1
            return (reads, hook)
        }
        current?(count)
        return lock.withLock { value }
    }

    func set(privacy: String? = nil, settled: Bool? = nil, readable: Bool? = nil) {
        lock.withLock {
            value = NetworkContext(
                privacy: privacy ?? value.privacy,
                environmentSettled: settled ?? value.environmentSettled,
                credentialsReadable: readable ?? value.credentialsReadable,
                update: value.update,
                apiBaseURL: value.apiBaseURL
            )
        }
    }
}

/// 可编排的设备标识读取：按顺序返回 values，用完后重复最后一个；记录读取次数。
final class ScriptedIdentifierReader: DeviceIdentifierReading, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?]
    private var count = 0

    init(_ values: [String?]) {
        self.values = values
    }

    var reads: Int {
        lock.withLock { count }
    }

    @MainActor
    func readIdentifier() -> String? {
        lock.withLock {
            count += 1
            if values.count > 1 {
                return values.removeFirst()
            }
            return values.first ?? nil
        }
    }
}

/// 一套设备注册的测试组合：DeviceRegistry 作为 ApiClient 的设备凭据，10402 接到它的重新注册。
struct DeviceFixture {
    let registry: DeviceRegistry
    let client: ApiClient
    let state: CoreTestState
    let secure: MemorySecureStore
    let reader: ScriptedIdentifierReader
}

func makeDeviceFixture(
    identifiers: [String?] = [ClientCoreFixtures.idfv],
    secure: MemorySecureStore = MemorySecureStore(),
    tokens: any SessionTokens = MemorySessionTokens(),
    admitRead: @escaping @MainActor @Sendable () -> Bool = { true },
    clock: @escaping @Sendable () -> Int64 = { 1_790_661_600_000 },
    nonce: @escaping @Sendable () -> String = { "b5a8f07b9dda63c3f78ed24c341d25b3" },
    registryContext: (@Sendable (CoreTestState) async -> NetworkContext)? = nil,
    afterCredentialAdmission: @escaping @Sendable () -> Void = {},
    clientContext: (@Sendable (CoreTestState) async -> NetworkContext)? = nil
) -> DeviceFixture {
    let state = CoreTestState()
    let reader = ScriptedIdentifierReader(identifiers)
    let registry = DeviceRegistry(
        store: DeviceIdentityStore(store: secure),
        reader: reader,
        platform: "ios",
        context: { await registryContext?(state) ?? state.context },
        admitRead: admitRead
    )
    var hooks = NetworkHooks(
        reRegisterDevice: { rejected, isValid in
            await registry.reRegister(rejectedDeviceId: rejected, isValid: isValid)
        },
        deviceRejected: { rejected in registry.deviceRejected(rejectedDeviceId: rejected) }
    )
    hooks.afterCredentialAdmission = afterCredentialAdmission
    let client = ApiClient(
        identity: ClientIdentity(platform: "ios", appVersion: "1.2.0", build: "120", channel: "app_store"),
        context: { await clientContext?(state) ?? state.context },
        device: registry,
        tokens: tokens,
        pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
        hooks: hooks,
        configuration: CoreStubProtocol.configuration(),
        clock: clock,
        sleeper: { _ in },
        nonce: nonce
    )
    registry.bind(client: client)
    return DeviceFixture(registry: registry, client: client, state: state, secure: secure, reader: reader)
}

enum ClientCoreFixtures {
    /// 契约设备哈希向量里的 IDFV 输入（同一个值的哈希由向量文件给出，测试从文件读，不复制）。
    static let idfv = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
    static let otherIdfv = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    static let devicesPath = "/v1/devices"

    /// registerDevice 的响应 data。
    static func registered(_ device: String, _ secret: String) -> String {
        "{\"device_id\":\"\(device)\",\"install_secret\":\"\(secret)\"}"
    }

    /// 仓库根（向上找 contract.lock）。
    static func repositoryRoot(file: String = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: file).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw NSError(domain: "ClientCoreFixtures", code: 1)
            }
            directory = parent
        }
        return directory
    }

    static func snapshotJSON(_ relative: String) throws -> [String: Any] {
        let url = try repositoryRoot().appendingPathComponent("contracts/snapshot").appendingPathComponent(relative)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }
}

/// 内存文件替身（可注入读写失败）。
final class MemoryFile {
    var value: String?
    var failReads = false
    var failWrites = false
    var writes = 0

    struct Failure: Error {}

    func read() throws -> String? {
        if failReads {
            throw Failure()
        }
        return value
    }

    func write(_ text: String?) throws {
        if failWrites {
            throw Failure()
        }
        writes += 1
        value = text
    }
}
