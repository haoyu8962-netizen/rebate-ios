import ClientCore
import Clipboard
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import MeCore
import Privacy
import Push
import Router
import Session
import SwiftUI
import Update
import XCTest

/// 网络层读到的设备凭据（ApiClient 的 `device:`）。`me.deviceId`（确认时的 deviceRegistered）不受它影响，照旧是已注册。
/// 放在文件顶层（不在 @MainActor 测试类里），保证 DeviceCredentials 的要求是非隔离的。
final class WithdrawSwitchableDevice: DeviceCredentials, @unchecked Sendable {
    enum Mode {
        case readable
        /// 读不出：device_id 与 install_secret 都没有。
        case missing
        /// device_id 为空串（`credentials` 按缺失处理）。
        case emptyId
    }

    private let lock = NSLock()
    private var mode = Mode.readable

    var deviceId: String? {
        lock.withLock { () -> String? in
            switch mode {
            case .readable:
                "device-fixture-0001"
            case .missing:
                nil
            case .emptyId:
                ""
            }
        }
    }

    var installSecret: String? {
        lock.withLock { () -> String? in
            mode == .missing ? nil : "test-only.install.device-a"
        }
    }

    func set(_ next: Mode) {
        lock.withLock { mode = next }
    }
}

/// FU-IOS-WITHDRAW-REQUIRES-DEVICE-ID（编排 D10-1940 ③，三端统一口径）调用点：隐私中心撤回隐私同意（AppMe.withdrawConsent）在确认时
/// 只以 `deviceRegistered()`（`me.deviceId` 闭包）为发送前提；确认之后、外层 Task 发送之前网络层读到的设备凭据变得读不出时，
/// POST /v1/consents 零到达（网络层 device_not_ready），本地撤回照常完成（进入基本模式、`deps.withdraw.busy == false`）。
///
/// 夹具：MeAppFixture.make 的设备替身是私有的固定值（`MeAppFixture.Device`），做不到「只让设备凭据读不出、会话照常」；这里在本文件里
/// 按 MeAppFixture.make 同一接线（逐行照抄，只把 `device:` 换成可切换的替身）组一个 MeAppFixture——不改已有夹具。
/// 时序同 LockIosConsentWithdrawIdentityUnknownTests：测试与外层 Task 同在主 actor，`withdrawConsent` 返回后、外层 Task 开始前插入故障；
/// 本地撤回在发送结束之后才做，所以「进入基本模式」时发送一定已经结束，可直接数请求。
@MainActor
final class FuIosWithdrawRequiresDeviceIdTests: MeTestCase {
    // MARK: - 1. 确认后设备凭据读不出 → 零发送，本地撤回照常完成

    /// A1. 普通会员（会话照常可读）：确认撤回时设备已注册；`withdrawConsent` 返回后设备凭据读不出（没有 device_id / install_secret）→
    /// POST /v1/consents 零到达；本地撤回照常完成（基本模式、busy 复位、身份降为 basic）。
    func testMemberWithdrawSendsNothingWhenDeviceBecomesUnreadable() async {
        await assertMemberWithdrawSendsNothing(after: .missing)
    }

    /// A1b. 同 A1，但确认后 device_id 变成空串（网络层按读不出处理）。
    func testMemberWithdrawSendsNothingWhenDeviceIdBecomesEmpty() async {
        await assertMemberWithdrawSendsNothing(after: .emptyId)
    }

    private func assertMemberWithdrawSendsNothing(
        after mode: WithdrawSwitchableDevice.Mode, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let device = WithdrawSwitchableDevice()
        let fixture = makeWithDevice(device)
        let identity = fixture.me.computeIdentity()
        XCTAssertEqual(identity.request?.account, "user-a", "前提：普通会员", file: file, line: line)
        XCTAssertTrue(fixture.me.isCurrent(identity), "前提：确认时身份已确认", file: file, line: line)
        XCTAssertTrue(fixture.me.deviceRegistered(), "前提：确认时设备已注册", file: file, line: line)

        fixture.me.withdrawConsent(identity)
        // 确认生效的同步入口已经走完；之后网络层读设备凭据一律读不出（会话照常可读），撤回记录在外层 Task 里组请求
        device.set(mode)
        await waitUntil("没进基本模式", file: file, line: line) { fixture.me.privacy.state.decision == .basicMode }

        XCTAssertTrue(
            requests("POST", "/v1/consents").isEmpty, "设备凭据读不出：不发不带 X-Device-Id 的撤回记录",
            file: file, line: line
        )
        XCTAssertFalse(fixture.me.deps.withdraw.busy, "本地撤回已完成", file: file, line: line)
        XCTAssertEqual(fixture.me.currentIdentity.level, MeLevel.basic, file: file, line: line)
    }

