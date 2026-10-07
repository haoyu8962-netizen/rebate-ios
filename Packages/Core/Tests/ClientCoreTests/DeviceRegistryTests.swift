import ClientCore
import CouliNetwork
import Foundation
import Generated
import SecureStore
import Session
import XCTest

/// 设备注册（BR-ID-09、BR-ID-11；03 §4.1、§4.2）对本地假服务的集成测试，以及契约设备哈希向量。
final class DeviceRegistryTests: XCTestCase {
    private let issuedDevice = "device-issued-1"
    private let issuedSecret = "test-only.install.issued-1"

    override func setUp() {
        CoreStubProtocol.install { _ in .error(.cannotConnectToHost) }
    }

    // MARK: - 契约向量（specs/device-hash.vectors.json，9cd1e6f）

    func testDeviceHashVectorsFromLockedSnapshot() throws {
        let doc = try ClientCoreFixtures.snapshotJSON("specs/device-hash.vectors.json")
        let cases = try XCTUnwrap(doc["hash_cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for row in cases {
            let input = try XCTUnwrap(row["input"] as? String)
            let expected = try XCTUnwrap(row["device_hash"] as? String)
            XCTAssertEqual(DeviceIdPolicy.deviceHash(input), expected, input)
            let source = try XCTUnwrap(row["id_source"] as? String)
            let platform = ["idfv": "ios", "android_id": "android", "odid": "harmony"][source]
            if let platform {
                let decision = DeviceIdPolicy.evaluate(platform: platform, rawId: input, privacy: "consented")
                XCTAssertTrue(decision.register, input)
                XCTAssertEqual(decision.deviceHash, expected, input)
                XCTAssertEqual(decision.idSource, source, input)
            } else {
                XCTAssertEqual(source, "oaid", "MVP 不采集 OAID，只校验算法")
            }
        }
        for row in try XCTUnwrap(doc["invalid_identifier_cases"] as? [[String: Any]]) {
            let input = try XCTUnwrap(row["input"] as? String)
            for platform in ["ios", "android", "harmony"] {
                XCTAssertFalse(
                    DeviceIdPolicy.evaluate(platform: platform, rawId: input, privacy: "consented").register,
                    "\(platform) \(input)"
                )
            }
        }
        var seeds: Set<String> = []
        for row in try XCTUnwrap(doc["invalid_hash_seeds"] as? [[String: Any]]) {
            let source = try XCTUnwrap(row["source_value"] as? String)
            let expected = try XCTUnwrap(row["device_hash"] as? String)
            XCTAssertEqual(DeviceIdPolicy.deviceHash(source), expected, source)
            XCTAssertFalse(DeviceIdPolicy.evaluate(platform: "android", rawId: source, privacy: "consented").register)
            seeds.insert(expected)
        }
        XCTAssertEqual(seeds, DeviceHashSeeds.invalidHashes, "生成的种子与锁定向量一致")
    }

    // MARK: - 同意后注册，签名改用真实凭据

    func testRegistersAfterConsentAndSignsWithIssuedSecretPerVector() async throws {
        let doc = try ClientCoreFixtures.snapshotJSON("specs/request-sign.vectors.json")
        let vector = try XCTUnwrap((doc["valid_cases"] as? [[String: Any]])?.first)
        let secret = try XCTUnwrap(vector["install_secret"] as? String)
        let nonce = try XCTUnwrap(vector["nonce"] as? String)
        let timestamp = try XCTUnwrap(Int64(XCTUnwrap(vector["timestamp"] as? String)))
        let fixture = makeDeviceFixture(clock: { timestamp * 1000 }, nonce: { nonce })
        CoreStubProtocol.install { [issuedDevice] request in
            request.path == ClientCoreFixtures.devicesPath
                ? coreOK(ClientCoreFixtures.registered(issuedDevice, secret)) : coreOK()
        }

        let outcome = await fixture.registry.registerIfNeeded()

        XCTAssertEqual(outcome, .registered)
        let register = try XCTUnwrap(CoreStubProtocol.requests(path: ClientCoreFixtures.devicesPath).first)
        XCTAssertEqual(register.method, "POST")
        XCTAssertNil(register.header("X-Device-Id"), "注册前没有 device_id")
        XCTAssertNil(register.header("X-Sign"), "registerDevice 不签名")
        let hashes = try ClientCoreFixtures.snapshotJSON("specs/device-hash.vectors.json")["hash_cases"]
        let expectedHash = (hashes as? [[String: Any]])?.first { $0["input"] as? String == ClientCoreFixtures.idfv }
        XCTAssertEqual(register.json?["device_hash"] as? String, expectedHash?["device_hash"] as? String)
        XCTAssertEqual(register.json?["id_source"] as? String, "idfv")
        XCTAssertEqual(fixture.registry.deviceId, issuedDevice)

        // 签名接口（links open）：X-Sign 与锁定向量一致，X-Device-Id 是刚签发的。
        let result = await fixture.client.send(ApiCall(
            operationId: "openLink", pathParams: ["link_id": "abc"], query: "src=agent",
            body: vector["body_utf8"] as? String
        ))
        XCTAssertTrue(result.isSuccessResult)
        let signed = try XCTUnwrap(CoreStubProtocol.requests(path: "/v1/links/abc/open").first)
        XCTAssertEqual(signed.header("X-Sign"), vector["expected_sign"] as? String)
        XCTAssertEqual(signed.header("X-Timestamp"), vector["timestamp"] as? String)
        XCTAssertEqual(signed.header("X-Device-Id"), issuedDevice)

        // 已注册：不再读标识、不再请求。
        let outcome1 = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(outcome1, .alreadyRegistered)
        XCTAssertEqual(fixture.reader.reads, 1)
        XCTAssertEqual(CoreStubProtocol.requests(path: ClientCoreFixtures.devicesPath).count, 1)
    }

    func testPersistsBeforeUseAndSaveFailureIsNotSuccess() async {
        let secure = MemorySecureStore()
        let fixture = makeDeviceFixture(secure: secure)
        CoreStubProtocol.install { [issuedDevice, issuedSecret] _ in
            coreOK(ClientCoreFixtures.registered(issuedDevice, issuedSecret))
        }
        secure.failWrites = true

        let outcome = await fixture.registry.registerIfNeeded()

        XCTAssertEqual(outcome, .storeFailed)
        XCTAssertNil(fixture.registry.credentials, "没落盘的凭据不在内存里生效")
        secure.failWrites = false
        let outcome2 = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(outcome2, .registered)
        let reloaded = DeviceRegistry(
            store: DeviceIdentityStore(store: secure), reader: ScriptedIdentifierReader([nil]), platform: "ios",
            context: { fixture.state.context }
        )
        XCTAssertEqual(reloaded.deviceId, issuedDevice, "重启后从安全存储读回")
    }

    // MARK: - 不注册的情形

    func testInvalidIdentifiersSendNoRegistration() async {
        for raw in [nil, "", "00000000-0000-0000-0000-000000000000", "----", "  \n"] as [String?] {
            CoreStubProtocol.install { _ in coreOK() }
            let fixture = makeDeviceFixture(identifiers: [raw])
            let outcome = await fixture.registry.registerIfNeeded()
            XCTAssertEqual(outcome, .invalidIdentifier, String(describing: raw))
            XCTAssertTrue(CoreStubProtocol.requests.isEmpty, "无效标识不发注册请求：\(String(describing: raw))")
            XCTAssertNil(fixture.registry.deviceId)
        }
    }

    func testNotConsentedNeverReadsIdentifier() async {
        for privacy in [PrivacyRaw.basic, PrivacyRaw.undecided] {
            CoreStubProtocol.install { _ in coreOK() }
            let fixture = makeDeviceFixture()
            fixture.state.set(privacy: privacy)
            let outcome3 = await fixture.registry.registerIfNeeded()
            XCTAssertEqual(outcome3, .notAllowed)
            XCTAssertEqual(fixture.reader.reads, 0, "同意前不读 IDFV（BR-ID-11）")
            XCTAssertTrue(CoreStubProtocol.requests.isEmpty)
        }
        let pending = makeDeviceFixture()
        pending.state.set(readable: false)
        let outcome4 = await pending.registry.registerIfNeeded()
        XCTAssertEqual(outcome4, .notAllowed, "撤回清理未完成按未同意")
        XCTAssertEqual(pending.reader.reads, 0)
    }

    func testStoreReadFailureIsNotTreatedAsUnregistered() async {
        let secure = MemorySecureStore()
        let fixture = makeDeviceFixture(secure: secure)
        CoreStubProtocol.install { _ in coreOK() }
        secure.failReads = true

        let outcome5 = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(outcome5, .storeUnreadable)
        XCTAssertTrue(CoreStubProtocol.requests.isEmpty, "读不出凭据时不重新注册")
        XCTAssertNil(fixture.registry.credentials)
    }

    // MARK: - 20001 reread_device_hash

    func test20001RereadsOnceAndNeverResendsRejectedHash() async {
        let fixture = makeDeviceFixture(identifiers: [ClientCoreFixtures.idfv])
        CoreStubProtocol.install { _ in coreFail(20001, data: "{\"fields\":[\"device_hash\"]}") }

        let outcome = await fixture.registry.registerIfNeeded()

        XCTAssertEqual(outcome, .rejectedHash)
        XCTAssertEqual(fixture.reader.reads, 2, "重读一次设备标识")
        XCTAssertEqual(CoreStubProtocol.requests.count, 1, "重读后仍是同一个值：不带原值重试")
        let outcome6 = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(outcome6, .rejectedHash, "退避重试也不再上报被拒的哈希")
        XCTAssertEqual(CoreStubProtocol.requests.count, 1)
    }

    func test20001RereadWithNewValueRegisters() async {
        let fixture = makeDeviceFixture(identifiers: [ClientCoreFixtures.idfv, ClientCoreFixtures.otherIdfv])
        CoreStubProtocol.install { [issuedDevice, issuedSecret] request in
            request.json?["device_hash"] as? String == DeviceIdPolicy.deviceHash(ClientCoreFixtures.idfv)
                ? coreFail(20001, data: "{\"fields\":[\"device_hash\"]}")
                : coreOK(ClientCoreFixtures.registered(issuedDevice, issuedSecret))
        }

        let outcome7 = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(outcome7, .registered)
        XCTAssertEqual(CoreStubProtocol.requests.count, 2)
        XCTAssertEqual(fixture.registry.deviceId, issuedDevice)
    }

    // MARK: - 10402：只重新注册 1 次，然后重放

    func test10402ReRegistersOnceThenReplays() async {
        let secure = MemorySecureStore()
        let fixture = makeDeviceFixture(secure: secure)
        let counter = Counter()
        CoreStubProtocol.install { request in
            if request.path == ClientCoreFixtures.devicesPath {
                let index = counter.next()
                return coreOK(ClientCoreFixtures.registered("device-\(index)", "test-only.install.n\(index)"))
            }
            return request.header("X-Device-Id") == "device-1" ? coreFail(10402) : coreOK("{\"done\":true}")
        }
        let outcome8 = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(outcome8, .registered)

        async let first = fixture.client.send(ApiCall(operationId: "openLink", pathParams: ["link_id": "a"]))
        async let second = fixture.client.send(ApiCall(operationId: "openLink", pathParams: ["link_id": "b"]))
        let results = await [first, second]

        XCTAssertTrue(results.allSatisfy(\.isSuccessResult), "重新注册后各重放 1 次")
        XCTAssertEqual(CoreStubProtocol.requests(path: ClientCoreFixtures.devicesPath).count, 2, "初次 + 单飞的 1 次")
        XCTAssertEqual(fixture.registry.deviceId, "device-2")
        let replays = CoreStubProtocol.requests.filter { $0.header("X-Device-Id") == "device-2" }
        XCTAssertEqual(replays.count, 2)
    }

    func test10402ReplayedOnlyOnce() async {
        let fixture = makeDeviceFixture()
        let counter = Counter()
        CoreStubProtocol.install { request in
            if request.path == ClientCoreFixtures.devicesPath {
                let index = counter.next()
                return coreOK(ClientCoreFixtures.registered("device-\(index)", "test-only.install.n\(index)"))
            }
            return coreFail(10402)
        }
        let outcome9 = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(outcome9, .registered)

        let result = await fixture.client.send(ApiCall(operationId: "openLink", pathParams: ["link_id": "a"]))

        if case let .failure(code, _, _, _, _, _) = result {
            XCTAssertEqual(code, 10402)
        } else {
            XCTFail("重放后的 10402 原样返回：\(result)")
        }
        XCTAssertEqual(CoreStubProtocol.requests(path: ClientCoreFixtures.devicesPath).count, 2, "只重新注册 1 次")
        XCTAssertEqual(CoreStubProtocol.requests(path: "/v1/links/a/open").count, 2, "原请求 + 重放 1 次")
    }

    // MARK: - 撤回同意、切换环境

    func testInvalidationDropsLateRegistrationResult() async throws {
        let fixture = makeDeviceFixture()
        CoreStubProtocol.install { _ in .hold }
        let task = Task { await fixture.registry.registerIfNeeded() }
        await CoreStubProtocol.waitUntilHeld()

        try fixture.registry.invalidateAndClear()
        CoreStubProtocol.release(with: coreOK(ClientCoreFixtures.registered(issuedDevice, issuedSecret)))

        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(fixture.registry.deviceId, "作废后晚到的结果不落盘")
        XCTAssertNil(try fixture.secure.data(forAccount: DeviceIdentityStore.account))
    }

    func testClearFailureKeepsOldCredentialsBlockedUntilDeleted() async throws {
        let secure = MemorySecureStore()
        let fixture = makeDeviceFixture(secure: secure)
        CoreStubProtocol.install { [issuedDevice, issuedSecret] _ in
            coreOK(ClientCoreFixtures.registered(issuedDevice, issuedSecret))
        }
        let outcome10 = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(outcome10, .registered)

        secure.failWrites = true
        XCTAssertThrowsError(try fixture.registry.invalidateAndClear())
        XCTAssertNil(fixture.registry.credentials, "删除失败：内存里继续阻断旧凭据")
        XCTAssertNotNil(try secure.data(forAccount: DeviceIdentityStore.account), "条目仍在")
        XCTAssertNil(fixture.registry.credentials, "重试删除仍失败：继续阻断")

        secure.failWrites = false
        XCTAssertNil(fixture.registry.credentials, "读取时重试删除成功")
        XCTAssertNil(try secure.data(forAccount: DeviceIdentityStore.account), "确认删除后才解除")
        let outcome11 = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(outcome11, .registered, "解除后可重新注册")
    }

    func testCleanerIsNamedForCredentialRegistries() async {
        let registry = makeDeviceFixture().registry
        let name = await MainActor.run { DeviceRegistryCleaner(registry: registry).cleanerName }
        XCTAssertEqual(name, "DeviceIdentity")
    }
}

/// 线程安全计数器。
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

extension ApiResult {
    var isSuccessResult: Bool {
        if case .success = self {
            return true
        }
        return false
    }
}

/// APP-03b 三端共性（android-review-r1）在 iOS 的对应测试。
final class DeviceRegistryLessonsTests: XCTestCase {
    private let rejected20001 = coreFail(20001, data: "{\"fields\":[\"device_hash\"]}")

