import Combine
@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import XCTest

/// FU-IOS-PERSONALIZATION-CONSENT-ROLLBACK（D10-1728，BR-ID-13：登录用户以服务端 users.personalization_off 为准，游客存本地并随请求头上报）：
/// 隐私中心【个性化推荐】开关 `PrivacyCenterController.setPersonalization`。
/// ① 登录用户切换后 recordConsent 没成功 → 本机值（personalizationOn、personalizationOffNow、X-Personalization 头）与页面状态回到切换前，提示一次；
/// ② 游客只写本地，失败只提示不回滚；③ 同意记录在途时全 App 再切换都不受理，只回滚最近一次切换（应用级，D10-1838）；离页后失败 member 仍回滚、
/// 不提示；④ 结果回来时身份已变不动本机值、不提示；⑤ 成功不回滚不提示。失败路径上不自动再发 recordConsent；回滚后紧接着的请求头已是回滚后的值。
/// 全部经真实 Router、真实 ApiClient 与页面渲染时取出的按钮回调（`PrivacyCenterActions`），传输层是本地假服务。
///
/// 构造不了的情形（只在注释里说明）：
/// - 缺协议版本：`AppMe.legalPrivacyVersion()` 取不到配置时回落到本机已同意版本，`MeAppFixture` 的已同意决定总带 consentedVersion "1"，
///   夹具没有「已同意但无版本」的入口；同一个 else 分支由「设备未注册」用例覆盖。
/// - cancelled / forceUpdate（只回滚不提示）：cancelled 只来自 session_changed / account_mismatch / 调用作废，这些都伴随身份变化，结果回来时
///   身份检查为 stale、走 ④；10405 强更要真实强更分流与 effect，夹具里没有让 consent 请求得到 forceUpdate 分类而身份仍当前的办法。
@MainActor
final class FuIosPersonalizationConsentRollbackTests: FuIosPersonalizationConsentTestCase {
    // MARK: - ① 登录用户：没成功就回滚

    /// ① 服务端失败（50001）：预置「关、切换时刻 1」，切开后失败 → 本机值与切换时刻回到「关、1」、页面回到关、回滚后紧接着的请求全带
    /// X-Personalization: off，提示一次，不自动再发。删掉 Task 结果里的 `personalizationFailed(...)`（或其中 member 回滚那段
    /// `deps.local?.setPersonalization(toggle.previous, …)` / 页面状态同步）会红；把写回时刻的 `toggle.previousAt ??` 去掉会红（时刻不是 1）。
    func testMemberServerFailureRollsBackAndHeaderFollows() async throws {
        let fixture = make()
        fixture.local.setPersonalization(false, now: 1)
        script.fail("POST /v1/consents", 50001)
        let controller = try center(fixture)
        assertValue(fixture, controller, false, "切换前")
        toggle(controller, true)
        assertValue(fixture, controller, true, "本机先保存")
        await waitUntil("没提示") { self.revertedToast(controller) }
        XCTAssertEqual(requests("POST", "/v1/consents").count, 1, "请求确实发出")
        assertValue(fixture, controller, false, "服务端失败后回滚")
        XCTAssertEqual(fixture.local.personalizationChangedAt, 1, "切换时刻写回切换前的值")
        let toastId = controller.state.toast?.id
        await assertNoResend(1, never: false, "服务端失败")
        await assertNextRequestsHeader(fixture, "off", "服务端失败回滚")
        XCTAssertEqual(controller.state.toast?.id, toastId, "只提示一次")
    }

    /// ① 传输失败（断连）：回滚到切换前（开），提示一次，不自动再发，回滚后紧接着的请求不带 X-Personalization。
    /// D10-1836：从没切换过 → 切换失败 → 回滚后本机切换时刻写回 0（「没有成功的切换」），不是当前时刻（被回滚的切换不得留下最新时刻，
    /// 否则登录对账按较晚者为准会压过别的设备上真正的选择）。删掉 member 回滚那段会红；把 `toggle.previousAt ?? 0` 改回当前时刻会红。
    func testMemberTransportFailureRollsBack() async throws {
        script.on("POST /v1/consents", .disconnect)
        let fixture = make()
        let controller = try center(fixture)
        XCTAssertNil(fixture.local.personalizationChangedAt, "从没切过")
        toggle(controller, false)
        assertValue(fixture, controller, false, "本机先保存")
        let switchedAt = try XCTUnwrap(fixture.local.personalizationChangedAt)
        await waitUntil("没提示", timeout: 10) { self.revertedToast(controller) }
        assertValue(fixture, controller, true, "传输失败后回滚")
        XCTAssertGreaterThan(switchedAt, 0, "切换时写的是当前时刻")
        XCTAssertEqual(fixture.local.personalizationChangedAt, 0, "从没切换过：回滚后切换时刻为 0，不是当前时刻（D10-1836）")
        await assertNoResend(1, never: true, "传输失败")
        await assertNextRequestsHeader(fixture, nil, "传输失败回滚")
    }