    /// A1'. 游客（设备已注册）：同样确认后设备凭据读不出 → 零到达，本地撤回照常完成。
    func testGuestWithdrawSendsNothingWhenDeviceBecomesUnreadable() async {
        let device = WithdrawSwitchableDevice()
        let fixture = makeWithDevice(device, account: nil)
        let identity = fixture.me.computeIdentity()
        XCTAssertEqual(identity.level, MeLevel.guest, "前提：游客")
        XCTAssertTrue(fixture.me.isCurrent(identity), "前提：确认时身份已确认")

        fixture.me.withdrawConsent(identity)
        device.set(.missing)
        await waitUntil("没进基本模式") { fixture.me.privacy.state.decision == .basicMode }

        XCTAssertTrue(requests("POST", "/v1/consents").isEmpty, "设备凭据读不出：零发送")
        XCTAssertFalse(fixture.me.deps.withdraw.busy, "本地撤回已完成")
    }

    // MARK: - 2. 对照：不插故障照发 1 条

    /// A2. 对照（游客，同 LockIosConsentWithdrawIdentityUnknownTests.testGuestRegisteredWithdrawSendsDeviceLevel）：不插故障 →
    /// 照发 1 条，设备级（assertDeviceLevelWithdraw 同判据：带 X-Device-Id、不带 Authorization 与签名头、请求体是隐私撤回）。
    /// 同时证明本文件组的夹具与 MeAppFixture.make 等价（可切换替身在可读时与原 Device 同值）。
    func testGuestWithdrawWithReadableDeviceSendsDeviceLevel() async throws {
        let fixture = makeWithDevice(WithdrawSwitchableDevice(), account: nil)
        let identity = fixture.me.computeIdentity()
        XCTAssertEqual(identity.level, MeLevel.guest, "前提：游客")

        fixture.me.withdrawConsent(identity)
        await waitUntil("没进基本模式") { fixture.me.privacy.state.decision == .basicMode }

        let consents = requests("POST", "/v1/consents")
        XCTAssertEqual(consents.count, 1, "设备凭据可读：照发")
        assertDeviceLevelWithdraw(try XCTUnwrap(consents.first))
        XCTAssertFalse(fixture.me.deps.withdraw.busy, "本地撤回已完成")
    }

    /// A2'. 对照（普通会员）：不插故障 → 照发 1 条、带 X-Device-Id、不带签名头、请求体是隐私撤回。会员会话可读时 Authorization 按现状
    /// （recordConsent x-auth=optional，有令牌就带），本用例不断言它（不属于本任务口径）。
    func testMemberWithdrawWithReadableDeviceSendsOnceWithDeviceId() async throws {
        let fixture = makeWithDevice(WithdrawSwitchableDevice())
        let identity = fixture.me.computeIdentity()
        XCTAssertTrue(fixture.me.isCurrent(identity), "前提：确认时身份已确认")

        fixture.me.withdrawConsent(identity)
        await waitUntil("没进基本模式") { fixture.me.privacy.state.decision == .basicMode }

        let consents = requests("POST", "/v1/consents")
        XCTAssertEqual(consents.count, 1, "设备凭据可读：照发")
        let sent = try XCTUnwrap(consents.first)
        XCTAssertEqual(sent.header(HeaderNames.deviceId), "device-fixture-0001", "设备级")
        for name in HeaderNames.signature {
            XCTAssertNil(sent.header(name), "x-signed=false：不带 \(name)")
        }
        XCTAssertEqual(sent.json["type"] as? String, "privacy")
        XCTAssertEqual(sent.json["accepted"] as? Bool, false)
        XCTAssertFalse(fixture.me.deps.withdraw.busy, "本地撤回已完成")
    }

    // MARK: - 夹具与判据

    /// 设备级撤回记录（同 LockIosConsentWithdrawIdentityUnknownTests.assertDeviceLevelWithdraw，那边是 private，照抄判据）。
    private func assertDeviceLevelWithdraw(
        _ sent: WalletStubProtocol.Recorded, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNil(sent.header(HeaderNames.authorization), "设备级、不带令牌", file: file, line: line)
        XCTAssertEqual(sent.header(HeaderNames.deviceId), "device-fixture-0001", "设备级", file: file, line: line)
        for name in HeaderNames.signature {
            XCTAssertNil(sent.header(name), "x-signed=false：不带 \(name)", file: file, line: line)
        }
        XCTAssertEqual(sent.json["type"] as? String, "privacy", file: file, line: line)
        XCTAssertEqual(sent.json["accepted"] as? Bool, false, file: file, line: line)
        XCTAssertEqual(sent.json["channel"] as? String, "privacy_center", file: file, line: line)
    }

