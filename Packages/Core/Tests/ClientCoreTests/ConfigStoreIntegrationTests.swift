import ClientCore
import CouliNetwork
import Foundation
import Generated
import Session
import XCTest

/// ConfigStore 经 ApiClient 对本地假服务拉 `/v1/config`（03 §4.3）：LKG、ETag、304、失败回落、基本模式可拉、切换环境清 LKG。
final class ConfigStoreIntegrationTests: XCTestCase {
    private let configPath = "/v1/config"

    override func setUp() {
        CoreStubProtocol.install { _ in .error(.cannotConnectToHost) }
    }

    private func makeClient(privacy: String = PrivacyRaw.full) -> ApiClient {
        let state = CoreTestState()
        state.set(privacy: privacy)
        return ApiClient(
            identity: ClientIdentity(platform: "ios", appVersion: "1.2.0", build: "120", channel: "app_store"),
            context: { state.context },
            tokens: MemorySessionTokens(),
            pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
            configuration: CoreStubProtocol.configuration(),
            sleeper: { _ in }
        )
    }

    /// 在主线程上发起拉取，等请求到达假服务后再让出主线程，让回复（经主线程回调）交付给 ConfigStore。
    @MainActor
    private func coldStartAndWait(_ store: ConfigStore, foreground: Bool = false) async {
        let before = CoreStubProtocol.requests(path: configPath).count
        if foreground {
            store.onForeground()
        } else {
            store.onColdStart()
        }
        for _ in 0..<400 where CoreStubProtocol.requests(path: configPath).count == before {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    @MainActor
    private func makeStore(_ file: MemoryFile, client: ApiClient) -> ConfigStore {
        ConfigStore(
            readFile: file.read, writeFile: file.write, fetcher: ConfigFetcher.make(client: client),
            clock: { 1 }, bundled: DefaultConfig.json
        )
    }

    @MainActor
    func testFetchSavesLKGThenFailureFallsBackToLKGAndForeground304KeepsIt() async {
        let file = MemoryFile()
        CoreStubProtocol.install { _ in
            coreOK("{\"dict_version\":\"net-1\",\"features\":{\"search_status\":{\"taobao\":\"off\"}}}",
                   headers: ["ETag": "W/\"cfg-1\""])
        }
        let first = makeStore(file, client: makeClient())
        await coldStartAndWait(first)
        XCTAssertEqual(first.sourceRaw, ConfigStore.sourceCurrent)
        XCTAssertEqual(first.searchStatus(platform: "taobao"), "off")
        XCTAssertNotNil(file.value, "成功响应写进 LKG 文件")
        XCTAssertNil(CoreStubProtocol.requests(path: configPath).first?.header("If-None-Match"), "冷启动不带 ETag")

        // 重启：拉取失败继续用 LKG。
        CoreStubProtocol.install { _ in .error(.notConnectedToInternet) }
        let second = makeStore(file, client: makeClient())
        await coldStartAndWait(second)
        XCTAssertEqual(second.sourceRaw, ConfigStore.sourceLKG)
        XCTAssertEqual(second.value(key: "dict_version"), "\"net-1\"")

        // 回前台：带 LKG 的 ETag（原样），304 不变。
        CoreStubProtocol.install { _ in .json(status: 304, headers: [:], body: "") }
        await coldStartAndWait(second, foreground: true)
        XCTAssertEqual(CoreStubProtocol.requests(path: configPath).last?.header("If-None-Match"), "W/\"cfg-1\"")
        XCTAssertEqual(second.sourceRaw, ConfigStore.sourceLKG)
        XCTAssertEqual(second.value(key: "dict_version"), "\"net-1\"")
    }

    @MainActor
    func testNoLKGUsesBundledDefaultAndBasicModeMayFetch() async {
        let file = MemoryFile()
        CoreStubProtocol.install { _ in coreOK("{\"dict_version\":\"basic-net\"}") }
        let store = makeStore(file, client: makeClient(privacy: PrivacyRaw.basic))
        XCTAssertEqual(store.sourceRaw, ConfigStore.sourceBundled)
        await coldStartAndWait(store)
        XCTAssertEqual(CoreStubProtocol.requests(path: configPath).count, 1, "基本模式可拉配置（白名单）")
        XCTAssertNil(CoreStubProtocol.requests(path: configPath).first?.header("X-Device-Id"))
        XCTAssertEqual(store.sourceRaw, ConfigStore.sourceCurrent)
        XCTAssertNotNil(store.linkPatternsJson, "当前响应没有链接表时回落到包内快照")
    }

    @MainActor
    func testEnvironmentSwitchClearsLKGAndDropsInFlightReply() async throws {
        let file = MemoryFile()
        CoreStubProtocol.install { _ in coreOK("{\"dict_version\":\"env-a\"}") }
        let store = makeStore(file, client: makeClient())
        await coldStartAndWait(store)
        XCTAssertNotNil(file.value)

        CoreStubProtocol.install { _ in .hold }
        store.onForeground()
        await CoreStubProtocol.waitUntilHeld()
        try store.clearForEnvironmentSwitch()
        XCTAssertNil(file.value, "切换环境清 LKG")
        XCTAssertEqual(store.sourceRaw, ConfigStore.sourceBundled)
        CoreStubProtocol.release(with: coreOK("{\"dict_version\":\"env-a-late\"}"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.sourceRaw, ConfigStore.sourceBundled, "旧环境晚到的响应丢弃")
        XCTAssertNil(file.value)
    }

    func testReplyMapping() {
        let meta = ApiResponseMeta(httpStatus: 200, headers: ["etag": "\"x\""])
        let ok = ConfigReply.from(.success(data: Data("{}".utf8), traceId: nil, idempotencyKey: nil), meta: meta)
        XCTAssertEqual(ok, ConfigReply(kindRaw: ConfigReply.ok, bodyJson: "{}", etag: "\"x\""))
        let notModified = ConfigReply.from(
            .transportFailure(kind: "no_envelope", httpStatus: 304, idempotencyKey: nil, pendingKeyUnknown: false),
            meta: ApiResponseMeta(httpStatus: 304, headers: [:])
        )
        XCTAssertEqual(notModified.kindRaw, ConfigReply.notModified)
        let failed = ConfigReply.from(.localReject(reason: "environment_unsettled"), meta: meta)
        XCTAssertEqual(failed.kindRaw, ConfigReply.failure)
    }

    func testLinkPatternsKeepLastSuccessfulAcrossRestart() throws {
        let file = MemoryFile()
        var pending: [(ConfigReply) -> Void] = []
        func makeStore() -> ConfigStore {
            ConfigStore(
                readFile: file.read, writeFile: file.write, fetcher: { _, done in pending.append(done) },
                clock: { 1 }, bundled: DefaultConfig.json
            )
        }
        let store = makeStore()
        store.onColdStart()
        pending.removeFirst()(ConfigReply(
            kindRaw: ConfigReply.ok, bodyJson: "{\"link_patterns\":{\"version\":\"good-1\",\"rules\":[]}}", etag: nil
        ))
        store.onForeground()
        pending.removeFirst()(ConfigReply(kindRaw: ConfigReply.ok, bodyJson: "{\"dict_version\":\"x\"}", etag: nil))
        XCTAssertTrue(try XCTUnwrap(store.linkPatternsJson).contains("good-1"), "当前没带链接表：用上一次成功的")

        let restarted = makeStore()
        restarted.onColdStart()
        XCTAssertTrue(try XCTUnwrap(restarted.linkPatternsJson).contains("good-1"), "上一次成功的链接表随 LKG 保存")
    }

    /// 共性 7：每次成功都推进「上一份成功配置」；按平台回落用最近一次成功的，不用冷启动读到的 LKG。
    func testSearchStatusFallsBackToMostRecentSuccessNotColdStartLKG() {
        let file = MemoryFile()
        file.value = "{\"v\":1,\"data\":{\"features\":{\"search_status\":{\"taobao\":\"from-lkg\"}}}}"
        var pending: [(ConfigReply) -> Void] = []
        let store = ConfigStore(
            readFile: file.read, writeFile: file.write, fetcher: { _, done in pending.append(done) },
            clock: { 1 }, bundled: DefaultConfig.json
        )
        store.onColdStart()
        XCTAssertEqual(store.searchStatus(platform: "taobao"), "from-lkg")
        pending.removeFirst()(ConfigReply(
            kindRaw: ConfigReply.ok, bodyJson: "{\"features\":{\"search_status\":{\"taobao\":\"first\"}}}", etag: nil
        ))
        store.onForeground()
        pending.removeFirst()(ConfigReply(
            kindRaw: ConfigReply.ok, bodyJson: "{\"features\":{\"search_status\":{\"jd\":\"off\"}}}", etag: nil
        ))
        XCTAssertEqual(store.searchStatus(platform: "taobao"), "first", "回落到最近一次成功，而不是冷启动的 LKG")
        XCTAssertEqual(store.searchStatus(platform: "jd"), "off")
    }

    func testLKGWriteFailureStillUsesFreshConfig() {
        let file = MemoryFile()
        file.failWrites = true
        var pending: ((ConfigReply) -> Void)?
        let store = ConfigStore(
            readFile: file.read, writeFile: file.write, fetcher: { _, done in pending = done },
            clock: { 1 }, bundled: DefaultConfig.json
        )
        store.onColdStart()
        pending?(ConfigReply(kindRaw: ConfigReply.ok, bodyJson: "{\"dict_version\":\"fresh\"}", etag: nil))
        XCTAssertEqual(store.value(key: "dict_version"), "\"fresh\"")
        XCTAssertNil(file.value)
    }

    func testBundledDefaultHasNoAddresses() {
        XCTAssertNil(DefaultConfig.json.range(of: "https?://", options: .regularExpression))
        XCTAssertFalse(DefaultConfig.json.contains("example.test"))
    }
}
