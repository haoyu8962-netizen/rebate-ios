import ClientCore
import Clipboard
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Privacy
import Router
import XCTest

/// FU-X-CLIP-DEFAULT-ON-ios（BR-ID-16 2026-10-30；brief §1 C1、C5、C6、C7、C9，§2.2）的 App 接线：真实 AppClipboard 生命周期入口
/// （sceneActive / sceneBackground）、真实 Router，本地假系统剪贴板（可挂起 detectPatterns）与假 parse 服务。
///
/// 接线约定（交回 §5）：
/// - `AppClipboard.init(…, autoSwitch: ClipboardAutoSwitch = <内存存储，从未选择>)`：最后一个参数、带缺省值（既有测试不改）；
///   `clipboard.autoSwitch` 就是这一个实例。开关的任何改动（设置页经它 `set`）都由 AppClipboard 立即生效：关闭时作废提示条、
///   挂起的探测回来不出提示条，之后回前台零探测零请求；手动粘贴照常。
/// - `ClipboardAutoSwitch.makeLive()`（App target）：生产用的开关实例，每次调用都从同一个本机文件读；文件不是
///   clipboard-records.json，撤回同意的清理项（ClipboardRecordsCleaner）与切换账号都不清它。`AppClipboard.make` 用它。
@MainActor
final class ClipDefaultOnWiringTests: XCTestCase {
    static let legacyKey = "couli.clipboard.autoDetect"
    var suiteName = ""
    var defaults: UserDefaults!
    let link = "【淘宝】降噪耳机 https://e.tb.cn/h.Demo01?tk=Sample 「降噪蓝牙耳机」 复制这段话打开"

    override func setUpWithError() throws {
        suiteName = "ClipDefaultOnWiringTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
    }

    struct Rig {
        let clipboard: AppClipboard
        let routing: AppRouting
        let system: HoldSystemClipboard
        let api: FakeParseApi
        let switchStore: MemoryClipboardHashStore
        let autoSwitch: ClipboardAutoSwitch
        let state: ClipboardWiringTests.FakeState
    }

    func make(switchStore: MemoryClipboardHashStore = MemoryClipboardHashStore()) -> Rig {
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = "consented"
        privacyStore.consentedVersion = "1"
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: .init(cleaners: []))
        let privacy = PrivacyController(store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1")
        let routing = AppRouting(environment: environment, privacy: privacy, update: UpdateFixtures.makeUpdate())
        routing.shellAppeared()
        let system = HoldSystemClipboard()
        let api = FakeParseApi()
        let state = ClipboardWiringTests.FakeState()
        let autoSwitch = ClipboardAutoSwitch(store: switchStore)
        let clipboard = AppClipboard(
            system: system, store: MemoryClipboardHashStore(), api: api, router: routing.router,
            deps: AppClipboard.Deps(
                privacy: { state.privacy }, privacyPrompting: { false }, forceUpdate: { false },
                configJson: { state.config }, guest: { state.guest },
                sessionGeneration: { state.session }, networkEpoch: { state.epoch },
                serverForced: { state.forced += 1 },
                networkForced: { state.networkForced.append($0) }
            ),
            autoSwitch: autoSwitch
        )
        clipboard.overlaySource = { state.overlay }
        return Rig(clipboard: clipboard, routing: routing, system: system, api: api, switchStore: switchStore,
                   autoSwitch: autoSwitch, state: state)
    }

    func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    /// 经过后台再回前台，剪贴板内容换过（changeCount 变化）。
    func foregroundWithNewContent(_ rig: Rig) {
        rig.clipboard.sceneBackground()
        rig.system.changeCount += 1
        rig.clipboard.sceneActive()
    }

    // MARK: - C1 默认开启

    func testFreshInstallDefaultOnDetectsAndPromptsWithoutConsentStepC1() {
        let rig = make()
        XCTAssertTrue(rig.clipboard.autoSwitch === rig.autoSwitch, "AppClipboard 用的就是注入的开关实例")
        XCTAssertTrue(rig.clipboard.autoSwitch.isOn, "全新安装、同意隐私政策后开关为开启")
        rig.system.changeCount = 3
        rig.clipboard.sceneActive()
        XCTAssertEqual(rig.system.detectCalls, 1, "回前台按原门槛探测")
        XCTAssertNotNil(rig.clipboard.prompt, "命中直接出提示条，没有用途说明这一步")
        XCTAssertEqual(rig.api.bodies.count, 0, "点击前不上传（iOS 现有口径不变，C9）")
    }

