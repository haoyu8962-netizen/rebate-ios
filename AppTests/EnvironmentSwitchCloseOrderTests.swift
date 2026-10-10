import ClientCore
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Privacy
import SecureStore
import Session
import XCTest

/// FU-IOS-0711（APP-08 第八次复核 NEW-07 → F-IOS-05）：切换环境的关闭步骤先于发布 switching。
///
/// 时序（修复后）：`EnvironmentStore.switchTo` → `EnvironmentApplier.closeRequests`（网络作废：推进作废世代、竖网络屏障；
/// 设备禁读；取消在途传输，与 `sendOnce` 最终准入同一把传输锁）→ 发布 switching → 读取保留项（`cleanPreservingRecords`
/// 开头再关一次）→ 清理器（第一位仍是网络层作废）。
///
/// 探针放在「读取保留项」那一刻（switching 已生效、首个清理器尚未运行）：在那里恢复暂停的旧请求，断言凭据零读取、零发送。
/// 对照：切换成功后新环境的正常请求与设备注册可用；切换失败回退后正常恢复；启动对账、阻断页重试同样先关闭。
@MainActor
final class EnvironmentSwitchCloseOrderTests: XCTestCase {
    private var suiteName = ""
    private var defaults: CloseOrderProbeDefaults!

    override func setUpWithError() throws {
        suiteName = "EnvironmentSwitchCloseOrderTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(CloseOrderProbeDefaults(suiteName: suiteName))
        AppStubProtocol.reset()
        Self.installServer()
    }

    override func tearDown() {
        defaults.onPreservedRead = nil
        defaults.removePersistentDomain(forName: suiteName)
        AppStubProtocol.reset()
    }

    private struct Fixture {
        let network: AppNetwork
        let privacy: PrivacyController
        let environment: EnvironmentStore
        let tokens: CloseOrderCountingTokens
        let registry: EnvironmentSwitchCleanerRegistry
        let switchable: CloseOrderSwitchableCleaner
        /// 网络状态源只弱引用 AppUpdate：测试组合要持有它。
        let update: AppUpdate
    }

    private static let getMe = ApiCall(operationId: "getMe")

    private static func installServer() {
        AppStubProtocol.install { request in
            guard request.path == "/v1/devices" else {
                return .json(status: 200, body: "{\"code\":0,\"msg\":\"\",\"data\":{},\"trace_id\":\"t\"}")
            }
            return .json(
                status: 200,
                body: "{\"code\":0,\"msg\":\"\",\"data\":{\"device_id\":\"device-app-1\","
                    + "\"install_secret\":\"test-only.install.app-1\"},\"trace_id\":\"t\"}"
            )
        }
    }

