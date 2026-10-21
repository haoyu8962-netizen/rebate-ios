import ClientCore
import Clipboard
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Login
import Privacy
import Router
import Update
import XCTest

/// APP-07 App 接线（brief §2.11）：经真实生命周期入口（sceneActive / sceneBackground）与 Router（导航栈、Tab），本地假剪贴板与假 parse
/// 服务（ApiCall 级，记录请求体），不直接调内部判定函数。断言点击前 0 次请求、点击后恰好 1 次、请求体不含原文、系统剪贴板写入次数为 0、
/// 敏感页不读不补、迟到响应只丢弃、42901 禁用所有粘贴入口、游客邀请预填、行内 10405 进强更、撤回同意清记录。
@MainActor
final class ClipboardWiringTests: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    let link = "【淘宝】降噪耳机 https://e.tb.cn/h.Demo01?tk=Sample 「降噪蓝牙耳机」 复制这段话打开"

    override func setUpWithError() throws {
        suiteName = "ClipboardWiringTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    struct Fixture {
        let clipboard: AppClipboard
        let routing: AppRouting
        let system: FakeSystemClipboard
        let api: FakeParseApi
        let store: MemoryClipboardHashStore
        let state: FakeState
    }

    @MainActor
    final class FakeState {
        var privacy: PrivacyState = .consented
        var guest = true
        var session: UInt64 = 1
        var epoch: UInt64 = 1
        var config = #"{"share_domains":["share.example.test"]}"#
        var forced = 0
        /// 整体 10405 由执行层进强更的次数与最低版本（FU-IOS-0712 R1-03 对照）。
        var networkForced: [String?] = []
        var overlay: String?
    }

    /// `clock`：限流禁用期的时钟（R1-04 测到期恢复）；nil = 墙钟。
    func make(privacy store: MemoryPrivacyStore? = nil, clock: (() -> Int64)? = nil) -> Fixture {
        let privacyStore = store ?? {
            let consented = MemoryPrivacyStore()
            consented.decisionRaw = "consented"
            consented.consentedVersion = "1"
            return consented
        }()
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: .init(cleaners: []))
        let privacy = PrivacyController(store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1")
        let routing = AppRouting(environment: environment, privacy: privacy, update: UpdateFixtures.makeUpdate())
        routing.shellAppeared()
        let system = FakeSystemClipboard()
        let api = FakeParseApi()
        let hashes = MemoryClipboardHashStore()
        let state = FakeState()
        let clipboard = AppClipboard(
            system: system, store: hashes, api: api, router: routing.router,
            deps: AppClipboard.Deps(
                privacy: { state.privacy }, privacyPrompting: { false }, forceUpdate: { false },
                configJson: { state.config }, guest: { state.guest },
                sessionGeneration: { state.session }, networkEpoch: { state.epoch },
                serverForced: { state.forced += 1 },
                networkForced: { state.networkForced.append($0) }
            ),
            clock: clock ?? { Int64(Date().timeIntervalSince1970 * 1000) }
        )
        clipboard.overlaySource = { state.overlay }
        return Fixture(
            clipboard: clipboard, routing: routing, system: system, api: api, store: hashes, state: state
        )
    }

    func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    // MARK: - AC-S1-03 a / b / c / e

    func testPromptThenOneParseWithoutRawTextAndNoWrites() async throws {
        let fixture = make()
        fixture.system.changeCount = 7
        fixture.system.detectHit = true
        fixture.api.reply = .success(card: true)
        fixture.clipboard.sceneActive()
        let prompt = try XCTUnwrap(fixture.clipboard.prompt, "命中链接出提示条")
        XCTAssertEqual(fixture.system.detectCalls, 1)
        XCTAssertEqual(fixture.api.bodies.count, 0, "点击前不发请求")
        fixture.clipboard.promptPasted(prompt.id, text: link)
        await settle()
        XCTAssertEqual(fixture.api.bodies.count, 1, "点击后恰好 1 次")
        let body = try XCTUnwrap(fixture.api.bodies.first)
        XCTAssertTrue(body.contains("e.tb.cn"))
        XCTAssertTrue(body.contains("\"scene\":\"clipboard\""))
        XCTAssertFalse(body.contains("复制这段话"), "原文其余部分不上传")
        XCTAssertFalse(body.contains("【淘宝】"))
        XCTAssertEqual(fixture.system.writes, 0, "识别、提示、上传前后都不写系统剪贴板")
        XCTAssertEqual(fixture.routing.router.path.last?.route, "ProductDetail", "1 张卡打开详情")
        let detail = try XCTUnwrap(fixture.routing.router.path.last)
        let seed = fixture.clipboard.seeds.claim(detail.id, productKey: "tb:milk")
        XCTAssertEqual(seed?["link_id"] as? String, "link-parse-1", "详情沿用 parse 卡的 link_id")
        XCTAssertEqual(fixture.system.writes, 0)
    }

    func testNoDetectHitNoPromptAndSameContentNotAgain() {
        let fixture = make()
        fixture.system.changeCount = 3
        fixture.system.detectHit = false
        fixture.clipboard.sceneActive()
        XCTAssertNil(fixture.clipboard.prompt, "普通文本不提示")
        XCTAssertEqual(fixture.system.detectCalls, 1)
        fixture.clipboard.sceneBackground()
        fixture.system.detectHit = true
        fixture.clipboard.sceneActive()
        XCTAssertEqual(fixture.system.detectCalls, 1, "changeCount 没变：不再探测（c）")
        XCTAssertNil(fixture.clipboard.prompt)
        XCTAssertEqual(fixture.api.bodies.count, 0)
    }

    func testRefocusWithoutBackgroundDoesNotDetectAgain() {
        let fixture = make()
        fixture.system.changeCount = 1
        fixture.system.detectHit = false
        fixture.clipboard.sceneActive()
        fixture.system.changeCount = 2
        fixture.system.detectHit = true
        // 下拉通知栏、系统弹窗后重新激活（没有经过后台）：不算回前台（共性第 1 条）
        fixture.clipboard.sceneActive()
        fixture.clipboard.sceneActive()
        XCTAssertEqual(fixture.system.detectCalls, 1)
        XCTAssertNil(fixture.clipboard.prompt)
        fixture.clipboard.sceneBackground()
        fixture.clipboard.sceneActive()
        XCTAssertEqual(fixture.system.detectCalls, 2, "真正经过后台再回来才重新判定")
        XCTAssertNotNil(fixture.clipboard.prompt)
    }

    // MARK: - d：敏感页面

    func testSensitiveRoutesDoNotReadAndNoCatchUp() {
        for route in ["Withdraw", "Login", "FindOrder"] {
            let fixture = make()
            fixture.system.changeCount = 5
            fixture.system.detectHit = true
            fixture.routing.router.path = [RouteDestination(route: route)]
            fixture.clipboard.sceneActive()
            XCTAssertEqual(fixture.system.detectCalls, 0, route)
            fixture.routing.router.path = []
            XCTAssertNil(fixture.clipboard.prompt, "\(route)：返回首页不补出")
            XCTAssertEqual(fixture.system.detectCalls, 0, route)
        }
    }

    func testSensitiveOverlayAndPrivacyGateSkip() {
        let fixture = make()
        fixture.system.changeCount = 5
        fixture.system.detectHit = true
        fixture.state.overlay = ClipboardSensitive.overlayAuthSheet
        fixture.clipboard.sceneActive()
        XCTAssertEqual(fixture.system.detectCalls, 0)
        let basic = MemoryPrivacyStore()
        basic.decisionRaw = "basic_mode"
        basic.basicMode = true
        let other = make(privacy: basic)
        other.state.privacy = .basicMode
        other.system.changeCount = 5
        other.system.detectHit = true
        other.clipboard.sceneActive()
        XCTAssertEqual(other.system.detectCalls, 0, "基本模式不读")
    }

    func testConfigFlagOffSkipsAutoButKeepsManual() async {
        let fixture = make()
        fixture.state.config = #"{"features":{"flags":{"clipboard.enabled.ios":false}}}"#
        fixture.system.changeCount = 5
        fixture.system.detectHit = true
        fixture.clipboard.sceneActive()
        XCTAssertEqual(fixture.system.detectCalls, 0, "G05：明确 false 关自动识别")
        fixture.api.reply = .success(card: true)
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await settle()
        XCTAssertEqual(fixture.api.bodies.count, 1, "手动粘贴保留")
    }

    // MARK: - App 自写

    func testSelfWrittenContentIsNotPromptedOrUploaded() async {
        let fixture = make()
        XCTAssertTrue(fixture.clipboard.writer.write(link))
        XCTAssertEqual(fixture.system.writes, 1)
        fixture.system.detectHit = true
        fixture.clipboard.sceneActive()
        XCTAssertEqual(fixture.system.detectCalls, 0, "写入后记下的 changeCount：回前台不提示")
        XCTAssertNil(fixture.clipboard.prompt)
        // 第二道：读到后的 hash（手动粘贴同样排除，共性第 17 条）
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await settle()
        XCTAssertEqual(fixture.api.bodies.count, 0)
    }

    func testWriterRefusesWhenLedgerNotPersisted() {
        let fixture = make()
        fixture.store.failWrites = true
        XCTAssertFalse(fixture.clipboard.writer.write("copy-me"), "自写 hash 没落盘就不写（共性第 23、25 条）")
        XCTAssertEqual(fixture.system.writes, 0)
    }

    // MARK: - 网页抑制（G06）

    func testWebSuppressionOnlyWhileContainerOnTop() {
        let fixture = make()
        let page = RouteDestination(route: "WebPage")
        fixture.routing.router.path = [page]
        fixture.clipboard.setWebAutoDetect(container: page.id, enabled: false)
        fixture.system.changeCount = 9
        fixture.system.detectHit = true
        fixture.clipboard.sceneBackground()
        fixture.clipboard.sceneActive()
        XCTAssertEqual(fixture.system.detectCalls, 0)
        fixture.routing.router.path = []
        fixture.clipboard.sceneBackground()
        fixture.clipboard.sceneActive()
        XCTAssertEqual(fixture.system.detectCalls, 1, "容器出栈后下一次回前台恢复识别")
    }

    // MARK: - 邀请（AC-S1-63）

    /// APP-17c（F-CLIP-06、AC-S1-63 ①，G19）：游客点确认 → 记为待绑定码，不跳登录页、不发请求；读取不取走。
    func testGuestInviteConfirmPrefillsLoginWithoutRequest() throws {
        let fixture = make()
        fixture.clipboard.sceneActive()
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: "邀请码 k7m2qx 快来")
        let result = try XCTUnwrap(fixture.clipboard.result)
        guard case let .inviteConfirm(code) = result.kind else { return XCTFail("游客出邀请确认") }
        XCTAssertEqual(code, "K7M2QX")
        fixture.clipboard.confirmInvite(result.id)
        XCTAssertTrue(fixture.routing.router.path.isEmpty, "不跳登录页（G19）")
        XCTAssertNil(fixture.clipboard.result)
        XCTAssertEqual(fixture.clipboard.pendingInvite.peek(), "K7M2QX")
        XCTAssertEqual(fixture.clipboard.pendingInvite.peek(), "K7M2QX", "读取不取走")
        XCTAssertEqual(fixture.api.bodies.count, 0, "游客只记下不上传")
    }

    func testProductPriorityAndLoggedInInviteSilent() async {
        let fixture = make()
        fixture.clipboard.sceneActive()
        fixture.api.reply = .success(card: true)
        let mixed = "https://e.tb.cn/h.Demo01?tk=Sample https://share.example.test/i/K7M2QX 邀请码 K7M2QX"
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: mixed)
        await settle()
        XCTAssertEqual(fixture.api.bodies.count, 1, "d：商品优先")
        XCTAssertFalse(fixture.api.bodies[0].contains("share.example.test"), "邀请落地页不上传（共性第 13 条）")
        let member = make()
        member.state.guest = false
        member.clipboard.sceneActive()
        member.clipboard.pasted(entry: ManualPasteAction.entryHome, text: "https://share.example.test/i/K7M2QX")
        XCTAssertNil(member.clipboard.result, "已登录粘贴纯邀请内容静默，不落入 30132（共性第 19 条）")
        XCTAssertEqual(member.api.bodies.count, 0)
    }

    func testLoginInvitePasteExtractsOnly() {
        let fixture = make()
        fixture.routing.router.path = [RouteDestination(route: "Login")]
        let paste = fixture.clipboard.makeLoginInvitePaste()
        XCTAssertEqual(paste.handle("￥AB12CD￥ 邀请码 K7M2QX"), .code("K7M2QX"))
        XCTAssertEqual(paste.handle("没有码"), .message("未识别到邀请码"))
    }
}