    override func setUp() {
        CoreStubProtocol.install { _ in .error(.cannotConnectToHost) }
    }

    /// 共性 2：作废后晚到的 20001 不改写被拒哈希、不重读、不继续注册。
    func testLateRejectionAfterInvalidationIsIgnored() async throws {
        let fixture = makeDeviceFixture(identifiers: [ClientCoreFixtures.idfv])
        CoreStubProtocol.install { _ in .hold }
        let task = Task { await fixture.registry.registerIfNeeded() }
        await CoreStubProtocol.waitUntilHeld()
        try fixture.registry.invalidateAndClear()
        CoreStubProtocol.release(with: rejected20001)
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(fixture.reader.reads, 1, "失效的结果不触发重读")

        CoreStubProtocol.install { _ in coreOK(ClientCoreFixtures.registered("device-new", "test-only.install.new")) }
        let again = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(again, .registered, "晚到的 20001 没有把这个哈希记成被拒")
    }

    /// 共性 3：每次 20001 都记下被拒的哈希（重读后的也算），退避重试时都不再发送。
    func testEveryRejectedHashIsExcluded() async {
        let fixture = makeDeviceFixture(identifiers: [
            ClientCoreFixtures.idfv, ClientCoreFixtures.otherIdfv, ClientCoreFixtures.idfv,
            ClientCoreFixtures.otherIdfv,
        ])
        CoreStubProtocol.install { [rejected20001] _ in rejected20001 }
        let first = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(first, .rejectedHash)
        XCTAssertEqual(CoreStubProtocol.requests.count, 2, "原值与重读后的新值各发一次")
        let retry = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(retry, .rejectedHash)
        XCTAssertEqual(CoreStubProtocol.requests.count, 2, "两个被拒的哈希都不再发送")
    }

