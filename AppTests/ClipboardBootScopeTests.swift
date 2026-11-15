import ClientCore
import Clipboard
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Privacy
import Router
import XCTest

/// FU-IOS-CLIP-COLDSTART-MISSED（D10-1753）自动识别接线：经真实生命周期入口（sceneActive）与写入口（writer.write），
/// 注入开机标识（同一存储上新建实例 = 重启后的新进程；可变标识 = 同一实例内先 A 后 B）。断言 detectPatterns 次数、提示条、
/// 提示条粘贴后的 parse 次数与本地 30132 提示。手动粘贴与记录清理见 ClipboardBootScopeManualTests。
@MainActor
final class ClipboardBootScopeTests: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "ClipboardBootScopeTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func rig(_ store: ClipboardHashStore, boot: String?) -> BootRig {
        BootRig.make(defaults: defaults, store: store, boot: { boot })
    }

    func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    // MARK: - 1 换开机标识后旧自写计数不判自写

    func testSelfWriteCountFromPreviousBootIsDetectedAgain() {
        let store = MemoryClipboardHashStore()
        let before = rig(store, boot: "boot-A")
        XCTAssertTrue(before.clipboard.writer.write(BootRig.link))
        let after = rig(store, boot: "boot-B")
        after.system.changeCount = before.system.changeCount
        after.system.detectHit = true
        after.clipboard.sceneActive()
        XCTAssertEqual(after.system.detectCalls, 1, "重启后同一计数照常调 detectPatterns")
        XCTAssertNotNil(after.clipboard.prompt)
    }

    func testBootChangesWithinSameInstanceVoidsSelfWriteCount() {
        let boot = AppTestBoot("boot-A")
        let fixture = BootRig.make(defaults: defaults, store: MemoryClipboardHashStore(), boot: { boot.value })
        XCTAssertTrue(fixture.clipboard.writer.write(BootRig.link))
        boot.value = "boot-B"
        fixture.system.detectHit = true
        fixture.clipboard.sceneActive()
        XCTAssertEqual(fixture.system.detectCalls, 1, "注入 boot 先 A 后 B：同一计数照常探测")
        XCTAssertNotNil(fixture.clipboard.prompt)
    }

    // MARK: - 2 同一次开机内自写后仍跳过

    func testSameBootSelfWriteStillSkipsDetect() {
        let fixture = rig(MemoryClipboardHashStore(), boot: "boot-A")
        XCTAssertTrue(fixture.clipboard.writer.write(BootRig.link))
        fixture.system.detectHit = true
        fixture.clipboard.sceneActive()
        XCTAssertEqual(fixture.system.detectCalls, 0)
        XCTAssertEqual(fixture.clipboard.detectCount, 0)
        XCTAssertNil(fixture.clipboard.prompt)
        #if DEBUG
        XCTAssertTrue(fixture.clipboard.debugDiagnostics.hasSuffix(" last=cold_start_foreground:self_written"),
                      fixture.clipboard.debugDiagnostics)
        #endif
    }

    func testSameBootRelaunchStillSkipsDetect() {
        let store = MemoryClipboardHashStore()
        let before = rig(store, boot: "boot-A")
        XCTAssertTrue(before.clipboard.writer.write(BootRig.link))
        let relaunched = rig(store, boot: "boot-A")
        relaunched.system.changeCount = before.system.changeCount
        relaunched.system.detectHit = true
        relaunched.clipboard.sceneActive()
        XCTAssertEqual(relaunched.system.detectCalls, 0, "同一次开机内重开进程：自写计数照样跳过")
        #if DEBUG
        XCTAssertTrue(relaunched.clipboard.debugDiagnostics.hasSuffix(" last=cold_start_foreground:self_written"),
                      relaunched.clipboard.debugDiagnostics)
        #endif
    }

    // MARK: - 3 等于更早一次（非最近一次）自写计数 → 照常探测

    func testEarlierSelfWriteCountIsDetected() {
        let fixture = rig(MemoryClipboardHashStore(), boot: "boot-A")
        XCTAssertTrue(fixture.clipboard.writer.write(BootRig.otherLink))
        let earlier = fixture.system.changeCount
        XCTAssertTrue(fixture.clipboard.writer.write(BootRig.link))
        let latest = fixture.system.changeCount
        fixture.system.changeCount = earlier
        fixture.system.detectHit = true
        fixture.clipboard.sceneActive()
        XCTAssertEqual(fixture.system.detectCalls, 1, "只认最近一次自写计数")
        XCTAssertNotNil(fixture.clipboard.prompt)
        // 对照：回到最近一次自写计数仍跳过
        fixture.clipboard.sceneBackground()
        fixture.system.changeCount = latest
        fixture.clipboard.sceneActive()
        XCTAssertEqual(fixture.system.detectCalls, 1)
    }

    // MARK: - 4 计数命中但 hash 非自写 → 照常识别

    func testRebootCountMatchButForeignContentParsesOnce() async throws {
        let store = MemoryClipboardHashStore()
        let before = rig(store, boot: "boot-A")
        XCTAssertTrue(before.clipboard.writer.write(BootRig.otherLink))
        let after = rig(store, boot: "boot-B")
        after.system.changeCount = before.system.changeCount
        after.system.detectHit = true
        after.clipboard.sceneActive()
        let prompt = try XCTUnwrap(after.clipboard.prompt, "外部链接出提示条")
        XCTAssertEqual(after.api.bodies.count, 0, "点击前不发请求")
        after.clipboard.promptPasted(prompt.id, text: BootRig.link)
        await settle()
        XCTAssertEqual(after.api.bodies.count, 1, "hash 不是自写：照常 1 次 parse")
        let body = try XCTUnwrap(after.api.bodies.first)
        XCTAssertTrue(body.contains("h.Demo01"))
        XCTAssertFalse(body.contains("Other99"))
    }

    // MARK: - 5 换开机后自写内容出了提示条 → 粘贴按 hash 排除

    func testRebootSelfWrittenPromptPasteExcludedByHash() async throws {
        let store = MemoryClipboardHashStore()
        let before = rig(store, boot: "boot-A")
        XCTAssertTrue(before.clipboard.writer.write(BootRig.link))
        let after = rig(store, boot: "boot-B")
        after.system.changeCount = before.system.changeCount
        after.system.detectHit = true
        after.clipboard.sceneActive()
        let prompt = try XCTUnwrap(after.clipboard.prompt, "换开机后计数作废：照常出提示条")
        after.clipboard.promptPasted(prompt.id, text: BootRig.link)
        await settle()
        XCTAssertEqual(after.api.bodies.count, 0, "读到正文按 hash 排除自写，不上传")
        guard case let .unrecognized(text, _) = after.clipboard.result?.kind else {
            return XCTFail("本地 30132 提示")
        }
        XCTAssertEqual(text, ClipboardDraftTexts.text(ParseResultAction.key(ParseResultAction.unrecognized)))
        XCTAssertEqual(after.system.writes, 0)
    }

    // MARK: - 6 ios_change_seen 跨开机作废

    func testChangeSeenVoidAcrossBoot() {
        let store = MemoryClipboardHashStore()
        let first = rig(store, boot: "boot-A")
        first.system.changeCount = 5
        first.clipboard.sceneActive()
        XCTAssertEqual(first.system.detectCalls, 1)
        XCTAssertEqual(store.read(AppClipboard.lastChangeKey), "5")
        XCTAssertEqual(store.read(AppClipboard.lastChangeKey + ClipboardBootScopedRecord.bootSuffix), "boot-A")
        // 对照：同一次开机重开进程、计数没变 → 不探测
        let relaunched = rig(store, boot: "boot-A")
        relaunched.system.changeCount = 5
        relaunched.system.detectHit = true
        relaunched.clipboard.sceneActive()
        XCTAssertEqual(relaunched.system.detectCalls, 0, "同一次开机：没变化跳过")
        let rebooted = rig(store, boot: "boot-B")
        rebooted.system.changeCount = 5
        rebooted.system.detectHit = true
        rebooted.clipboard.sceneActive()
        XCTAssertEqual(rebooted.system.detectCalls, 1, "换开机：同一计数不判「没变化」")
        XCTAssertNotNil(rebooted.clipboard.prompt)
        XCTAssertEqual(store.read(AppClipboard.lastChangeKey + ClipboardBootScopedRecord.bootSuffix), "boot-B")
    }
}

