#if DEBUG
import ClientCore
import Clipboard
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Privacy
import Router
import XCTest

/// FU-IOS-CLIP-DIAG-REASON（D10-1640 (2)）：Debug 剪贴板调试计数 `debugDiagnostics` 的 ` last=<event>:<outcome>`。
/// 经真实生命周期入口（sceneActive / sceneBackground）与 Router 逐个分支驱动自动识别判定，断言 last= 的值，同时断言产品行为与改动前一致
/// （提示条、detectCount / detectPatterns 次数、ios_change_seen 是否写、本轮是否已判定）。另断言：初始 last=none；旧轮迟到的探测回调
/// 不覆盖新一轮的记录；文本不含剪贴板内容与 changeCount 数字。
/// 不覆盖：home_visual（DebugHomeVisual.shared 只能由启动参数 bootstrap，且会装网络拦截，宿主测试里不造）；stale_background（进后台
/// 必然先让 watcher.round 加 1，复核按 guard 顺序总是先落到 stale_round，生产与测试都到不了）。
@MainActor
final class ClipboardDiagReasonTests: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    let link = "【淘宝】降噪耳机 https://e.tb.cn/h.Demo01?tk=Sample 「降噪蓝牙耳机」 复制这段话打开"

    override func setUpWithError() throws {
        suiteName = "ClipboardDiagReasonTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    struct Rig {
        let clipboard: AppClipboard
        let routing: AppRouting
        let system: DiagReasonSystemClipboard
        let store: MemoryClipboardHashStore
        let autoSwitch: ClipboardAutoSwitch
        let state: ClipboardWiringTests.FakeState

        var diagnostics: String {
            clipboard.debugDiagnostics
        }

        /// ` last=` 之后的部分。
        var last: String {
            guard let range = diagnostics.range(of: " last=") else { return "<missing last=>" }
            return String(diagnostics[range.upperBound...])
        }

        var changeSeen: String? {
            store.read(AppClipboard.lastChangeKey)
        }

        var consumed: Bool {
            clipboard.watcher.readThisForeground
        }
    }

    func make() -> Rig {
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = "consented"
        privacyStore.consentedVersion = "1"
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: .init(cleaners: []))
        let privacy = PrivacyController(store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1")
        let routing = AppRouting(environment: environment, privacy: privacy, update: UpdateFixtures.makeUpdate())
        routing.shellAppeared()
        let system = DiagReasonSystemClipboard()
        let store = MemoryClipboardHashStore()
        let state = ClipboardWiringTests.FakeState()
        let autoSwitch = ClipboardAutoSwitch(store: MemoryClipboardHashStore())
        let clipboard = AppClipboard(
            system: system, store: store, api: FakeParseApi(), router: routing.router,
            deps: AppClipboard.Deps(
                privacy: { state.privacy }, privacyPrompting: { false }, forceUpdate: { false },
                configJson: { state.config }, guest: { state.guest },
                sessionGeneration: { state.session }, networkEpoch: { state.epoch }
            ),
            autoSwitch: autoSwitch
        )
        clipboard.overlaySource = { state.overlay }
        return Rig(clipboard: clipboard, routing: routing, system: system, store: store, autoSwitch: autoSwitch,
                   state: state)
    }

    func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    // MARK: - 初始、格式、不含内容

    func testInitialIsNoneAndCountsSectionUnchanged() {
        let rig = make()
        XCTAssertEqual(rig.diagnostics, "detect=0 parse=0 writes=0 last=none", "还没判定过：last=none，计数段格式不变")
    }

    func testHitAndTextHasNoContentNorChangeCount() async throws {
        let rig = make()
        rig.system.changeCount = 987_654
        rig.clipboard.sceneActive()
        let prompt = try XCTUnwrap(rig.clipboard.prompt, "命中出提示条")
        XCTAssertEqual(rig.last, "cold_start_foreground:hit")
        XCTAssertEqual(rig.clipboard.detectCount, 1)
        XCTAssertEqual(rig.system.detectCalls, 1)
        XCTAssertEqual(rig.changeSeen, "987654", "ios_change_seen 照常写")
        XCTAssertTrue(rig.consumed)
        XCTAssertTrue(rig.diagnostics.hasPrefix("detect=1 parse=0 writes=0 last="))
        // 用户点系统粘贴控件交回正文、发 parse：计数文本里也不出现正文
        rig.clipboard.promptPasted(prompt.id, text: link)
        await settle()
        let text = rig.diagnostics
        XCTAssertTrue(text.hasPrefix("detect=1 parse=1 writes=0 last="), text)
        for fragment in ["987654", "e.tb.cn", "Demo01", "Sample", "淘宝", "降噪"] {
            XCTAssertFalse(text.contains(fragment), "计数文本不含剪贴板内容与 changeCount：\(fragment) in \(text)")
        }
    }

    // MARK: - evaluate 的返回点

    func testNoHit() {
        let rig = make()
        rig.system.changeCount = 3
        rig.system.detectHit = false
        rig.clipboard.sceneActive()
        XCTAssertNil(rig.clipboard.prompt)
        XCTAssertEqual(rig.clipboard.detectCount, 1)
        XCTAssertEqual(rig.changeSeen, "3")
        XCTAssertEqual(rig.last, "cold_start_foreground:no_hit")
    }

    func testDetectingWhileHeldThenHit() {
        let rig = make()
        rig.system.changeCount = 2
        rig.system.hold = true
        rig.clipboard.sceneActive()
        XCTAssertEqual(rig.last, "cold_start_foreground:detecting", "已发起 detectPatterns、结果没回来")
        XCTAssertEqual(rig.clipboard.detectCount, 1)
        XCTAssertNil(rig.clipboard.prompt)
        XCTAssertEqual(rig.changeSeen, "2")
        XCTAssertTrue(rig.consumed)
        rig.system.releaseAll()
        XCTAssertNotNil(rig.clipboard.prompt)
        XCTAssertEqual(rig.last, "cold_start_foreground:hit")
    }

    func testUnchangedWritesChangeSeenWithoutDetect() {
        let rig = make()
        rig.system.changeCount = 3
        rig.system.detectHit = false
        rig.clipboard.sceneActive()
        rig.clipboard.sceneBackground()
        rig.system.detectHit = true
        rig.clipboard.sceneActive()
        XCTAssertEqual(rig.last, "foreground_after_background:unchanged")
        XCTAssertEqual(rig.system.detectCalls, 1, "changeCount 没变不再探测")
        XCTAssertEqual(rig.clipboard.detectCount, 1)
        XCTAssertEqual(rig.changeSeen, "3")
        XCTAssertTrue(rig.consumed)
        XCTAssertNil(rig.clipboard.prompt)
    }

    func testNotHomeRootWritesChangeSeenAndNoCatchUp() {
        let rig = make()
        rig.system.changeCount = 4
        rig.routing.router.path = [RouteDestination(route: AppClipboard.productDetailRoute)]
        rig.clipboard.sceneActive()
        XCTAssertEqual(rig.last, "cold_start_foreground:not_home_root")
        XCTAssertEqual(rig.system.detectCalls, 0)
        XCTAssertEqual(rig.clipboard.detectCount, 0)
        XCTAssertEqual(rig.changeSeen, "4", "策略让探测：ios_change_seen 在首页根页判断之前写")
        XCTAssertTrue(rig.consumed)
        rig.routing.router.path = []
        XCTAssertNil(rig.clipboard.prompt, "回到首页不补做")
        XCTAssertEqual(rig.system.detectCalls, 0)
        XCTAssertEqual(rig.last, "cold_start_foreground:not_home_root", "导航不产生新的判定")
    }

    func testSelfWrittenSkipsDetect() {
        let rig = make()
        XCTAssertTrue(rig.clipboard.writer.write(link))
        rig.clipboard.sceneActive()
        XCTAssertEqual(rig.last, "cold_start_foreground:self_written")
        XCTAssertEqual(rig.system.detectCalls, 0)
        XCTAssertEqual(rig.clipboard.detectCount, 0)
        XCTAssertEqual(rig.changeSeen, "1")
        XCTAssertNil(rig.clipboard.prompt)
    }

    /// 读取策略在探测前就跳过：last= 记 reasonRaw；不探测、不写 ios_change_seen、本轮照常算读过。
    func assertPolicySkip(_ reason: String, file: StaticString = #filePath, line: UInt = #line,
                          prepare: (Rig) -> Void) {
        let rig = make()
        rig.system.changeCount = 5
        prepare(rig)
        rig.clipboard.sceneActive()
        XCTAssertEqual(rig.last, "cold_start_foreground:" + reason, file: file, line: line)
        XCTAssertEqual(rig.system.detectCalls, 0, reason, file: file, line: line)
        XCTAssertEqual(rig.clipboard.detectCount, 0, reason, file: file, line: line)
        XCTAssertNil(rig.changeSeen, "\(reason)：不写 ios_change_seen", file: file, line: line)
        XCTAssertTrue(rig.consumed, reason, file: file, line: line)
        XCTAssertNil(rig.clipboard.prompt, reason, file: file, line: line)
    }

    func testPolicySkipReasons() {
        assertPolicySkip(ClipboardReadPolicy.reasonSensitive) { rig in
            rig.routing.router.path = [RouteDestination(route: AppClipboard.loginRoute)]
        }
        assertPolicySkip(ClipboardReadPolicy.reasonSensitive) { rig in
            rig.state.overlay = ClipboardSensitive.overlayAuthSheet
        }
        assertPolicySkip(ClipboardReadPolicy.reasonBasicMode) { rig in
            rig.state.privacy = .basicMode
        }
        assertPolicySkip(ClipboardReadPolicy.reasonPrivacyOutdated) { rig in
            rig.state.privacy = .notDecided
        }
        assertPolicySkip(ClipboardReadPolicy.reasonConfigOff) { rig in
            rig.state.config = #"{"features":{"flags":{"clipboard.enabled.ios":false}}}"#
        }
        assertPolicySkip(ClipboardReadPolicy.reasonWebSuppressed) { rig in
            let page = RouteDestination(route: "WebPage")
            rig.routing.router.path = [page]
            rig.clipboard.setWebAutoDetect(container: page.id, enabled: false)
        }
        assertPolicySkip(ClipboardReadPolicy.reasonSwitchOff) { rig in
            XCTAssertTrue(rig.autoSwitch.set(false))
        }
    }

    /// already_read / not_foreground：iOS 的 watcher 只会以冷启动、回前台两个事件且本轮未判定时调 evaluate，生命周期入口驱动不到；
    /// 这里直接调 evaluate 只验证落点映射（判定照常跳过、不探测、不动已有提示条）。
    func testAlreadyReadAndNotForegroundByDirectEvaluate() throws {
        let rig = make()
        rig.system.changeCount = 6
        rig.clipboard.sceneActive()
        let prompt = try XCTUnwrap(rig.clipboard.prompt)
        let round = rig.clipboard.watcher.round
        rig.clipboard.evaluate(event: ClipboardReadPolicy.eventForeground, round: round)
        XCTAssertEqual(rig.last, "foreground_after_background:already_read")
        rig.clipboard.evaluate(event: ClipboardReadPolicy.eventRefocus, round: round)
        XCTAssertEqual(rig.last, "refocus_without_background:not_foreground")
        XCTAssertEqual(rig.system.detectCalls, 1)
        XCTAssertEqual(rig.clipboard.detectCount, 1)
        XCTAssertEqual(rig.clipboard.prompt?.id, prompt.id, "跳过不动已有提示条")
        XCTAssertEqual(rig.changeSeen, "6")
    }
}