    /// 共性 4：10402 的重新注册结果按被拒的 device_id 保存；晚到的同一 device_id 的 10402 复用（失败也复用），
    /// 之后交给退避流程。
    func test10402FailureIsReusedAndHandedToBackoff() async {
        let fixture = makeDeviceFixture()
        let counter = Counter()
        let notified = Counter()
        fixture.registry.onNeedsRegistration = { _ = notified.next() }
        CoreStubProtocol.install { request in
            if request.path == ClientCoreFixtures.devicesPath {
                return counter.next() == 1
                    ? coreOK(ClientCoreFixtures.registered("device-1", "test-only.install.n1")) : coreFail(
                        50001,
                        status: 500
                    )
            }
            return coreFail(10402)
        }
        let registered = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(registered, .registered)

        _ = await fixture.client.send(ApiCall(operationId: "openLink", pathParams: ["link_id": "a"]))
        _ = await fixture.client.send(ApiCall(operationId: "openLink", pathParams: ["link_id": "b"]))

        XCTAssertEqual(CoreStubProtocol.requests(path: ClientCoreFixtures.devicesPath).count, 2, "失败结果被复用")
        XCTAssertEqual(notified.next(), 2, "失败只交给退避流程一次")
        CoreStubProtocol.install { _ in coreOK(ClientCoreFixtures.registered("device-2", "test-only.install.n2")) }
        let backoff = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(backoff, .registered, "被拒的 device_id 不算已注册，退避流程会重新注册")
        XCTAssertEqual(fixture.registry.deviceId, "device-2")
    }