    // MARK: - C5 关闭态

    func testSwitchOffSkipsDetectionZeroUploadsAndManualPasteStillWorksC5() async {
        let rig = make()
        XCTAssertTrue(rig.autoSwitch.set(false))
        rig.system.changeCount = 5
        rig.clipboard.sceneActive()
        foregroundWithNewContent(rig)
        foregroundWithNewContent(rig)
        XCTAssertEqual(rig.system.detectCalls, 0, "关闭后冷启动与回前台都不探测（detectPatterns 也不做）")
        XCTAssertNil(rig.clipboard.prompt)
        XCTAssertEqual(rig.api.bodies.count, 0, "零上传")
        XCTAssertFalse(rig.autoSwitch.isOn, "读取判定不改用户的开关")
        rig.api.reply = .success(card: true)
        rig.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await settle()
        XCTAssertEqual(rig.api.bodies.count, 1, "手动粘贴照常识别（手动任务不看开关）")
        XCTAssertEqual(rig.routing.router.path.last?.route, "ProductDetail")
    }

    func testTurningOffClearsPromptAndVoidsPendingDetectionThenOnReadsNextRoundC5() {
        let rig = make()
        rig.system.changeCount = 1
        rig.clipboard.sceneActive()
        XCTAssertNotNil(rig.clipboard.prompt, "开着时命中出提示条")
        XCTAssertTrue(rig.autoSwitch.set(false))
        XCTAssertNil(rig.clipboard.prompt, "关闭立即作废自动识别出的提示条")

        // 挂起的探测：回前台已发起 detectPatterns，结果回来之前用户关掉开关
        XCTAssertTrue(rig.autoSwitch.set(true))
        rig.system.hold = true
        foregroundWithNewContent(rig)
        XCTAssertEqual(rig.system.detectCalls, 2)
        XCTAssertTrue(rig.autoSwitch.set(false))
        rig.system.release()
        XCTAssertNil(rig.clipboard.prompt, "关闭后迟到的探测结果不出提示条")
        rig.system.hold = false
        foregroundWithNewContent(rig)
        XCTAssertEqual(rig.system.detectCalls, 2, "关闭期间不再探测")
        XCTAssertEqual(rig.api.bodies.count, 0)

        XCTAssertTrue(rig.autoSwitch.set(true))
        foregroundWithNewContent(rig)
        XCTAssertEqual(rig.system.detectCalls, 3, "重新打开后下一次回前台照常探测")
        XCTAssertNotNil(rig.clipboard.prompt)
    }

    func testConfigCanOnlyTurnOffAndNeverChangesUserSwitchC5() {
        let rig = make()
        rig.state.config = #"{"features":{"flags":{"clipboard.enabled.ios":false}}}"#
        rig.system.changeCount = 1
        rig.clipboard.sceneActive()
        XCTAssertEqual(rig.system.detectCalls, 0, "服务端按端停用：不读")
        XCTAssertTrue(rig.autoSwitch.isOn, "配置不改用户开关值")
        rig.state.config = #"{"features":{"flags":{"clipboard.enabled.ios":true}}}"#
        XCTAssertTrue(rig.autoSwitch.set(false))
        foregroundWithNewContent(rig)
        XCTAssertEqual(rig.system.detectCalls, 0, "配置为开也不能把用户的关闭态改为开启")
        XCTAssertFalse(rig.autoSwitch.isOn)
    }

    func testOffStateSurvivesRestartC5() {
        let store = MemoryClipboardHashStore()
        let first = make(switchStore: store)
        XCTAssertTrue(first.autoSwitch.set(false))
        // 杀进程重启：新的 AppClipboard 与开关实例读同一份本机存储
        let second = make(switchStore: store)
        XCTAssertFalse(second.clipboard.autoSwitch.isOn, "重启后仍关闭")
        second.system.changeCount = 9
        second.clipboard.sceneActive()
        XCTAssertEqual(second.system.detectCalls, 0, "重启后冷启动不读")
    }

