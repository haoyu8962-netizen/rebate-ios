@testable import Couli
import CouliNetwork
import Foundation
import Router
import SwiftUI
import Wallet
import WalletCore
import XCTest

/// FU-IOS-WITHDRAW-ENTRY-SILENT（D10-2648 ②；主链路实跑第 10 / 11 项）的公共搭法：真 Router + 真 AppWallet + 本地假服务；【提现】一律从
/// 渲染用的 `WalletActions.make(controller, controller.state).withdraw()` 进入（不直接调 `wallet.open`）。钱包页余额 0、withdraw_enabled
/// true，本会话还没查过实名（点了要先异步取 GET /v1/me）。
@MainActor
class FuIosWithdrawEntrySilentTestCase: WalletFlowTestCase {
    static let unverifiedMe = "{\"user_id\":\"user-a\",\"realname_status\":\"none\",\"phone_bound\":true}"
    static let unverified = WalletStubProtocol.Reply.envelope(code: 0, data: unverifiedMe, headers: [:])
    static let verified = WalletStubProtocol.Reply.envelope(code: 0, data: WalletSamples.me, headers: [:])
    /// 余额 0（available / withdrawable 都是 0），withdraw_enabled 仍为 true（实跑第 10 项的测试号）。
    static let zeroBalance = WalletSamples.summary.replacingOccurrences(
        of: "\"available_fen\":1000,\"withdrawable_fen\":1000", with: "\"available_fen\":0,\"withdrawable_fen\":0"
    )

    struct Opened {
        let fixture: WalletAppFixture
        let entry: WalletPageEntry
        let controller: WalletController
        /// 钱包页（发起页）的导航实例。
        let origin: UUID
        /// 打开钱包页之后、点击之前假服务记到的最大请求编号（只数这之后的 GET /v1/me）。
        let baseline: Int
    }

    /// 打开钱包页、等摘要到位且可见；核对前提：【提现】可点、余额 0、本会话还没查过实名。
    func openWallet(file: StaticString = #filePath, line: UInt = #line) async throws -> Opened {
        script.ok("GET /v1/wallet/summary", Self.zeroBalance)
        let fixture = make()
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.wallet), "钱包没有打开", file: file, line: line)
        let origin = try XCTUnwrap(fixture.router.path.last?.id, file: file, line: line)
        let controller = try XCTUnwrap(entry.controller as? WalletController, file: file, line: line)
        controller.load()
        await waitUntil("钱包摘要没有加载", file: file, line: line) { controller.state.phase == .content }
        await waitUntil("钱包页没有变为可见", file: file, line: line) { fixture.wallet.lastVisible[origin] == true }
        await settle()
        XCTAssertEqual(controller.state.summary?.withdrawableFen, 0, "前提：余额 0", file: file, line: line)
        XCTAssertTrue(controller.state.withdrawEnabled, "前提：【提现】可点", file: file, line: line)
        XCTAssertTrue(fixture.wallet.realnameState == nil, "前提：本会话还没查过实名", file: file, line: line)
        let baseline = WalletStubProtocol.requests.map(\.id).max() ?? 0
        return Opened(fixture: fixture, entry: entry, controller: controller, origin: origin, baseline: baseline)
    }

    /// 用户点【提现】：渲染时取出的按钮回调（与 WalletScreen 同一个构造）。
    func tapWithdraw(_ opened: Opened) {
        WalletActions.make(opened.controller, opened.controller.state).withdraw()
    }

    func meRequests(_ opened: Opened) -> [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("GET", "/v1/me").filter { $0.id > opened.baseline }
    }

    /// 发起页之上推入的路由（发起页已不在栈里时为整个栈）。
    func pushed(_ opened: Opened) -> [String] {
        let path = opened.fixture.router.path
        let above = path.firstIndex { $0.id == opened.origin }.map { path[($0 + 1)...] } ?? path[...]
        return above.map { $0.route ?? "(upgrade)" }
    }

    func top(_ opened: Opened) -> String? {
        opened.fixture.router.path.last?.route
    }

    /// 失败信息里的实得值：栈末尾路由、发起页之上推入的路由、发起页 openError、点击后 GET /v1/me 次数、Router 最近结论。
    func observed(_ opened: Opened) -> String {
        let router = opened.fixture.router
        let decision = router.lastDecision.map { "\($0.kindRaw)→\($0.route ?? "nil")" } ?? "nil"
        let onOrigin = router.path.last?.id == opened.origin ? "（发起页）" : ""
        return "实得：path 末尾=\(top(opened) ?? "空")\(onOrigin) 推入=\(pushed(opened)) "
            + "openError=\(opened.entry.context.openError?.key ?? "nil") GET /v1/me=\(meRequests(opened).count) 次 "
            + "lastDecision=\(decision)"
    }

    /// 点击后的 GET /v1/me 已发出并挂起（只这一次），返回它的请求编号。
    func heldMe(_ opened: Opened, _ name: String, file: StaticString = #filePath,
                line: UInt = #line) async throws -> Int {
        await waitUntil("\(name)：GET /v1/me 没有发出并挂起", file: file, line: line) {
            let sent = meRequests(opened)
            return sent.count == 1 && sent.allSatisfy { WalletStubProtocol.heldIds.contains($0.id) }
        }
        return try XCTUnwrap(meRequests(opened).first?.id, "\(name)：\(observed(opened))", file: file, line: line)
    }

    /// 放行挂起的 GET /v1/me；之后再有的 GET /v1/me 也给同一个回答（不再挂起）。
    func release(_ held: Int, with reply: WalletStubProtocol.Reply) {
        script.on("GET /v1/me", reply)
        WalletStubProtocol.release(held, with: reply)
    }
}