    /// 共性 6：刷新请求遇到 10402 也走同一个注册单飞入口，成功后重新签名、至多重放一次。
    func testRefreshHitting10402ReRegistersAndReplaysOnce() async {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let fixture = makeDeviceFixture(tokens: tokens)
        let counter = Counter()
        CoreStubProtocol.install { request in
            switch request.path {
            case ClientCoreFixtures.devicesPath:
                let index = counter.next()
                return coreOK(ClientCoreFixtures.registered("device-\(index)", "test-only.install.n\(index)"))
            case "/v1/auth/refresh":
                return request.header("X-Device-Id") == "device-1"
                    ? coreFail(10402)
                    :
                    coreOK(
                        "{\"access_token\":\"access-2\",\"refresh_token\":\"refresh-2\",\"session_scope\":\"full\"}"
                    )
            default:
                return request.header("Authorization") == "Bearer access-2" ? coreOK() : coreFail(10002, status: 401)
            }
        }
        let registered = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(registered, .registered)

        let result = await fixture.client.send(ApiCall(operationId: "getMe"))

        XCTAssertTrue(result.isSuccessResult, "\(result)")
        let refreshes = CoreStubProtocol.requests(path: "/v1/auth/refresh")
        XCTAssertEqual(refreshes.map { $0.header("X-Device-Id") }, ["device-1", "device-2"], "重新签名后重放一次")
        XCTAssertNotEqual(refreshes[0].header("X-Sign"), refreshes[1].header("X-Sign"))
        XCTAssertEqual(CoreStubProtocol.requests(path: ClientCoreFixtures.devicesPath).count, 2)
        XCTAssertEqual(tokens.accessToken, "access-2")
    }
}

/// APP-03b 三端共性 12、13（android-review-r2）。
final class DeviceRegistryTicketTests: XCTestCase {
    override func setUp() {
        CoreStubProtocol.install { _ in coreOK(ClientCoreFixtures.registered("device-t", "test-only.install.t")) }
    }