/// 可注入开机标识的 AppClipboard 组装（与 ClipboardWiringTests.make 同口径，多一个 boot、存储由调用方给）。
@MainActor
struct BootRig {
    static let link = "【淘宝】降噪耳机 https://e.tb.cn/h.Demo01?tk=Sample 「降噪蓝牙耳机」 复制这段话打开"
    /// App 自写的另一条口令（hash 与 link 不同）。
    static let otherLink = "【淘宝】保温杯 https://e.tb.cn/h.Other99?tk=Self 「保温杯」 复制这段话打开"
    static let invite = "邀请码 K7M2QX 快来"

    let clipboard: AppClipboard
    let routing: AppRouting
    let system: FakeSystemClipboard
    let api: FakeParseApi
    let state: ClipboardWiringTests.FakeState

    static func make(defaults: UserDefaults, store: ClipboardHashStore, boot: @escaping () -> String?) -> BootRig {
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = "consented"
        privacyStore.consentedVersion = "1"
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: .init(cleaners: []))
        let privacy = PrivacyController(store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1")
        let routing = AppRouting(environment: environment, privacy: privacy, update: UpdateFixtures.makeUpdate())
        routing.shellAppeared()
        let system = FakeSystemClipboard()
        let api = FakeParseApi()
        let state = ClipboardWiringTests.FakeState()
        let clipboard = AppClipboard(
            system: system, store: store, api: api, router: routing.router,
            deps: AppClipboard.Deps(
                privacy: { state.privacy }, privacyPrompting: { false }, forceUpdate: { false },
                configJson: { state.config }, guest: { state.guest },
                sessionGeneration: { state.session }, networkEpoch: { state.epoch }
            ),
            boot: boot
        )
        return BootRig(clipboard: clipboard, routing: routing, system: system, api: api, state: state)
    }
}

/// 可改的开机标识（同一实例内模拟换开机）。
final class AppTestBoot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(_ value: String?) {
        stored = value
    }

    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