    /// ① 本地拒绝（发送前闸门在实际写出前关上 → gated）：一条都没发出，回滚并提示。切换返回后、在途任务开跑前启动禁用期，
    /// 执行层的 sendAllowed 拦下。删掉 Task 结果里的 `personalizationFailed(...)` 会红（旧实现只提示不回滚）。
    func testMemberLocalGateRejectRollsBack() async throws {
        let fixture = make()
        let controller = try center(fixture)
        toggle(controller, false)
        fixture.me.deps.gates.consent.start(60000)
        await waitUntil("没提示") { self.revertedToast(controller) }
        await settle()
        XCTAssertTrue(requests("POST", "/v1/consents").isEmpty, "本地拒绝，零发送")
        XCTAssertEqual(fixture.api.calls(PrivacyCenterController.recordConsent), 1, "确实进了发送入口")
        assertValue(fixture, controller, true, "本地拒绝后回滚")
        await assertNoResend(0, never: true, "本地拒绝")
    }

    /// ① 身份暂时未知被本地拒、结果回来时读取已恢复（FU-IOS-PERSONALIZATION-ROLLBACK-FLAKY，D10-2153）：发送入口起会话读取持续失败
    /// （`ReadFailureWindow.open` → `failReads(fromNth: 1)`，与读取次数、别的任务谁先读无关，这次发送必按 session_unreadable 本地拒绝、
    /// 零发送）；在途结束 `personalization.end()` 里 `settled` 同步发布时恢复读取——Task 里 send 返回 → end() → `check(identity)`
    /// 同在主线程、中间没有挂起点，所以恢复一定在发送被拒之后、结果处理之前。结果落定时身份是 `.current`（持续未知由下一条覆盖）：
    /// 登录用户回滚本机值 / 网络头 / 页面并提示一次，不自动再发。删掉 `personalizationFailed` 里 member 回滚那段（只提示不回滚）会红。
    func testMemberIdentityUnknownLocalRejectRollsBack() async throws {
        let fixture = make()
        let controller = try center(fixture)
        let operation = PrivacyCenterController.recordConsent
        let window = ReadFailureWindow(fixture.store)
        fixture.api.onEntry { entered in
            if entered == operation {
                window.open()
            }
        }
        // 在途结束（settled 同步发布）时关窗；产品 Task 里 end() 写在 check(identity) 之前，本用例依赖这条时序、不验证它
        // （把 end() 挪到 check 之后在这里与原逻辑行为等价：.unknown 与 .current 都回滚并提示，见 FU 目录 mut-2 说明）
        let ended = fixture.me.deps.personalization.$settled.dropFirst().sink { _ in window.close() }
        toggle(controller, false)
        await waitUntil("没提示") { self.revertedToast(controller) }
        await settle()
        ended.cancel()
        fixture.api.onEntry(nil)
        fixture.store.disarm()
        XCTAssertTrue(revertedToast(controller), "本地拒绝要提示（落定后仍在）")
        XCTAssertEqual(fixture.api.calls(operation), 1, "确实进了发送入口")
        XCTAssertTrue(requests("POST", "/v1/consents").isEmpty, "本地拒绝，零发送")
        XCTAssertGreaterThan(window.failedReads, 0, "发送窗口里确有会话读取且都失败，窗口在在途结束时关上（前提）")
        XCTAssertEqual(fixture.me.check(controller.identity), .current, "关窗后读取恢复、身份回到当前（不是持续未知）")
        assertValue(fixture, controller, true, "本地拒绝后回滚")
        XCTAssertEqual(fixture.local.personalizationChangedAt, 0, "切换时刻写回 0")
        XCTAssertFalse(controller.hasLeft, "页面还在")
        let toastId = controller.state.toast?.id
        await assertNoResend(0, never: true, "身份暂时未知")
        XCTAssertEqual(controller.state.toast?.id, toastId, "只提示一次")
    }