    /// 共性 12（S0）：读标识前的最后一次放行检查与读取在同一同步区；不放行就不读 identifierForVendor。
    func testLastAdmissionCheckGuardsTheReadItself() async {
        let fixture = makeDeviceFixture(admitRead: { false })
        let outcome = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(outcome, .notAllowed)
        XCTAssertEqual(fixture.reader.reads, 0, "撤回之后旧任务不再读标识")
        XCTAssertTrue(CoreStubProtocol.requests.isEmpty)
    }

    /// 共性 12：注册任务开始后撤回同意（清理世代变化），旧任务不读标识。
    func testWithdrawalAfterTaskStartPreventsRead() async {
        let fixture = makeDeviceFixture()
        let registry = fixture.registry
        fixture.state.onRead = { count in
            if count == 2 {
                try? registry.invalidateAndClear()
            }
        }
        let outcome = await registry.registerIfNeeded()
        // 清理时旧 flight 被摘掉，等待者按「已取消」结算（共性 24）。
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(fixture.reader.reads, 0)
        XCTAssertTrue(CoreStubProtocol.requests.isEmpty)
    }

    /// 共性 13：注册请求带开始时的 ApiClient 票据；读完标识后网络层已作废（撤回、切换环境）时在发送守卫里结束，
    /// 不被重新绑定到当前环境发出。
    func testRegistrationCarriesOriginalTicketIntoSendGuard() async {
        let fixture = makeDeviceFixture()
        let client = fixture.client
        fixture.state.onRead = { count in
            if count == 3 {
                client.invalidateSessions()
            }
        }
        let outcome = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(fixture.reader.reads, 1)
        XCTAssertTrue(CoreStubProtocol.requests.isEmpty, "旧票据的注册请求不发出")
        XCTAssertNil(fixture.registry.deviceId)
    }
}