// MARK: - detected 的返回点、旧轮迟到

extension ClipboardDiagReasonTests {
    /// 冷启动发起探测并挂起，`change` 之后放行：last= 应为 `outcome`；不出提示条、detectCount 仍为 1。
    func assertHeld(_ outcome: String, file: StaticString = #filePath, line: UInt = #line, change: (Rig) -> Void) {
        let rig = make()
        rig.system.changeCount = 8
        rig.system.hold = true
        rig.clipboard.sceneActive()
        XCTAssertEqual(rig.last, "cold_start_foreground:detecting", file: file, line: line)
        change(rig)
        rig.system.releaseAll()
        XCTAssertEqual(rig.last, "cold_start_foreground:" + outcome, file: file, line: line)
        XCTAssertNil(rig.clipboard.prompt, outcome, file: file, line: line)
        XCTAssertEqual(rig.clipboard.detectCount, 1, outcome, file: file, line: line)
        XCTAssertEqual(rig.system.detectCalls, 1, outcome, file: file, line: line)
        XCTAssertEqual(rig.changeSeen, "8", outcome, file: file, line: line)
    }

    func testDetectedStaleOutcomes() {
        // 探测期间进了后台（没回来）：round 已变
        assertHeld(DebugClipboardEvaluation.staleRound) { rig in
            rig.clipboard.sceneBackground()
        }
        // 推入页面再返回首页：首页世代换代
        assertHeld(DebugClipboardEvaluation.staleHomeGen) { rig in
            rig.routing.router.path = [RouteDestination(route: AppClipboard.productDetailRoute)]
            rig.routing.router.path = []
        }
        // 隐私状态已变、还没经 privacyChanged 通知（homeGen 未换代）：首页根页不成立
        assertHeld(DebugClipboardEvaluation.staleNotHomeRoot) { rig in
            rig.state.privacy = .notDecided
        }
        // 敏感浮层出现（overlaySource 现取，未经 sensitiveOverlayShown 换代）
        assertHeld(DebugClipboardEvaluation.staleOverlay) { rig in
            rig.state.overlay = ClipboardSensitive.overlayAuthSheet
        }
        // 剪贴板又变了
        assertHeld(DebugClipboardEvaluation.staleChange) { rig in
            rig.system.changeCount += 1
        }
    }