/// brief §3 第 1–5 条（第 6 条依赖实现方新增的 `WalletPageContext.isOpeningWithdraw`，在 FuIosWithdrawEntrySilentBusyTests）。
final class FuIosWithdrawEntrySilentTests: FuIosWithdrawEntrySilentTestCase {
    // MARK: - 第 1、2 条：零变化对照

    /// 第 1 条：余额 0、未实名 → 守卫按实名前置进 RealName；只发一次 GET /v1/me，不推 Withdraw。
    func testZeroBalanceUnverifiedOpensRealName() async throws {
        script.on("GET /v1/me", Self.unverified)
        let opened = try await openWallet()
        tapWithdraw(opened)
        await waitUntil("第 1 条：没有进 RealName") { top(opened) == WalletRoutes.realName }
        await quietWindow()
        XCTAssertEqual(pushed(opened), [WalletRoutes.realName], "第 1 条：恰好推一次 RealName。\(observed(opened))")
        let decision = opened.fixture.router.lastDecision
        XCTAssertEqual(decision?.kind, .requireRealname, "第 1 条：守卫结论是实名前置。\(observed(opened))")
        XCTAssertEqual(decision?.route, WalletRoutes.realName, "第 1 条：前置页是 RealName。\(observed(opened))")
        XCTAssertEqual(meRequests(opened).count, 1, "第 1 条：只发一次 GET /v1/me。\(observed(opened))")
    }

    /// 第 2 条：余额 0、已实名 → 进 Withdraw（参数为空）；只发一次 GET /v1/me。
    func testZeroBalanceVerifiedOpensWithdraw() async throws {
        script.on("GET /v1/me", Self.verified)
        let opened = try await openWallet()
        tapWithdraw(opened)
        await waitUntil("第 2 条：没有进 Withdraw") { top(opened) == WalletRoutes.withdraw }
        await quietWindow()
        XCTAssertEqual(pushed(opened), [WalletRoutes.withdraw], "第 2 条：恰好推一次 Withdraw。\(observed(opened))")
        XCTAssertEqual(opened.fixture.router.path.last?.params, [:], "第 2 条：参数为空。\(observed(opened))")
        XCTAssertEqual(meRequests(opened).count, 1, "第 2 条：只发一次 GET /v1/me。\(observed(opened))")
    }

    // MARK: - 第 3 条：查询在途的噪声不得让结果静默丢弃

    /// 第 3 条（一）：同值赋值 `router.path = router.path`（router.$path 发值、导航世代前进，栈不变）。
    func testPathReassignDuringQueryNotSilent() async throws {
        try await assertNotSilentAfterNoise("第 3 条·同值赋值 path") { fixture in
            fixture.router.path = fixture.router.path
        }
    }

    /// 第 3 条（二）：场景 inactive 再 active（下拉通知中心等过渡；可见世代前进两次）。
    func testSceneBlipDuringQueryNotSilent() async throws {
        try await assertNotSilentAfterNoise("第 3 条·inactive→active") { fixture in
            fixture.wallet.scenePhaseChanged(.inactive)
            fixture.wallet.scenePhaseChanged(.active)
        }
    }

    /// 第 3 条（三）：两种噪声都来。
    func testPathReassignAndSceneBlipDuringQueryNotSilent() async throws {
        try await assertNotSilentAfterNoise("第 3 条·同值赋值 + inactive→active") { fixture in
            fixture.router.path = fixture.router.path
            fixture.wallet.scenePhaseChanged(.inactive)
            fixture.wallet.scenePhaseChanged(.active)
        }
    }

    // MARK: - 第 4 条：本地取消类结果，发起页仍在 → openError

