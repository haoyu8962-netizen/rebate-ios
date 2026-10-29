@testable import Couli
import Foundation
import Router
import Wallet
import WalletCore
import XCTest

/// FU-IOS-0733（F-IOS-52；APP-09v 评审 r2 S2-1，变异 M1a）：提现门槛的最后一道守卫在执行器 `WalletController.withdraw`
/// （`state.withdrawEnabled`）。页面侧置灰之外，门槛不满足时**直接调执行器**——带当前快照的版本与身份，版本 / 身份核对必然放行，
/// 拒绝只能来自门槛——也必须拒绝：
/// - 同步：执行器不发起导航（导航世代不变）、不起实名查询（GET /v1/me 的查询序号不变）、快照不变；
/// - 等满观察窗（1.5 秒，在途的异步请求与其后的导航都已落定）：Router 栈与 Tab 根不变、零请求（不取 getMe、不取 rules、不发提现），
///   发起页上不出现打开失败的提示。
/// 每组都带同一调用在门槛满足时的正向对照（恰好进一次 Withdraw），证明这些观察手段看得见导航，不是恒绿。
@MainActor
final class WalletWithdrawGuardTests: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    let script = WalletScript()

    override func setUpWithError() throws {
        suiteName = "WalletWithdrawGuardTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        WalletStubProtocol.reset()
        script.install()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        WalletStubProtocol.reset()
    }

    private struct Opened {
        let fixture: WalletAppFixture
        let entry: WalletPageEntry
        let controller: WalletController
    }

    private func open(_ summary: String = WalletSamples.summary, realnameKnown: Bool = false) async throws -> Opened {
        script.ok("GET /v1/wallet/summary", summary)
        let fixture = WalletAppFixture.make(suiteName: suiteName, defaults: defaults)
        if realnameKnown {
            // 本会话已查清实名：生产出口不再先取 getMe，导航是同步的
            fixture.wallet.realnameChanged()
            await waitUntil("实名状态没取到") { fixture.wallet.realnameVerified() }
        }
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.wallet), "钱包没有打开")
        let controller = try XCTUnwrap(entry.controller as? WalletController)
        controller.load()
        await waitUntil("钱包摘要没有加载") { controller.state.summary != nil || controller.state.phase == .error }
        return Opened(fixture: fixture, entry: entry, controller: controller)
    }

    private static func replacing(_ from: String, _ to: String) -> String {
        WalletSamples.summary.replacingOccurrences(of: from, with: to)
    }

    private static let negative = replacing("\"negative_fen\":0", "\"negative_fen\":200")
    private static let disabled = replacing("\"withdraw_enabled\":true", "\"withdraw_enabled\":false")

    // MARK: - 门槛不满足：执行器拒绝

    /// 待抵扣（negative_fen > 0）、withdraw_enabled=false；实名未查（生产出口会先异步取 getMe）。
    func testSummaryThresholdRefusedAtExecutor() async throws {
        for (name, summary) in [("待抵扣", Self.negative), ("withdraw_enabled=false", Self.disabled)] {
            let opened = try await open(summary)
            XCTAssertEqual(opened.controller.state.phase, .content, "\(name)：前提——摘要已到")
            await assertExecutorRefuses(opened, name)
        }
        try await assertControlOpensWithdraw(realnameKnown: false)
    }

    /// 同上两种门槛，但本会话已查清实名（生产出口同步导航）：执行器放行的话 Router 会立刻入栈。
    func testSummaryThresholdRefusedAtExecutorWithRealnameKnown() async throws {
        for (name, summary) in [("待抵扣", Self.negative), ("withdraw_enabled=false", Self.disabled)] {
            let opened = try await open(summary, realnameKnown: true)
            XCTAssertTrue(opened.fixture.wallet.realnameVerified(), "\(name)：前提——实名已查清")
            await assertExecutorRefuses(opened, "\(name)（实名已查清）")
        }
        try await assertControlOpensWithdraw(realnameKnown: true)
    }

    /// 旧数据（G-W05）：断网冷启动显示缓存；已有摘要后读取失败（5xxxx，独立错误 + 更新于）；42901 共享读禁用期中。
    func testStaleDataRefusedAtExecutor() async throws {
        // 断网缓存：先在线成功一次写缓存，再断网打开新页面
        let online = try await open()
        online.fixture.router.path.removeAll()
        script.on("GET /v1/wallet/summary", .disconnect)
        let entry = try XCTUnwrap(online.fixture.open(WalletRoutes.wallet))
        let offline = try XCTUnwrap(entry.controller as? WalletController)
        offline.load()
        await waitUntil("断网时应显示缓存") { offline.state.staleAt != nil }
        XCTAssertNotNil(offline.state.summary, "断网缓存：前提——显示的是缓存摘要")
        await assertExecutorRefuses(Opened(fixture: online.fixture, entry: entry, controller: offline), "断网缓存")

        // 已有摘要后 5xxxx：保留旧数据、显示错误
        let failed = try await open()
        script.fail("GET /v1/wallet/summary", 50001)
        failed.controller.refresh()
        await waitUntil("刷新失败应转为旧数据") { failed.controller.state.error != nil }
        XCTAssertNotNil(failed.controller.state.staleAt, "5xxxx：前提——旧数据")
        await assertExecutorRefuses(failed, "已有摘要后 5xxxx")

        // 42901：共享读禁用期中（生产出口的实名查询也被同一禁用期拦，不发请求，但会在发起页留提示——同样不许出现）
        let gated = try await open()
        script.fail("GET /v1/wallet/summary", 42901, headers: ["Retry-After": "30"])
        gated.controller.refresh()
        await waitUntil("42901 应写入禁用期") { gated.fixture.gates.read.active }
        XCTAssertNotNil(gated.controller.state.staleAt, "42901：前提——旧数据")
        await assertExecutorRefuses(gated, "42901 禁用期")
    }

    /// 没有摘要：首次加载中（摘要请求挂起）、首次加载失败（5xxxx 错误态，不伪装成余额为 0）。
    func testNoSummaryRefusedAtExecutor() async throws {
        let failed = try await open(WalletSamples.summary)
        failed.fixture.router.path.removeAll()
        script.fail("GET /v1/wallet/summary", 50001)
        let entry = try XCTUnwrap(failed.fixture.open(WalletRoutes.wallet))
        let errored = try XCTUnwrap(entry.controller as? WalletController)
        errored.load()
        await waitUntil("首次加载失败应进错误态") { errored.state.phase == .error }
        XCTAssertNil(errored.state.summary, "错误态：前提——没有摘要")
        await assertExecutorRefuses(Opened(fixture: failed.fixture, entry: entry, controller: errored), "首次加载失败")

        failed.fixture.router.path.removeAll()
        script.on("GET /v1/wallet/summary", .hold)
        let held = WalletStubProtocol.requests("GET", "/v1/wallet/summary").count
        let loadingEntry = try XCTUnwrap(failed.fixture.open(WalletRoutes.wallet))
        let loading = try XCTUnwrap(loadingEntry.controller as? WalletController)
        loading.load()
        await waitUntil("摘要请求应已发出并挂起") {
            WalletStubProtocol.requests("GET", "/v1/wallet/summary").count > held && !WalletStubProtocol.heldIds.isEmpty
        }
        XCTAssertEqual(loading.state.phase, .loading, "加载中：前提")
        XCTAssertNil(loading.state.summary, "加载中：前提——没有摘要")
        await assertExecutorRefuses(
            Opened(fixture: failed.fixture, entry: loadingEntry, controller: loading), "首次加载中"
        )
        for id in WalletStubProtocol.heldIds {
            WalletStubProtocol.release(id, with: .disconnect)
        }
    }

    // MARK: - 判据

    /// 门槛不满足时直接调执行器（当前版本与身份）：同步不发起导航、不起实名查询、快照不变；等满观察窗后零导航、零请求、发起页无提示。
    private func assertExecutorRefuses(_ opened: Opened, _ name: String, file: StaticString = #filePath,
                                       line: UInt = #line) async {
        let fixture = opened.fixture
        let controller = opened.controller
        let state = controller.state
        XCTAssertFalse(state.withdrawEnabled, "\(name)：前提——门槛不满足", file: file, line: line)
        XCTAssertTrue(fixture.wallet.isCurrent(state.owner), "\(name)：前提——身份是当前会话（拒绝只能来自门槛）",
                      file: file, line: line)
        let generation = controller.visibility.generation
        let serial = fixture.wallet.realnameSerial
        let path = fixture.router.path
        let tab = fixture.router.tabRoot
        let before = WalletStubProtocol.requests.count
        let calls = Self.apiCalls(fixture)

        controller.withdraw(version: state.version, owner: state.owner)

        XCTAssertEqual(controller.visibility.generation, generation, "\(name)：执行器发起了导航", file: file, line: line)
        XCTAssertEqual(fixture.wallet.realnameSerial, serial, "\(name)：执行器起了实名查询（GET /v1/me）",
                       file: file, line: line)
        XCTAssertEqual(fixture.router.path, path, "\(name)：执行器同步导航了", file: file, line: line)
        XCTAssertEqual(controller.state, state, "\(name)：拒绝不改快照", file: file, line: line)

        await quietWindow()

        XCTAssertEqual(fixture.router.path, path, "\(name)：观察窗后零导航（栈）", file: file, line: line)
        XCTAssertEqual(fixture.router.tabRoot, tab, "\(name)：观察窗后零导航（Tab）", file: file, line: line)
        let after = WalletStubProtocol.requests.dropFirst(before).map { "\($0.method) \($0.path)" }
        XCTAssertEqual(after, [], "\(name)：观察窗后零请求（含 GET /v1/me、rules、POST /v1/withdrawals）", file: file, line: line)
        XCTAssertEqual(Self.apiCalls(fixture), calls, "\(name)：钱包调用入口零调用（摘要、rules、提现、收款账号）",
                       file: file, line: line)
        XCTAssertNil(opened.entry.context.openError, "\(name)：发起页不出现打开失败提示", file: file, line: line)
        XCTAssertEqual(controller.state, state, "\(name)：观察窗后快照不变", file: file, line: line)
    }

    /// 钱包调用入口（生产 `AppWallet(api:)` 注入的透明计数）上与提现相关的调用次数。
    private static func apiCalls(_ fixture: WalletAppFixture) -> [String: Int] {
        let operations = [
            WalletController.operation, "getWithdrawRules", "createWithdrawal", "getPayoutAccount",
            "confirm:createWithdrawal", "abandon:createWithdrawal",
        ]
        return Dictionary(uniqueKeysWithValues: operations.map { ($0, fixture.api.calls($0)) })
    }

    /// 正向对照：门槛满足时同一调用恰好进一次 Withdraw（空参数），导航世代加一；实名未查时只取一次 getMe，已查清时零请求。
    private func assertControlOpensWithdraw(realnameKnown: Bool, file: StaticString = #filePath,
                                            line: UInt = #line) async throws {
        let opened = try await open(realnameKnown: realnameKnown)
        let controller = opened.controller
        let state = controller.state
        XCTAssertTrue(state.withdrawEnabled, "对照：门槛满足", file: file, line: line)
        let generation = controller.visibility.generation
        let before = WalletStubProtocol.requests.count
        controller.withdraw(version: state.version, owner: state.owner)
        // 执行器发起导航时导航世代加一；实名已查清时生产出口同步入栈，钱包页随即被盖住、世代再加一，所以只要求「变了」
        XCTAssertGreaterThan(controller.visibility.generation, generation, "对照：执行器发起导航", file: file, line: line)
        await waitUntil("对照：没有进 Withdraw", file: file, line: line) {
            opened.fixture.router.path.last?.route == WalletRoutes.withdraw
        }
        await quietWindow()
        let pushed = opened.fixture.router.path.filter { $0.route == WalletRoutes.withdraw }
        XCTAssertEqual(pushed.count, 1, "对照：恰好一次", file: file, line: line)
        XCTAssertEqual(pushed.first?.params, [:], "对照：空参数", file: file, line: line)
        let after = WalletStubProtocol.requests.dropFirst(before).map { "\($0.method) \($0.path)" }
        XCTAssertEqual(after, realnameKnown ? [] : ["GET /v1/me"], "对照：请求只有实名查询", file: file, line: line)
    }
}