    func testDetectedLateOutcomes() {
        assertHeld("late_" + ClipboardReadPolicy.reasonSwitchOff) { rig in
            XCTAssertTrue(rig.autoSwitch.set(false))
        }
        assertHeld("late_" + ClipboardReadPolicy.reasonConfigOff) { rig in
            rig.state.config = #"{"features":{"flags":{"clipboard.enabled.ios":false}}}"#
        }
    }

    func testOldRoundLateCallbackDoesNotOverwriteNewUnchangedRound() {
        let rig = make()
        rig.system.changeCount = 8
        rig.system.hold = true
        rig.clipboard.sceneActive()
        rig.clipboard.sceneBackground()
        rig.clipboard.sceneActive()
        XCTAssertEqual(rig.last, "foreground_after_background:unchanged")
        rig.system.releaseAll()
        XCTAssertEqual(rig.last, "foreground_after_background:unchanged", "旧轮迟到的回调不覆盖新一轮")
        XCTAssertNil(rig.clipboard.prompt)
        XCTAssertEqual(rig.clipboard.detectCount, 1)
    }

    func testOldRoundLateCallbackDoesNotOverwriteNewSkippedRound() {
        let rig = make()
        rig.system.changeCount = 8
        rig.system.hold = true
        rig.clipboard.sceneActive()
        rig.clipboard.sceneBackground()
        XCTAssertTrue(rig.autoSwitch.set(false))
        rig.system.changeCount += 1
        rig.clipboard.sceneActive()
        XCTAssertEqual(rig.last, "foreground_after_background:switch_off")
        rig.system.releaseAll()
        XCTAssertEqual(rig.last, "foreground_after_background:switch_off", "旧轮迟到的回调不覆盖新一轮")
        XCTAssertNil(rig.clipboard.prompt)
        XCTAssertEqual(rig.system.detectCalls, 1)
    }