    // MARK: - C6 迁移

    func testLegacyAutoDetectDefaultsKeyDoesNotAffectSwitchC6() {
        // APP-04（2026-10-07～10-10）H5 桥 clipboard.setAutoDetect 写过的 UserDefaults 键；APP-07 起不再读写（AppBridgeServices 注释）
        UserDefaults.standard.set(false, forKey: Self.legacyKey)
        let rig = make()
        XCTAssertTrue(rig.clipboard.autoSwitch.isOn, "旧键遗留 false 不等于用户关闭：从未选择 → 开启")
        rig.system.changeCount = 2
        rig.clipboard.sceneActive()
        XCTAssertEqual(rig.system.detectCalls, 1)
        XCTAssertTrue(rig.autoSwitch.set(false))
        UserDefaults.standard.set(true, forKey: Self.legacyKey)
        XCTAssertFalse(make(switchStore: rig.switchStore).clipboard.autoSwitch.isOn, "旧键为 true 也不把关闭态改回开启")
    }

    // MARK: - C7 撤回与重新同意

    func testWithdrawReadsNothingAndReconsentKeepsUserOffC7() {
        let rig = make()
        XCTAssertTrue(rig.autoSwitch.set(false))
        rig.state.privacy = .basicMode
        rig.clipboard.privacyChanged(.basicMode)
        foregroundWithNewContent(rig)
        XCTAssertEqual(rig.system.detectCalls, 0, "基本模式不读")
        rig.state.privacy = .consented
        rig.clipboard.privacyChanged(.consented)
        XCTAssertFalse(rig.clipboard.autoSwitch.isOn, "重新同意：此前在设置关闭过的仍关闭")
        foregroundWithNewContent(rig)
        XCTAssertEqual(rig.system.detectCalls, 0)
    }

    func testWithdrawThenReconsentNeverTouchedIsOnAndReadsC7() {
        let rig = make()
        rig.system.changeCount = 1
        rig.state.privacy = .basicMode
        rig.clipboard.privacyChanged(.basicMode)
        rig.clipboard.sceneActive()
        XCTAssertEqual(rig.system.detectCalls, 0, "基本模式不读")
        rig.state.privacy = .consented
        rig.clipboard.privacyChanged(.consented)
        XCTAssertTrue(rig.clipboard.autoSwitch.isOn, "重新同意后回到默认开启")
        foregroundWithNewContent(rig)
        XCTAssertEqual(rig.system.detectCalls, 1)
        XCTAssertNotNil(rig.clipboard.prompt)
    }

    func testLiveSwitchPersistsAndSurvivesWithdrawalRecordsCleanerC5C7() throws {
        XCTAssertTrue(ClipboardAutoSwitch.makeLive().set(false))
        defer { _ = ClipboardAutoSwitch.makeLive().set(true) }
        XCTAssertFalse(ClipboardAutoSwitch.makeLive().isOn, "生产实例：重启（重新读本机文件）后仍关闭")
        // 撤回同意的清理项：删掉剪贴板 hash 记录文件；关闭态是设备级设置，本机保留（BR-ID-16「关闭态本机保留」）
        try ClipboardRecordsCleaner.shared.cleanForEnvironmentSwitch()
        XCTAssertFalse(ClipboardAutoSwitch.makeLive().isOn, "撤回清理之后仍关闭")
        XCTAssertTrue(ClipboardAutoSwitch.makeLive().set(true))
        XCTAssertTrue(ClipboardAutoSwitch.makeLive().isOn)
    }
}

/// 假系统剪贴板：可把 detectPatterns 的结果挂起，模拟「已发起探测、结果还没回来」。
@MainActor
final class HoldSystemClipboard: SystemClipboard {
    var changeCount = 0
    var detectHit = true
    var hold = false
    private(set) var detectCalls = 0
    private var pending: [@MainActor (Bool) -> Void] = []

    func detectLink(_ completion: @escaping @MainActor (Bool) -> Void) {
        detectCalls += 1
        if hold {
            pending.append(completion)
        } else {
            completion(detectHit)
        }
    }

    func release() {
        let waiting = pending
        pending = []
        for completion in waiting {
            completion(detectHit)
        }
    }

    func write(_: String) {
        changeCount += 1
    }
}
