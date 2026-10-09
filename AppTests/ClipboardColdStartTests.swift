import ClientCore
import Clipboard
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Privacy
import Router
import Session
import XCTest

/// 已登录冷启动的初始化顺序（编排者补充：Android APP-08 发现登录模块初始化时发布会话状态、剪贴板会话回调反取未构造完的登录单例而循环）。
/// iOS：AppLogin 先于 AppClipboard 构造，剪贴板只在构造之后订阅会话变化（dropFirst），回调只改自己的状态，不取任何单例；状态源闭包捕获
/// 已构造好的对象。这里按生产顺序（AppClipboard.make）组装一个已登录会话的 App，断言不崩、初始为已登录（guest=false），之后的会话变化
/// 经回调作废剪贴板结果。
@MainActor
final class ClipboardColdStartTests: XCTestCase {
    private struct Device: DeviceCredentials {
        var deviceId: String? = "device-fixture"
        var installSecret: String? = "test-only.install.device-a"
    }

    func testLoggedInColdStartWiresSessionCallbackWithoutCycle() throws {
        let suite = "ClipboardColdStartTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = "consented"
        privacyStore.consentedVersion = "1"
        let runner = WithdrawalCleanupRunner(store: privacyStore, registry: withdrawal)
        let network = AppNetwork(
            tokens: tokens, pendingBackend: MemoryPendingKeyBackend(), device: Device(),
            withdrawalRegistry: withdrawal, environmentRegistry: environmentSwitch,
            credentialsReadable: { runner.credentialsReadable }, configuration: AppStubProtocol.configuration()
        )
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: environmentSwitch)
        let privacy = PrivacyController(
            store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1", withdrawalRunner: runner
        )
        let update = UpdateFixtures.makeUpdate()
        let routing = AppRouting(environment: environment, privacy: privacy, update: update)
        let login = AppLogin(network: network, routing: routing, update: update)
        network.attach(environment: environment, privacy: privacy, update: update)
        let config = AppConfig(
            client: network.client, file: ClientFile(name: suite + ".json"),
            environmentRegistry: EnvironmentSwitchCleanerRegistry(cleaners: [])
        )
        // 已登录会话先发布一次（模拟登录模块初始化时的会话通知），再按生产顺序组装剪贴板
        routing.sessionStateChanged(resumePending: false)
        let records = ClipboardRecordsCleaner(store: ClipboardFileStore(
            file: ClientFile(name: "records.json", baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(suite))
        ))
        let system = FakeSystemClipboard()
        let clipboard = AppClipboard.make(
            network: network, routing: routing, privacy: privacy, config: config, login: login,
            system: system, records: records
        )
        login.clipboard = clipboard
        XCTAssertTrue(login.loggedIn, "已登录冷启动")
        clipboard.sceneActive()
        // 已登录粘贴纯邀请内容静默（G01）：说明 guest 状态源取到的是已构造好的登录模块
        clipboard.pasted(entry: ManualPasteAction.entryHome, text: "普通文字，没有链接")
        XCTAssertNotNil(clipboard.result)
        // 之后的会话变化经回调同步作废结果
        routing.sessionStateChanged(resumePending: false)
        XCTAssertNil(clipboard.result, "会话变化作废剪贴板结果")
        XCTAssertNotNil(login.pageConfig(restricted: false).invitePaste, "登录页拿得到邀请码【粘贴】")
    }
}