    /// 第 4 条：查询已登记、还没写出时，共用的 getMe 截止时间（`meReadGate`：「我的」/ 桥 auth.getUser 的 42901）开始 → 网络层发送前
    /// 最终准入本地结束 send_blocked；不是钱包自己的读禁用期拦下（probe 没记拒绝），74b66f3 归为 `.cancelled` 静默丢弃。发起页仍在栈顶、
    /// 前台、会话没换代 → 必须在发起页显示 openError，不当成未实名导航；【重试】可用。
    func testLocalCancelWhileOnOriginShowsOpenError() async throws {
        let opened = try await openWallet()
        let wallet = opened.fixture.wallet
        let gate = RetryAfterGate()
        wallet.meReadGate = gate
        let serial = wallet.realnameSerial
        tapWithdraw(opened)
        XCTAssertEqual(wallet.realnameSerial, serial + 1, "第 4 条前提：点击起了实名查询。\(observed(opened))")
        // 同步紧跟点击（查询任务还没开始执行）：截止时间开始
        gate.start(30000)
        await waitUntil("第 4 条：本地取消后发起页既没有 openError 也没有离开") {
            opened.entry.context.openError != nil || opened.fixture.router.path.last?.id != opened.origin
        }
        await quietWindow()
        XCTAssertEqual(meRequests(opened).count, 0, "第 4 条前提：请求没有写出（本地结束）。\(observed(opened))")
        XCTAssertNotNil(opened.entry.context.openError, "第 4 条：本地取消被静默丢弃。\(observed(opened))")
        XCTAssertEqual(pushed(opened), [], "第 4 条：读取失败不当成未实名继续导航。\(observed(opened))")
        XCTAssertEqual(opened.fixture.router.path.last?.id, opened.origin, "第 4 条：停在发起页。\(observed(opened))")

        gate.reset()
        opened.entry.context.retryOpen()
        await waitUntil("第 4 条：【重试】后没有进 Withdraw") { top(opened) == WalletRoutes.withdraw }
        XCTAssertEqual(meRequests(opened).count, 1, "第 4 条：【重试】发一次 GET /v1/me。\(observed(opened))")
    }

    /// 第 4 条的对照（74b66f3 即绿）：钱包自己的读禁用期在途开始（probe 记下拒绝）→ 按 42901 显示在发起页。证明观察手段看得见 openError。
    func testWalletReadGateInFlightShowsOpenErrorControl() async throws {
        let opened = try await openWallet()
        tapWithdraw(opened)
        opened.fixture.wallet.gates.read.start(30000)
        await waitUntil("对照：42901 没有显示在发起页") { opened.entry.context.openError != nil }
        XCTAssertEqual(opened.entry.context.openError?.key, "error.42901", "对照：\(observed(opened))")
        XCTAssertEqual(pushed(opened), [], "对照：不导航。\(observed(opened))")
        opened.fixture.wallet.gates.read.reset()
    }

    // MARK: - 第 5 条：真被覆盖 / 离开 / 换代仍静默（防修过头）

    /// 第 5 条（一）：查询在途推入别的页、结果到达时仍被盖着 → 不导航、不提示；退回发起页后也不补导航。
    func testCoveredAtArrivalStaysSilent() async throws {
        script.on("GET /v1/me", .hold)
        let opened = try await openWallet()
        tapWithdraw(opened)
        let held = try await heldMe(opened, "第 5 条·覆盖")
        opened.fixture.router.open(RouteRequest(route: WalletRoutes.help, from: .inApp))
        release(held, with: Self.unverified)
        await waitUntil("第 5 条·覆盖：实名结论没有到") { opened.fixture.wallet.realnameState != nil }
        await quietWindow()
        XCTAssertEqual(pushed(opened), [WalletRoutes.help], "第 5 条·覆盖：被盖住时不导航。\(observed(opened))")
        opened.fixture.router.path.removeLast()
        await quietWindow()
        assertSilent(opened, "第 5 条·覆盖后退回")
    }

    /// 第 5 条（二）：查询在途推入别的页又退回（被覆盖过），结果到达时发起页在栈顶 → 仍静默（同受保护用例的口径，未实名、带 openError 核对）。
    func testCoveredAndBackBeforeArrivalStaysSilent() async throws {
        script.on("GET /v1/me", .hold)
        let opened = try await openWallet()
        tapWithdraw(opened)
        let held = try await heldMe(opened, "第 5 条·覆盖又退回")
        opened.fixture.router.open(RouteRequest(route: WalletRoutes.help, from: .inApp))
        opened.fixture.router.path.removeLast()
        await waitUntil("第 5 条·覆盖又退回：发起页没有恢复可见") {
            opened.fixture.wallet.lastVisible[opened.origin] == true
        }
        release(held, with: Self.unverified)
        await waitUntil("第 5 条·覆盖又退回：实名结论没有到") { opened.fixture.wallet.realnameState != nil }
        await quietWindow()
        assertSilent(opened, "第 5 条·覆盖又退回")
    }