    /// 前半段接线（会话令牌、隐私决定、撤回 / 切环境清理名单、AppNetwork）的产物，交给后半段组装。
    private struct NetworkWiring {
        let tokens: MemorySessionTokens
        let privacyStore: MemoryPrivacyStore
        let withdrawal: EnvironmentSwitchCleanerRegistry
        let environmentSwitch: EnvironmentSwitchCleanerRegistry
        let runner: WithdrawalCleanupRunner
        let push: TestPushSource
        let store: CountingSessionTokens
        let network: AppNetwork
    }

    /// MeAppFixture.make 的同一接线（MeAppFixture.swift 76–130，缺省参数：scope full、decision consented、registered true、
    /// 无推送令牌、更新检查 ok、phoneKnown true），只把 AppNetwork 的 `device:` 换成 `device`。为满足函数体长度拆成前后两段，
    /// 语句顺序与原接线一致。
    private func makeWithDevice(_ device: WithdrawSwitchableDevice, account: String? = "user-a") -> MeAppFixture {
        assembleFixture(wireNetwork(device, account: account), account: account)
    }

    /// 前半段：MeAppFixture.swift 81–91。
    private func wireNetwork(_ device: WithdrawSwitchableDevice, account: String?) -> NetworkWiring {
        let tokens = account.map {
            MemorySessionTokens(access: "at-\($0)", refresh: "rt-\($0)", scope: "full", account: $0)
        } ?? MemorySessionTokens()
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = "consented"
        privacyStore.consentedVersion = "1"
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let runner = WithdrawalCleanupRunner(store: privacyStore, registry: withdrawal)
        let push = TestPushSource(token: nil)
        let store = CountingSessionTokens(tokens)
        let network = AppNetwork(
            tokens: store, pendingBackend: MemoryPendingKeyBackend(), device: device, withdrawalRegistry: withdrawal,
            environmentRegistry: environmentSwitch, credentialsReadable: { runner.credentialsReadable },
            configuration: WalletStubProtocol.configuration()
        )
        return NetworkWiring(
            tokens: tokens, privacyStore: privacyStore, withdrawal: withdrawal, environmentSwitch: environmentSwitch,
            runner: runner, push: push, store: store, network: network
        )
    }

    /// 后半段：MeAppFixture.swift 92–129。
    private func assembleFixture(_ wiring: NetworkWiring, account: String?) -> MeAppFixture {
        let (network, runner, push) = (wiring.network, wiring.runner, wiring.push)
        let (withdrawal, environmentSwitch) = (wiring.withdrawal, wiring.environmentSwitch)
        let update = UpdateFixtures.makeUpdate(checker: StubUpdateChecker(.success(UpdateFixtures.ok)))
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: environmentSwitch)
        let privacy = PrivacyController(
            store: wiring.privacyStore, clock: { 1 }, bundledPolicyVersion: "1", withdrawalRunner: runner,
            pushStart: { push.start() }
        )
        let routing = AppRouting(environment: environment, privacy: privacy, update: update)
        let config = AppConfig(
            client: network.client, file: ClientFile(name: suiteName + ".config.json"),
            environmentRegistry: environmentSwitch
        )
        let login = AppLogin(network: network, routing: routing, update: update)
        network.attach(environment: environment, privacy: privacy, update: update)
        if account != nil {
            login.phone.record(true, generation: network.client.sessionGeneration)
        }
        routing.shellAppeared()
        let localFile = FlakyMeFile(
            ClientFile(name: MeLocalStore.fileName, baseDirectory: MeAppFixture.localDirectory(suiteName))
        )
        let local = MeLocalStore(file: localFile, pending: localFile.sibling(MeLocalStore.pendingFileName))
        let cleaner = MeLocalCleaner(store: local)
        MeLocalCleaner.register(cleaner, withdrawal: withdrawal)
        let system = FakeMeSystem()
        let (nickname, notify, api) = (TestNicknameBackend(), TestNotifyBackend(), CountingMeApi(network.client))
        let me = AppMe(
            network: network, routing: routing, config: config, login: login, update: update, system: system,
            mask: AmountMaskStore(defaults: defaults), local: local, pushSource: push, nickname: nickname,
            notify: notify,
            credentialsReadable: { runner.credentialsReadable }, withdrawalRegistry: withdrawal,
            environmentRegistry: environmentSwitch, api: api
        )
        me.deviceId = { "device-fixture-0001" }
        let clipboard = RecordingClipboard()
        let ledgerStore = MemoryClipboardHashStore()
        me.writer = ClipboardWriter(system: clipboard, ledger: ClipboardWriteLedger(store: ledgerStore))
        return MeAppFixture(
            me: me, routing: routing, tokens: wiring.tokens, store: wiring.store, api: api, network: network,
            login: login, config: config, update: update, privacyStore: wiring.privacyStore, runner: runner,
            withdrawal: withdrawal, environmentSwitch: environmentSwitch, system: system, push: push,
            clipboard: clipboard, ledgerStore: ledgerStore, local: local, localFile: localFile, nickname: nickname,
            notify: notify
        )
    }
}