    /// ① 身份持续未知（评审 S2-2）：发送入口起会话读取一直失败（`failReads(fromNth: 1)`，不是只失败一次），send 按 session_unreadable
    /// 本地拒绝，结果回来时 `check(identity)` 仍是 `.unknown`（世代未变、会话读不出；`syncIdentity` 在未知时不换代，页面不重建）。
    /// 登录用户照样回滚本机值与切换时刻（从没切过 → 0），页面还在 → 同步页面状态并提示一次。上面一次性读失败那条在结果回来时读取已恢复，
    /// 对持续未知是假绿。把 Task 里 `guard deps.env.check(identity) != .stale` 改回 `isCurrent` 会红（未知时直接返回、不回滚）。
    func testMemberIdentityPersistentlyUnknownRollsBack() async throws {
        let fixture = make()
        let controller = try center(fixture)
        let operation = PrivacyCenterController.recordConsent
        fixture.api.onEntry { [store = fixture.store] entered in
            if entered == operation {
                store.failReads(fromNth: 1)
            }
        }
        toggle(controller, false)
        await waitUntil("没提示") { self.revertedToast(controller) }
        await settle()
        XCTAssertEqual(fixture.me.check(controller.identity), .unknown, "结果落定时身份仍未知（前提）")
        XCTAssertTrue(requests("POST", "/v1/consents").isEmpty, "本地拒绝，零发送")
        assertValue(fixture, controller, true, "身份持续未知：回滚")
        XCTAssertEqual(fixture.local.personalizationChangedAt, 0, "切换时刻写回 0")
        XCTAssertFalse(controller.hasLeft, "页面还在")
        fixture.api.onEntry(nil)
        fixture.store.disarm()
        await assertNoResend(0, never: true, "身份持续未知")
    }

    /// ① 写盘失败（读得出、写不进，`FlakyMeFile.failWrite`）：预置「关、时刻 1」后让偏好文件写入失败，切开 → 盘上仍是关、时刻仍是 1，
    /// 只有内存（网络头）与页面是开；服务端失败 → 仍按应用级切换序号判「最近一次」回滚：网络头恢复 off、页面回到关、提示 revertedKey。
    /// 判据若改回「回读盘上切换时刻是否等于本次」会红（盘上时刻没写进，判成别处切过、不回滚，网络头停在开）。
    func testMemberWriteFailureStillRollsBack() async throws {
        script.fail("POST /v1/consents", 50001)
        let fixture = make()
        fixture.local.setPersonalization(false, now: 1)
        fixture.localFile.failWrite = true
        let controller = try center(fixture)
        toggle(controller, true)
        XCTAssertFalse(fixture.local.personalizationOffNow, "内存先按新值")
        XCTAssertEqual(fixture.local.personalizationChangedAt, 1, "前提：写盘失败，盘上时刻没变")
        await waitUntil("没提示") { self.revertedToast(controller) }
        assertValue(fixture, controller, false, "写盘失败也回滚")
        await assertNoResend(1, never: false, "写盘失败")
        await assertNextRequestsHeader(fixture, "off", "写盘失败回滚")
        fixture.localFile.failWrite = false
    }

    /// ① 限流闸门开着（切换前已在禁用期）：不发请求，回滚并提示。删掉 `gate.active` 分支里的 `personalizationFailed(toggle, notify: true)`
    /// （旧实现只 toast）会红。
    func testMemberGateActiveRollsBack() async throws {
        let fixture = make()
        let controller = try center(fixture)
        fixture.me.deps.gates.consent.start(60000)
        toggle(controller, false)
        assertValue(fixture, controller, true, "闸门开着：同步回滚")
        XCTAssertTrue(revertedToast(controller), "提示一次")
        await settle()
        XCTAssertTrue(requests("POST", "/v1/consents").isEmpty, "限流中不发")
        XCTAssertEqual(fixture.api.calls(PrivacyCenterController.recordConsent), 0)
        await assertNoResend(0, never: true, "限流")
    }

