@testable import Couli
import CouliNetwork
import Foundation
import Me
@testable import MeCore
import Router
import Session
import XCTest

/// FU-IOS-0713 必测 3（RW-06）：「我的」用一次完整身份快照；身份暂时未知不当游客、不清共享闸门、不移登录专属页；风险说明、申诉的读取
/// 接入暂缓与补取，无内容时给可重试结算态。全部经生产入口：页面经 Router 打开、`MePageEntry.appeared`、渲染时取出的
/// `RiskNoticeActions`；身份同步走 `AppMe.syncIdentity`（会话版本、隐私、强更状态变化与回前台都转到这里）。故障按读取位置遍历。
final class FollowupIos0713MeTests: MeTestCase {
    private let suites = FreshSuites()

    override func tearDown() {
        suites.removeAll()
        super.tearDown()
    }

    static let banned = MeSamples.me(risk: "banned", reason: "account_security")
    static let frozen = MeSamples.me(risk: "frozen", reason: "abnormal_trade", until: "2026-10-15T00:00:00+08:00")

    func fresh(_ tag: String) -> MeAppFixture {
        WalletStubProtocol.reset()
        script.install()
        let (name, defaults) = suites.make(suiteName, tag)
        return MeAppFixture.make(suiteName: name, defaults: defaults)
    }

    /// 风险说明 / 申诉页此刻的阶段（两页的 Phase 同名）。
    private func phase(_ controller: AnyObject) -> String {
        if let risk = controller as? RiskNoticeController {
            return "\(risk.state.phase)"
        }
        if let appeal = controller as? AppealController {
            return "\(appeal.state.phase)"
        }
        return "?"
    }

    /// 页面上的【重试】（渲染时的回调）。
    private func retry(_ controller: AnyObject) {
        if let risk = controller as? RiskNoticeController {
            RiskNoticeActions.make(risk, risk.state).retry()
        }
        if let appeal = controller as? AppealController {
            AppealActions.make(appeal, appeal.state).retry()
        }
    }

    static let upheld = MeSamples.appeals([MeSamples.appeal("upheld", closed: true)])

    /// 页面显示的是服务端的实际内容：风险说明为 banned / frozen 版式；申诉页为「维持原处理结果」（脚本里那一条申诉）。
    func assertActualContent(_ controller: AnyObject, _ tag: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        if let risk = controller as? RiskNoticeController {
            let layout = risk.model()?.layoutRaw ?? ""
            XCTAssertTrue(layout.hasPrefix("banned") || layout.hasPrefix("frozen"), "\(tag)：显示服务端说明（\(layout)）",
                          file: file, line: line)
        }
        if let appeal = controller as? AppealController {
            XCTAssertEqual(appeal.layout, AppealView.resultUpheld, "\(tag)：显示服务端申诉结论", file: file, line: line)
            XCTAssertEqual(appeal.state.appeals.count, 1, "\(tag)：申诉列表是服务端那一条", file: file, line: line)
        }
    }

    // MARK: - 风险说明 / 申诉的读取

    /// 已收到成功的 getMe 响应、核对身份时读取暂时失败（按读取位置遍历，含 computeIdentity 的读取）：页面不停在加载中；故障窗口在
    /// 「下一个读取进入 MeApi 入口」或页面结算时结束（之后的网络层读取不在窗口内）。之后只经生产身份确认入口（`syncIdentity`）→ 自动
    /// 采用保留的结果或补取，显示服务端实际内容；不点【重试】。
    func testRiskAndAppealSuccessAtUnknownIdentityAdoptedOrRefetchedOnConfirmation() async throws {
        for route in [AppMe.riskNotice, AppMe.appeal] {
            try await forEachReadPosition("\(route) 读取") { fault, nth in
                let tag = "\(route) 读取/\(fault.rawValue)#\(nth)"
                script.on("GET /v1/me", .hold, .envelope(code: 0, data: Self.frozen, headers: [:]))
                script.ok("GET /v1/me/appeals", Self.upheld)
                let fixture = fresh(tag)
                let entry = try XCTUnwrap(fixture.open(route), "\(tag)：页面没有打开")
                entry.appeared()
                let controller = entry.controller()
                await waitUntil("\(tag)：getMe 没有挂住") { WalletStubProtocol.heldIds.count == 1 }
                XCTAssertEqual(fixture.api.calls(MeRepository.operation), 1, "\(tag)：前提：挂住的是本页的 getMe")
                let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
                let window = FaultWindow(fixture.store)
                let store = fixture.store
                fixture.api.onEntry { _ in store.disarm() }
                window.begin(fault, nth)
                WalletStubProtocol.release(held, with: .envelope(code: 0, data: Self.banned, headers: [:]))
                await waitUntil("\(tag)：响应回来后停在加载中（无出口）") { phase(controller) != "loading" }
                fixture.api.onEntry(nil)
                let used = window.end()
                fixture.me.syncIdentity()
                await waitUntil("\(tag)：身份确认后没有自动显示内容") { phase(controller) == "content" }
                assertActualContent(controller, tag)
                XCTAssertTrue(fixture.router.path.contains { $0.route == route }, "\(tag)：页面仍在栈里")
                return used
            }
        }
    }