    /// 第 5 条（三）：查询在途离开发起页（出栈）→ 不导航。
    func testLeftOriginStaysSilent() async throws {
        script.on("GET /v1/me", .hold)
        let opened = try await openWallet()
        tapWithdraw(opened)
        let held = try await heldMe(opened, "第 5 条·离开")
        opened.fixture.router.path.removeAll()
        release(held, with: Self.unverified)
        await waitUntil("第 5 条·离开：实名结论没有到") { opened.fixture.wallet.realnameState != nil }
        await quietWindow()
        XCTAssertEqual(opened.fixture.router.path.map(\.route), [], "第 5 条·离开：不导航。\(observed(opened))")
    }

    /// 第 5 条（四）：查询在途退到后台、结果到达时仍在后台 → 不导航、不提示；回前台后也不补导航。
    func testBackgroundAtArrivalStaysSilent() async throws {
        script.on("GET /v1/me", .hold)
        let opened = try await openWallet()
        tapWithdraw(opened)
        let held = try await heldMe(opened, "第 5 条·后台")
        opened.fixture.wallet.scenePhaseChanged(.background)
        release(held, with: Self.unverified)
        await waitUntil("第 5 条·后台：实名结论没有到") { opened.fixture.wallet.realnameState != nil }
        await quietWindow()
        XCTAssertEqual(pushed(opened), [], "第 5 条·后台：在后台时不导航。\(observed(opened))")
        opened.fixture.wallet.scenePhaseChanged(.active)
        await quietWindow()
        assertSilent(opened, "第 5 条·后台后回前台")
    }

    /// 第 5 条（五）：查询在途会话换代（换账号）→ 旧查询作废，不导航、不提示。
    func testSessionChangedStaysSilent() async throws {
        script.on("GET /v1/me", .hold)
        let opened = try await openWallet()
        tapWithdraw(opened)
        let held = try await heldMe(opened, "第 5 条·换代")
        try opened.fixture.switchAccount(to: "user-b")
        release(held, with: Self.unverified)
        await quietWindow()
        assertSilent(opened, "第 5 条·换代")
    }

    // MARK: - 判据

    /// 静默：发起页仍在栈顶、之上没有推入任何页、发起页没有 openError。
    private func assertSilent(_ opened: Opened, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(opened.fixture.router.path.last?.id, opened.origin, "\(name)：应停在发起页。\(observed(opened))",
                       file: file, line: line)
        XCTAssertEqual(pushed(opened), [], "\(name)：不导航。\(observed(opened))", file: file, line: line)
        XCTAssertNil(opened.entry.context.openError, "\(name)：不提示。\(observed(opened))", file: file, line: line)
    }

    /// 第 3 条判据：查询挂起时注入噪声（发起页仍在栈顶、前台），放行「未实名」→ 最终进了 RealName（恰好一次、守卫实名前置），或停在发起页且
    /// openError 非空；两者都没有即红。任何情况下都不推 Withdraw。
    private func assertNotSilentAfterNoise(_ name: String, file: StaticString = #filePath, line: UInt = #line,
                                           _ inject: (WalletAppFixture) -> Void) async throws {
        script.on("GET /v1/me", .hold)
        let opened = try await openWallet(file: file, line: line)
        tapWithdraw(opened)
        let held = try await heldMe(opened, name, file: file, line: line)
        inject(opened.fixture)
        XCTAssertEqual(opened.fixture.router.path.last?.id, opened.origin, "\(name) 前提：噪声后发起页仍在栈顶",
                       file: file, line: line)
        XCTAssertTrue(opened.fixture.wallet.sceneActive, "\(name) 前提：前台", file: file, line: line)
        release(held, with: Self.unverified)
        await waitUntil("\(name)：结果到达后既没进 RealName 也没有 openError", file: file, line: line) {
            top(opened) == WalletRoutes.realName || opened.entry.context.openError != nil
        }
        await quietWindow()
        let reached = top(opened) == WalletRoutes.realName
        XCTAssertTrue(reached || opened.entry.context.openError != nil, "\(name)：查询结果被静默丢弃。\(observed(opened))",
                      file: file, line: line)
        XCTAssertEqual(pushed(opened), reached ? [WalletRoutes.realName] : [],
                       "\(name)：恰好推一次 RealName，或停在发起页提示。\(observed(opened))", file: file, line: line)
        if reached {
            XCTAssertEqual(opened.fixture.router.lastDecision?.kind, .requireRealname,
                           "\(name)：经守卫实名前置。\(observed(opened))", file: file, line: line)
        }
    }
}