    /// ① 设备未注册（发不出）：不发请求，回滚并提示（member 发不出也提示）。删掉 deviceRegistered / 版本 guard 的 else 里的
    /// `personalizationFailed(toggle, notify: identity.level == member)`（旧实现直接 return）会红。
    func testMemberUnregisteredRollsBackAndNotifies() async throws {
        let fixture = make(registered: false)
        let controller = try center(fixture)
        XCTAssertEqual(controller.identity.level, MeLevel.member)
        toggle(controller, false)
        assertValue(fixture, controller, true, "设备未注册：同步回滚")
        XCTAssertTrue(revertedToast(controller), "member 发不出也提示")
        await settle()
        XCTAssertTrue(requests("POST", "/v1/consents").isEmpty)
    }

    // MARK: - ② 游客：只提示不回滚

    /// ② 游客服务端失败：保持新值，提示一次。删掉 `personalizationFailed` 里的 `identity.level == MeLevel.member` 条件会红。
    func testGuestServerFailureKeepsLocal() async throws {
        script.fail("POST /v1/consents", 50001)
        let fixture = make(account: nil)
        let controller = try center(fixture)
        XCTAssertEqual(controller.identity.level, MeLevel.guest)
        toggle(controller, false)
        await waitUntil("没提示") { self.failedToast(controller) }
        XCTAssertEqual(requests("POST", "/v1/consents").count, 1, "游客记设备级")
        assertValue(fixture, controller, false, "游客不回滚")
    }

    /// ② 游客限流中：只提示不回滚；游客设备未注册：只写本地、不提示不回滚（原行为）。删掉 member 条件（回滚）或把未注册分支的
    /// notify 改成恒真（提示）会红。
    func testGuestGateAndUnregisteredKeepLocal() async throws {
        let gated = make(account: nil)
        let controller = try center(gated)
        gated.me.deps.gates.consent.start(60000)
        toggle(controller, false)
        XCTAssertTrue(failedToast(controller), "限流中提示")
        assertValue(gated, controller, false, "游客限流中不回滚")

        let unregistered = fresh(account: nil, registered: false)
        let page = try center(unregistered)
        toggle(page, false)
        await settle()
        assertValue(unregistered, page, false, "游客设备未注册：只写本地")
        XCTAssertNil(page.state.toast, "游客设备未注册不提示")
        XCTAssertTrue(requests("POST", "/v1/consents").isEmpty)
    }

    // MARK: - ④ 身份已变

    /// ④ 请求在途时换账号（会话世代变了），失败结果回来：本机值不动（仍是切换后的「关」）、旧页面不提示。
    /// 本机值由 Task 里 `guard deps.env.check(identity) != .stale` 保证（离页后也会回滚）：删掉它会红；不提示另由
    /// `if notify, !left` 兜住（换代后旧执行器已 leave）。
    func testIdentityChangedKeepsLocalAndSilent() async throws {
        script.on("POST /v1/consents", .hold)
        let fixture = make()
        let controller = try center(fixture)
        toggle(controller, false)
        await waitUntil("请求没发出") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        try fixture.switchAccount(to: "user-b")
        WalletStubProtocol.release(held, with: .envelope(code: 50001, data: "null", headers: [:]))
        await settle(50)
        XCTAssertFalse(fixture.local.personalizationOn, "身份已变不动本机值")
        XCTAssertTrue(fixture.local.personalizationOffNow, "网络头读的内存值不动")
        XCTAssertNil(controller.state.toast, "身份已变不提示")
    }

    // MARK: - ⑤ 成功

    /// ⑤ 登录用户成功：保持新值、不提示、之后请求带 X-Personalization: off。删掉 Task 里 `if case .success = result { return }` 会红
    /// （成功也走失败处理 → 回滚并提示）。
    func testMemberSuccessKeepsAndSilent() async throws {
        let fixture = make()
        await fixture.loadConfig()
        let controller = try center(fixture)
        toggle(controller, false)
        await waitUntil("同意记录没发") { !self.requests("POST", "/v1/consents").isEmpty }
        await settle()
        assertValue(fixture, controller, false, "成功不回滚")
        XCTAssertNil(controller.state.toast, "成功不提示")
        _ = await fixture.enterMeTab()
        await waitUntil("Me 没请求") { !self.requests("GET", "/v1/me").isEmpty }
        XCTAssertEqual(requests("GET", "/v1/me").last?.header("X-Personalization"), "off")
    }
}