    /// 真实的网络读取失败（getMe 断连）：带错误提示的可重试失败态；用户点【重试】→ 显示服务端内容。与身份未知的场景分开。
    func testRiskAndAppealNetworkReadFailureRetryLoads() async throws {
        for route in [AppMe.riskNotice, AppMe.appeal] {
            let tag = "\(route) 网络失败"
            // 网络层对读请求可能自动重试：断连一直持续到页面结算为失败态，之后服务端恢复
            script.on("GET /v1/me", .disconnect)
            script.ok("GET /v1/me/appeals", Self.upheld)
            let fixture = fresh(tag)
            let entry = try XCTUnwrap(fixture.open(route))
            entry.appeared()
            let controller = entry.controller()
            await waitUntil("\(tag)：没有结算为失败态") { phase(controller) == "error" }
            script.ok("GET /v1/me", Self.banned)
            retry(controller)
            await waitUntil("\(tag)：【重试】后没有显示内容") { phase(controller) == "content" }
            assertActualContent(controller, tag)
        }
    }

    /// 无内容的结算态有本页出口：身份持续未知时响应到达 → 失败态（不是加载中）；仍不可读时点【重试】并等页面空闲 → 不调用读取入口、不出
    /// 内容；Keychain 恢复后（之前没有任何身份同步）点【重试】→ 显示服务端内容。
    func testRiskNoticeSettledStateRetryLoadsAfterKeychainRecovers() async throws {
        script.on("GET /v1/me", .hold, .envelope(code: 0, data: Self.frozen, headers: [:]))
        let fixture = fresh("重试出口")
        let entry = try XCTUnwrap(fixture.open(AppMe.riskNotice))
        entry.appeared()
        let controller = try XCTUnwrap(entry.controller() as? RiskNoticeController)
        await waitUntil("getMe 没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        fixture.store.failReads(fromNth: 1)
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: Self.banned, headers: [:]))
        await waitUntil("响应回来后停在加载中") { controller.state.phase != .loading }
        XCTAssertNil(controller.state.risk, "前提：没有采用身份未知时的响应")
        XCTAssertEqual(controller.state.phase, .error, "无内容：可重试的失败态")
        let calls = fixture.api.calls(MeRepository.operation)
        RiskNoticeActions.make(controller, controller.state).retry()
        await controller.whenIdle()
        XCTAssertEqual(fixture.api.calls(MeRepository.operation), calls, "身份仍不可读：【重试】不调用读取入口")
        XCTAssertNotEqual(controller.state.phase, .content, "身份仍不可读：【重试】不出内容")
        fixture.store.disarm()
        RiskNoticeActions.make(controller, controller.state).retry()
        await waitUntil("恢复后【重试】没有出内容") { controller.state.phase == .content }
        assertActualContent(controller, "恢复后【重试】")
    }

    /// 单次身份计算字段同源（RW-06「一次完整身份快照」）：计算开始的第一次读取是已登录 A；之后的读取读失败或读到「没有会话」→ 结果仍是
    /// 那一次读取的完整身份（已登录、账号 A、网络归属账号 A），不拼接第二次读取。
    func testComputeIdentityUsesOneSnapshot() {
        for other in ["失败", "没有会话"] {
            let fixture = fresh("身份同源/\(other)")
            if other == "失败" {
                fixture.store.failReads(fromNth: 2)
            } else {
                fixture.store.redirect(fromNth: 2, to: MemorySessionTokens())
            }
            let identity = fixture.me.computeIdentity()
            fixture.store.disarm()
            XCTAssertEqual(identity.level, MeLevel.member, "\(other)：已登录")
            XCTAssertEqual(identity.account, "user-a", "\(other)：账号 A")
            XCTAssertEqual(identity.request?.account, "user-a", "\(other)：网络归属同一次读取")
        }
    }

    // MARK: - 身份同步

    /// 「我的」已登录、Me 已取到、风险说明在栈里、读取闸门在禁用期；一次身份同步期间读取暂时失败（按读取位置遍历）→ 不当游客（Tab 不按
    /// 游客重建）、不清读取闸门与 Me 快照、不移出风险说明；恢复后再同步一次，仍是同一已登录身份，以上都保持。
    func testSyncIdentityWhileUnknownKeepsMemberGatesAndLoginOnlyPages() async throws {
        try await forEachReadPosition("身份同步") { fault, nth in
            let tag = "身份同步/\(fault.rawValue)#\(nth)"
            script.ok("GET /v1/me", Self.banned)
            let fixture = fresh(tag)
            _ = await loadedTab(fixture)
            let risk = try XCTUnwrap(fixture.open(AppMe.riskNotice))
            risk.appeared()
            let controller = try XCTUnwrap(risk.controller() as? RiskNoticeController)
            await waitUntil("\(tag)：说明没有到位") { controller.state.phase == .content }
            fixture.me.gates.read.start(600_000)
            let window = FaultWindow(fixture.store)
            window.begin(fault, nth)
            fixture.me.syncIdentity()
            let used = window.end()
            assertMemberKept(fixture, controller, "\(tag)：未知期间")
            fixture.me.syncIdentity()
            assertMemberKept(fixture, controller, "\(tag)：恢复后")
            XCTAssertTrue(fixture.me.currentIdentity.member, "\(tag)：恢复后仍是已登录身份")
            return used
        }
    }

    private func assertMemberKept(_ fixture: MeAppFixture, _ controller: RiskNoticeController, _ tag: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotEqual(fixture.me.currentIdentity.level, MeLevel.guest, "\(tag)：不当游客", file: file, line: line)
        XCTAssertNotEqual(fixture.me.tabHost.controller.identity.level, MeLevel.guest, "\(tag)：Tab 不按游客重建",
                          file: file, line: line)
        XCTAssertTrue(fixture.me.gates.read.active, "\(tag)：不清读取闸门", file: file, line: line)
        XCTAssertNotNil(fixture.me.deps.repo.state.me, "\(tag)：不清 Me 快照", file: file, line: line)
        XCTAssertTrue(fixture.router.path.contains { $0.route == AppMe.riskNotice }, "\(tag)：不移出风险说明",
                      file: file, line: line)
        XCTAssertFalse(controller.hasLeft, "\(tag)：风险说明执行器不作废", file: file, line: line)
        XCTAssertEqual(controller.state.phase, .content, "\(tag)：说明内容保留", file: file, line: line)
    }

    /// 对照（确认换代才重置）：确认换成另一个账号 → 风险说明移出导航栈、读取闸门重置。
    func testConfirmedAccountChangeStillClearsLoginOnlyPagesAndGates() throws {
        script.ok("GET /v1/me", Self.banned)
        let fixture = fresh("换代对照")
        let risk = try XCTUnwrap(fixture.open(AppMe.riskNotice))
        risk.appeared()
        fixture.me.gates.read.start(600_000)
        try fixture.switchAccount(to: "user-b")
        fixture.me.syncIdentity()
        XCTAssertFalse(fixture.router.path.contains { $0.route == AppMe.riskNotice }, "移出风险说明")
        XCTAssertFalse(fixture.me.gates.read.active, "读取闸门重置")
    }

    // MARK: - 「我的」Tab 进入

    /// 进入「我的」Tab 时身份读取暂时失败（按读取位置遍历，含 computeIdentity 的第二次读取）：Tab 执行器不按游客建；之后一次身份同步
    /// → Tab 是已登录身份并取到 Me。
    func testEnterMeTabWhileUnknownIsNotGuestAndLoadsAfterConfirmation() async throws {
        try await forEachReadPosition("进入我的") { fault, nth in
            let tag = "进入我的/\(fault.rawValue)#\(nth)"
            let fixture = fresh(tag)
            // 选中 Tab 后同步进入（与 Tab 根出现时排到下一轮的 enterTab 同一入口；先到者生效）：窗口只含这一次进入的读取
            _ = fixture.routing.selectTab(.me)
            let window = FaultWindow(fixture.store)
            window.begin(fault, nth)
            fixture.me.enterTab()
            let used = window.end()
            XCTAssertNotEqual(fixture.me.tabHost.controller.identity.level, MeLevel.guest, "\(tag)：未知不按游客建 Tab")
            fixture.me.syncIdentity()
            await waitUntil("\(tag)：确认后 Tab 没有按已登录取到 Me") {
                fixture.me.tabHost.controller.identity.member && fixture.me.deps.repo.state.me != nil
            }
            return used
        }
    }
}