    func testOldRoundLateCallbackDoesNotOverwriteNewDetectingRound() {
        let rig = make()
        rig.system.changeCount = 8
        rig.system.hold = true
        rig.clipboard.sceneActive()
        rig.clipboard.sceneBackground()
        rig.system.changeCount += 1
        rig.clipboard.sceneActive()
        XCTAssertEqual(rig.last, "foreground_after_background:detecting")
        XCTAssertEqual(rig.system.detectCalls, 2)
        XCTAssertEqual(rig.clipboard.detectCount, 2)
        rig.system.releaseFirst()
        XCTAssertEqual(rig.last, "foreground_after_background:detecting", "旧轮迟到的回调不覆盖新一轮")
        XCTAssertNil(rig.clipboard.prompt, "旧轮回调不出提示条")
        rig.system.releaseAll()
        XCTAssertEqual(rig.last, "foreground_after_background:hit")
        XCTAssertNotNil(rig.clipboard.prompt)
        XCTAssertFalse(rig.diagnostics.contains("9"), "不含 changeCount：\(rig.diagnostics)")
    }
}

/// 假系统剪贴板：changeCount 可设、detectPatterns 可挂起并逐个按发起顺序放行（模拟旧轮回调迟到）；写入 changeCount 加 1。
@MainActor
final class DiagReasonSystemClipboard: SystemClipboard {
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

    /// 只放行最早发起的那一次。
    func releaseFirst() {
        guard !pending.isEmpty else { return }
        pending.removeFirst()(detectHit)
    }

    func releaseAll() {
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
#endif
