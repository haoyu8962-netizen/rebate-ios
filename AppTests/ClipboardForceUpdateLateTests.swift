import ClientCore
import Clipboard
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Privacy
import Router
import Session
import Update
import XCTest

/// APP-07 iOS 第 1 轮评审 R1-02（共性第 29 条）：整体 10405 的 parse 响应也受归属约束。用生产组装（AppClipboard.make）与真实
/// ApiClient（本地 URLProtocol 假服务，基址 .invalid）：整体 10405 已到达、网络层还在等主线程（errorResult 的 readContext）时用户切 Tab / 离开发起页 / 切换环境，
/// 不得跳强更、UpdateGate 不落盘。对照：发起页仍在时照常进强更（带最低版本按比较，不带按服务端判定落盘）。
@MainActor
final class ClipboardForceUpdateLateTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let link = "https://e.tb.cn/h.Demo01 「降噪蓝牙耳机」"
    static let bare10405 = #"{"code":10405,"msg":"","data":null,"trace_id":"trace-10405"}"#
    static let min10405 = #"{"code":10405,"msg":"","data":{"min_supported_version":"99.0.0"},"trace_id":"t"}"#

    override func setUpWithError() throws {
        suiteName = "ClipboardForceUpdateLateTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        LateReplyProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        LateReplyProtocol.reset()
    }

    private struct Device: DeviceCredentials {
        var deviceId: String? = "device-fixture"
        var installSecret: String? = "test-only.install.device-a"
    }

    private struct Fixture {
        let clipboard: AppClipboard
        let routing: AppRouting
        let update: AppUpdate
        let updateStore: MemoryUpdateStore
        let environmentSwitch: EnvironmentSwitchCleanerRegistry
    }

    private func make() -> Fixture {
        let tokens = MemorySessionTokens()
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = "consented"
        privacyStore.consentedVersion = "1"
        let runner = WithdrawalCleanupRunner(store: privacyStore, registry: withdrawal)
        let network = AppNetwork(
            tokens: tokens, pendingBackend: MemoryPendingKeyBackend(), device: Device(),
            withdrawalRegistry: withdrawal, environmentRegistry: environmentSwitch,
            credentialsReadable: { runner.credentialsReadable }, configuration: LateReplyProtocol.configuration()
        )
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: environmentSwitch)
        let privacy = PrivacyController(
            store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1", withdrawalRunner: runner
        )
        let updateStore = MemoryUpdateStore()
        let update = UpdateFixtures.makeUpdate(store: updateStore)
        let routing = AppRouting(environment: environment, privacy: privacy, update: update)
        routing.shellAppeared()
        let login = AppLogin(network: network, routing: routing, update: update)
        network.attach(environment: environment, privacy: privacy, update: update)
        let config = AppConfig(
            client: network.client, file: ClientFile(name: suiteName + ".json"),
            environmentRegistry: EnvironmentSwitchCleanerRegistry(cleaners: [])
        )
        let records = ClipboardRecordsCleaner(store: ClipboardFileStore(
            file: ClientFile(name: "records.json", baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(suiteName))
        ))
        let clipboard = AppClipboard.make(
            network: network, routing: routing, privacy: privacy, config: config, login: login,
            system: FakeSystemClipboard(), records: records
        )
        login.clipboard = clipboard
        clipboard.sceneActive()
        return Fixture(
            clipboard: clipboard, routing: routing, update: update, updateStore: updateStore,
            environmentSwitch: environmentSwitch
        )
    }

    private func forced(_ fixture: Fixture) -> Bool {
        fixture.update.routerStatus == .finished(.belowMin)
            || fixture.routing.router.path.contains { $0.route == RoutePolicy.forceUpdate }
    }

    /// 等网络层把这次响应处理完（最多约 1 秒）；`until` 先成立就提前结束。
    private func drain(until: () -> Bool = { false }) async {
        for _ in 0..<40 where !until() {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    // MARK: - 迟到：不跳强更、不落盘

    func testLateWhole10405AfterLeavingIsDroppedWithoutPersisting() async {
        let exits: [(String, (Fixture) -> Void)] = [
            ("tab", { _ = $0.routing.selectTab(.me) }),
            ("cover", { $0.routing.router.path = [RouteDestination(route: "Help")] }),
            ("env", { _ = $0.environmentSwitch.cleanAll() }),
        ]
        for body in [Self.bare10405, Self.min10405] {
            for (name, exit) in exits {
                LateReplyProtocol.reset()
                let fixture = make()
                fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
                await LateReplyProtocol.waitUntilHeld()
                XCTAssertEqual(LateReplyProtocol.paths, ["/v1/inputs/parse"], name)
                LateReplyProtocol.releaseAndHoldMain(body: body)
                exit(fixture)
                await drain { self.forced(fixture) }
                XCTAssertFalse(forced(fixture), "\(name)：迟到的整体 10405 不跳强更")
                XCTAssertNil(fixture.updateStore.record.forcedByServer, "\(name)：UpdateGate 不落盘服务端判定")
                XCTAssertNil(fixture.updateStore.record.forcedMinimum, "\(name)：也不落盘最低版本")
                XCTAssertNil(fixture.clipboard.result, name)
            }
        }
    }

    /// 发起页离开（SearchTyping 出栈）后整体 10405 才到：同样丢弃。
    func testLateWhole10405AfterSearchPagePoppedIsDropped() async {
        let fixture = make()
        fixture.routing.router.open(RouteRequest(route: "Search", from: .inApp))
        fixture.clipboard.pasted(entry: ManualPasteAction.entrySearchTyping, text: link)
        await LateReplyProtocol.waitUntilHeld()
        LateReplyProtocol.releaseAndHoldMain(body: Self.bare10405)
        fixture.routing.router.path = []
        await drain { self.forced(fixture) }
        XCTAssertFalse(forced(fixture))
        XCTAssertNil(fixture.updateStore.record.forcedByServer)
    }

    // MARK: - 对照：发起页仍在，照常进强更

    func testOwnedWhole10405StillEntersForceUpdate() async {
        for (body, persisted) in [(Self.bare10405, true), (Self.min10405, false)] {
            LateReplyProtocol.reset()
            let fixture = make()
            fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
            await LateReplyProtocol.waitUntilHeld()
            LateReplyProtocol.release(body: body)
            await drain { self.forced(fixture) }
            XCTAssertTrue(forced(fixture), body)
            XCTAssertEqual(fixture.update.routerStatus, .finished(.belowMin), body)
            if persisted {
                XCTAssertEqual(fixture.updateStore.record.forcedByServer, true, "不带最低版本：按服务端判定落盘")
            } else {
                XCTAssertEqual(fixture.updateStore.record.forcedMinimum, "99.0.0", "带最低版本：按比较")
            }
        }
    }
}

/// 本测试的假服务：请求挂着，直到 `release(body:)` 才在请求所在线程回 403 + 外壳（模拟「服务端响应迟到」）。
final class LateReplyProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var held: [LateReplyProtocol] = []
    private nonisolated(unsafe) static var recorded: [String] = []
    private nonisolated(unsafe) static var waiters: [CheckedContinuation<Void, Never>] = []
    private nonisolated(unsafe) static var finished = false
    private var thread: Thread?
    private var body = ""

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LateReplyProtocol.self]
        return config
    }

    static func reset() {
        lock.withLock {
            held = []
            recorded = []
            waiters = []
            finished = false
        }
    }

    static var paths: [String] {
        lock.withLock { recorded }
    }

    static func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if !held.isEmpty {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    static func release(body: String) {
        let pending: [LateReplyProtocol] = lock.withLock {
            defer { held = [] }
            return held
        }
        for request in pending {
            request.body = body
            guard let thread = request.thread else { continue }
            request.perform(#selector(deliver), on: thread, with: nil, waitUntilDone: false)
        }
    }

    /// 放出响应后阻塞主线程片刻：URLSession 已把响应交给网络层，网络层随后的 readContext 等主线程（评审 R1-02 的窗口），
    /// 调用方这时再切 Tab / 离页 / 切环境——Task 取消已取消不了这次网络任务。
    static func releaseAndHoldMain(body: String) {
        release(body: body)
        for _ in 0..<200 where !lock.withLock({ finished }) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.2)
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        thread = Thread.current
        let path = request.url?.path(percentEncoded: true) ?? ""
        let ready: [CheckedContinuation<Void, Never>] = Self.lock.withLock {
            Self.recorded.append(path)
            Self.held.append(self)
            defer { Self.waiters = [] }
            return Self.waiters
        }
        ready.forEach { $0.resume() }
    }

    @objc private func deliver() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: [:])
        client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
        Self.lock.withLock { Self.finished = true }
    }

    override func stopLoading() {}
}