    private func makeFixture(
        device: (any DeviceCredentials)? = nil,
        snapshotTap: (@Sendable (NetworkContext) async -> NetworkContext)? = nil,
        launchFailures: Int = 0
    ) -> Fixture {
        let tokens = CloseOrderCountingTokens(
            MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        )
        let switchable = CloseOrderSwitchableCleaner()
        switchable.failuresLeft = launchFailures
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [
            SessionTokensCleaner(tokens: tokens), switchable,
        ])
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = "consented"
        privacyStore.consentedVersion = "1"
        let runner = WithdrawalCleanupRunner(store: privacyStore, registry: withdrawal)
        let network = AppNetwork(
            tokens: tokens,
            pendingBackend: MemoryPendingKeyBackend(),
            device: device,
            deviceStore: DeviceIdentityStore(store: MemorySecureStore()),
            identifierReader: CloseOrderFixedReader(),
            withdrawalRegistry: withdrawal,
            environmentRegistry: environmentSwitch,
            credentialsReadable: { runner.credentialsReadable },
            configuration: AppStubProtocol.configuration(),
            snapshotTap: snapshotTap
        )
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: environmentSwitch)
        let privacy = PrivacyController(
            store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1", withdrawalRunner: runner,
            deviceRegistration: { done in network.registerDevice(done: done) }
        )
        let update = UpdateFixtures.makeUpdate()
        network.attach(environment: environment, privacy: privacy, update: update)
        return Fixture(
            network: network, privacy: privacy, environment: environment, tokens: tokens,
            registry: environmentSwitch, switchable: switchable, update: update
        )
    }

    private func waitForDevice(_ network: AppNetwork) async {
        for _ in 0..<400 where network.registry.deviceId == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// 读取保留项那一刻：记下 switching、两道屏障、令牌是否还在（清理器未运行），恢复旧请求并等它结束（最多 5 秒），记下增量。
    private func probeAtPreservedRead(
        _ fixture: Fixture, seen: CloseOrderSeen, resume: DispatchSemaphore, finished: DispatchSemaphore
    ) {
        let tokenBase = fixture.tokens.reads
        let deviceBase = fixture.network.registry.identityReads
        let sentBase = AppStubProtocol.requests.count
        defaults.onPreservedRead = { [weak environment = fixture.environment] in
            seen.switching.append(environment?.switching ?? false)
            seen.networkBarrier.append(fixture.network.client.withdrawalReadBarrierRaised)
            seen.deviceBarrier.append(fixture.network.registry.withdrawalBarrierRaised)
            seen.tokenPresent.append(fixture.tokens.inner.accessToken != nil)
            resume.signal()
            seen.resumedFinished.append(finished.wait(timeout: .now() + 5) == .success)
            seen.tokenReadsDelta.append(fixture.tokens.reads - tokenBase)
            seen.deviceReadsDelta.append(fixture.network.registry.identityReads - deviceBase)
            seen.sentDelta.append(AppStubProtocol.requests.count - sentBase)
        }
    }

    // MARK: - switching 已生效、首个清理器尚未运行：旧请求零读取、零发送

    /// 旧请求已取得「环境就绪、完整模式、可读」的快照后暂停；Debug 切换页的入口 `switchTo` 发布 switching、读取保留项时恢复它——
    /// 会话令牌零读取、设备凭据零读取、零发送。
    func testSwitchingPublishedBeforeFirstCleanerOldSnapshotReadsNothingSendsNothing() async throws {
        let pause = CloseOrderPause()
        let fixture = makeFixture(snapshotTap: { state in
            await Task.detached { pause.pass() }.value
            return state
        })
        await waitForDevice(fixture.network)
        XCTAssertEqual(fixture.network.registry.deviceId, "device-app-1", "前提：旧环境设备已注册")
        try? await Task.sleep(nanoseconds: 50_000_000)

        pause.arm()
        let finished = DispatchSemaphore(value: 0)
        let client = fixture.network.client
        let call = Task.detached { () -> ApiResult in
            let result = await client.send(Self.getMe)
            finished.signal()
            return result
        }
        let reachedPause = await pause.waitUntilPaused()
        XCTAssertTrue(reachedPause, "前提：旧请求持旧快照停在暂停点")
        let seen = CloseOrderSeen()
        probeAtPreservedRead(fixture, seen: seen, resume: pause.resume, finished: finished)

        try fixture.environment.switchTo(.staging)
        let result = await call.value

        XCTAssertEqual(seen.switching, [true], "前提：探针时 switching 已生效")
        XCTAssertEqual(seen.tokenPresent, [true], "前提：探针时清理器尚未运行（令牌还在）")
        XCTAssertEqual(seen.resumedFinished, [true], "前提：旧请求在清理器运行之前已恢复并结束")
        XCTAssertEqual(seen.networkBarrier, [true], "发布 switching 之前已竖网络屏障")
        XCTAssertEqual(seen.deviceBarrier, [true], "发布 switching 之前已竖设备屏障")
        XCTAssertEqual(seen.tokenReadsDelta, [0], "switching 已生效、清理器未运行：会话令牌零读取")
        XCTAssertEqual(seen.deviceReadsDelta, [0], "switching 已生效、清理器未运行：设备凭据零读取")
        XCTAssertEqual(seen.sentDelta, [0], "旧请求零发送")
        XCTAssertFalse(result.closeOrderSucceeded, "\(result)")
        XCTAssertEqual(fixture.environment.current.id, "staging")
    }

    /// 切换前已读完凭据、组好请求、尚未写出（停在设备凭据交回之前）的旧请求：切换开始后恢复，最终准入（sendOnce）拒绝写出。
    func testRequestBuiltBeforeSwitchIsNotWrittenAfterSwitchStarts() async throws {
        let pause = CloseOrderPause()
        let fixture = makeFixture(device: CloseOrderPausingDevice(pause: pause))
        try? await Task.sleep(nanoseconds: 50_000_000)

        pause.arm()
        let finished = DispatchSemaphore(value: 0)
        let client = fixture.network.client
        let call = Task.detached { () -> ApiResult in
            let result = await client.send(Self.getMe)
            finished.signal()
            return result
        }
        let reachedPause = await pause.waitUntilPaused()
        XCTAssertTrue(reachedPause, "前提：旧请求已通过凭据准入、停在写出之前")
        let seen = CloseOrderSeen()
        probeAtPreservedRead(fixture, seen: seen, resume: pause.resume, finished: finished)

        try fixture.environment.switchTo(.staging)
        let result = await call.value

        XCTAssertEqual(seen.switching, [true], "前提：探针时 switching 已生效")
        XCTAssertEqual(seen.resumedFinished, [true], "前提：旧请求在清理器运行之前已恢复并结束")
        XCTAssertEqual(seen.sentDelta, [0], "切换开始之后旧请求零写出")
        XCTAssertEqual(result.notSentReason, LocalRejectReason.callCancelled, "\(result)")
    }

    // MARK: - 对照：切换成功、失败回退后正常恢复

    /// 切换成功：新环境里设备重新注册，正常请求（新登录的令牌）放下两道屏障并带令牌、设备头发出。
    func testAfterSwitchSucceedsRequestsAndRegistrationWorkInNewEnvironment() async throws {
        let fixture = makeFixture()
        await waitForDevice(fixture.network)
        let registrations = AppStubProtocol.requests.filter { $0.path == "/v1/devices" }.count

        try fixture.environment.switchTo(.staging)
        XCTAssertFalse(fixture.environment.switching)
        XCTAssertNil(fixture.network.registry.deviceId, "清理阶段删掉旧环境的设备凭据")
        await waitForDevice(fixture.network)
        XCTAssertEqual(fixture.network.registry.deviceId, "device-app-1", "新环境重新注册设备")
        XCTAssertEqual(AppStubProtocol.requests.filter { $0.path == "/v1/devices" }.count, registrations + 1)
        XCTAssertFalse(fixture.network.registry.withdrawalBarrierRaised, "新环境设备注册放下设备屏障")

        try fixture.tokens.save(access: "access-new", refresh: "refresh-new", scope: "full", account: "account-B")
        let result = await fixture.network.client.send(Self.getMe)
        XCTAssertTrue(result.closeOrderSucceeded, "\(result)")
        XCTAssertFalse(fixture.network.client.withdrawalReadBarrierRaised, "新环境的正常请求放下网络屏障")
        XCTAssertEqual(AppStubProtocol.requests.last?.header("Authorization"), "Bearer access-new")
        XCTAssertEqual(AppStubProtocol.requests.last?.header("X-Device-Id"), "device-app-1")
    }

    /// 切换失败回退：留在旧环境，switching 结束；设备重新注册，正常请求放下屏障并照常发出。
    func testAfterSwitchFailsFallbackRecoversNormally() async throws {
        let fixture = makeFixture()
        await waitForDevice(fixture.network)
        fixture.switchable.failuresLeft = 1

        XCTAssertThrowsError(try fixture.environment.switchTo(.staging))
        XCTAssertEqual(fixture.environment.current.id, "test", "失败回退：仍在旧环境")
        XCTAssertFalse(fixture.environment.switching)
        XCTAssertTrue(fixture.network.client.withdrawalReadBarrierRaised, "前提：关闭步骤已竖网络屏障")
        await waitForDevice(fixture.network)
        XCTAssertEqual(fixture.network.registry.deviceId, "device-app-1", "回退后重新注册设备")
        XCTAssertFalse(fixture.network.registry.withdrawalBarrierRaised)

        try fixture.tokens.save(access: "access-2", refresh: "refresh-2", scope: "full", account: "account-A")
        let result = await fixture.network.client.send(Self.getMe)
        XCTAssertTrue(result.closeOrderSucceeded, "\(result)")
        XCTAssertFalse(fixture.network.client.withdrawalReadBarrierRaised, "回退后的正常请求放下网络屏障")
        XCTAssertEqual(AppStubProtocol.requests.last?.header("Authorization"), "Bearer access-2")
    }

    // MARK: - 其他入口：启动对账、阻断页重试

    /// 冷启动对账（覆盖安装换了环境）与阻断页重试：读取保留项之前两道屏障都已竖起；重试成功后转为 settled。
    func testLaunchReconcileAndBlockedRetryCloseBeforeReadingPreservedKeys() {
        defaults.set("prod", forKey: AppNamespace.appliedEnvironmentKey)
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let switchable = CloseOrderSwitchableCleaner()
        switchable.failuresLeft = 2
        let registry = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens), switchable])
        let network = AppNetwork(
            tokens: tokens,
            pendingBackend: MemoryPendingKeyBackend(),
            deviceStore: DeviceIdentityStore(store: MemorySecureStore()),
            identifierReader: CloseOrderFixedReader(),
            withdrawalRegistry: EnvironmentSwitchCleanerRegistry(cleaners: []),
            environmentRegistry: registry,
            credentialsReadable: { true },
            configuration: AppStubProtocol.configuration()
        )
        var barriers: [String: [Bool]] = [:]
        let record: (String) -> () -> Void = { entry in
            {
                barriers[entry] = [
                    network.client.withdrawalReadBarrierRaised, network.registry.withdrawalBarrierRaised,
                ]
            }
        }
        // 跳过 init 读选择记录、对账读生效记录这两次，探针落在清理前保存保留项那一刻。
        defaults.skipPreservedReads = 2
        defaults.onPreservedRead = record("启动对账")
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: registry)
        XCTAssertEqual(environment.gate, .blocked, "前提：清理两次失败，阻断")

        defaults.skipPreservedReads = 1
        defaults.onPreservedRead = record("阻断页重试")
        environment.retryLaunchCleanup()
        XCTAssertEqual(environment.gate, .settled)

        XCTAssertEqual(barriers["启动对账"], [true, true], "启动对账：读取保留项之前已竖网络与设备屏障")
        XCTAssertEqual(barriers["阻断页重试"], [true, true], "阻断页重试：读取保留项之前已竖网络与设备屏障")
        XCTAssertNil(tokens.accessToken, "随后清理器照常执行")
    }
}