/// 本单两本测试共用的搭建（打开隐私中心、按渲染回调切换、三处值断言、不自动再发、回滚后的请求头）。
@MainActor
class FuIosPersonalizationConsentTestCase: MeTestCase {
    func center(_ fixture: MeAppFixture) throws -> PrivacyCenterController {
        let entry = try XCTUnwrap(fixture.open("PrivacyCenter"))
        entry.appeared()
        return try XCTUnwrap(entry.controller() as? PrivacyCenterController)
    }

    /// 经渲染时取出的回调切换（每次按此刻的版本取，与页面一致）。
    func toggle(_ controller: PrivacyCenterController, _ on: Bool) {
        PrivacyCenterActions.make(controller, controller.state).personalization(on)
    }

    /// 本机值、网络头读的内存值、页面状态三处都等于 `on`。
    func assertValue(_ fixture: MeAppFixture, _ controller: PrivacyCenterController, _ on: Bool, _ tag: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.local.personalizationOn, on, "\(tag)：本机值", file: file, line: line)
        XCTAssertEqual(fixture.local.personalizationOffNow, !on, "\(tag)：网络头读的内存值", file: file, line: line)
        XCTAssertEqual(controller.state.personalizationOn, on, "\(tag)：页面状态", file: file, line: line)
    }

    /// 没回滚的失败提示（游客等）。
    func failedToast(_ controller: PrivacyCenterController) -> Bool {
        controller.state.toast?.key == PrivacyCenterController.failedKey
    }

    /// 登录用户失败回滚后的提示（D10-1838：「没有保存成功，已恢复原来的设置」）。
    func revertedToast(_ controller: PrivacyCenterController) -> Bool {
        controller.state.toast?.key == PrivacyCenterController.revertedKey
    }

    /// 同一用例里要多个干净组合时用：假服务、偏好目录都重来。
    func fresh(account: String? = "user-a", registered: Bool = true) -> MeAppFixture {
        WalletStubProtocol.reset()
        script.install()
        try? FileManager.default.removeItem(at: MeAppFixture.localDirectory(suiteName))
        return make(account: account, registered: registered)
    }

    /// 失败落定后再持续观察一段（约 0.6 秒）：POST /v1/consents 一直是 `count` 条，且没有 accepted == `never` 的（回滚值不自动补发）。
    func assertNoResend(_ count: Int, never accepted: Bool, _ tag: String,
                        file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            let posts = requests("POST", "/v1/consents")
            if posts.count != count || posts.contains(where: { $0.json["accepted"] as? Bool == accepted }) {
                XCTFail("\(tag)：失败后自动再发了 recordConsent（\(posts.count) 条）", file: file, line: line)
                return
            }
        }
    }

    /// 回滚之后紧接着发出的请求（进「我的」Tab 的 GET /v1/me 等）全部带回滚后的 X-Personalization（nil = 不带，即开）。
    func assertNextRequestsHeader(_ fixture: MeAppFixture, _ expected: String?, _ tag: String,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        let mark = WalletStubProtocol.requests.count
        _ = await fixture.enterMeTab()
        await waitUntil("\(tag)：Me 没请求", file: file, line: line) {
            WalletStubProtocol.requests.dropFirst(mark).contains { $0.method == "GET" && $0.path == "/v1/me" }
        }
        for request in WalletStubProtocol.requests.dropFirst(mark) {
            XCTAssertEqual(request.header("X-Personalization"), expected, "\(tag)：\(request.method) \(request.path)",
                           file: file, line: line)
        }
    }
}

/// 会话读取的故障窗口（本文件「身份暂时未知被本地拒」用）：`open()` 起读取持续失败，`close()` 恢复，并记下窗口里失败了几次读取
/// （`close()` 没在 `open()` 之后发生则为 0）。
private final class ReadFailureWindow: @unchecked Sendable {
    private let store: CountingSessionTokens
    private let lock = NSLock()
    private var openedAt: Int?
    private var failed = 0

    init(_ store: CountingSessionTokens) {
        self.store = store
    }

    var failedReads: Int {
        lock.withLock { failed }
    }

    func open() {
        lock.withLock { openedAt = store.reads }
        store.failReads(fromNth: 1)
    }

    func close() {
        lock.withLock { failed = openedAt.map { store.reads - $0 } ?? 0 }
        store.stopFailing()
    }
}
