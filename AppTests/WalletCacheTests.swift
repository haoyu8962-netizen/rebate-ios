@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Router
import Wallet
import WalletCore
import XCTest

/// TECH-20 / G22：钱包断网显示上次数据（只缓存摘要、按账号隔离、只有传输层失败才用、5xxxx 不用）；登出、换账号、撤回同意、切换环境删除；
/// 42901 共享读禁用期在执行层与页面两处生效（共性第 13、27、32、46、55、62 条）。
@MainActor
final class WalletCacheTests: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    let script = WalletScript()

    override func setUpWithError() throws {
        suiteName = "WalletCacheTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        WalletStubProtocol.reset()
        script.install()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        WalletStubProtocol.reset()
    }

    func make() -> WalletAppFixture {
        WalletAppFixture.make(suiteName: suiteName, defaults: defaults)
    }

    func openWallet(_ fixture: WalletAppFixture) throws -> WalletController {
        try XCTUnwrap(fixture.open(WalletRoutes.wallet)?.controller as? WalletController)
    }

    /// 先成功加载、再断网冷启动（新页面实例）：显示缓存与旧数据提示，【提现】置灰；下拉成功后提示消失。
    func testStaleCacheAfterOfflineColdStartAndRecovery() async throws {
        let fixture = make()
        let first = try openWallet(fixture)
        first.load()
        await waitUntil { first.state.summary != nil }
        fixture.router.path.removeAll()
        script.on("GET /v1/wallet/summary", .disconnect)
        let second = try openWallet(fixture)
        second.load()
        await waitUntil("断网时应显示缓存") { second.state.staleAt != nil }
        XCTAssertEqual(second.state.summary?.withdrawableFen, 1000)
        XCTAssertTrue(second.state.staleNetwork)
        XCTAssertFalse(second.state.withdrawEnabled, "旧数据【提现】置灰")
        script.ok("GET /v1/wallet/summary", WalletSamples.summary)
        second.refresh()
        await waitUntil("刷新成功后提示条消失") { second.state.staleAt == nil }
        XCTAssertTrue(second.state.withdrawEnabled)
    }

    /// 5xxxx 不用缓存、不伪装成余额为 0：显示错误态，文案带 trace6（未收录的 5xxxx 回落 error.50001，trace6 独立追加）。
    func testServerErrorDoesNotUseCacheAndShowsTrace6() async throws {
        let fixture = make()
        let first = try openWallet(fixture)
        first.load()
        await waitUntil { first.state.summary != nil }
        fixture.router.path.removeAll()
        script.fail("GET /v1/wallet/summary", 50999)
        let second = try openWallet(fixture)
        second.load()
        await waitUntil { second.state.phase == .error }
        XCTAssertNil(second.state.summary)
        let message = try XCTUnwrap(second.state.error?.message(WalletDraftTexts()))
        XCTAssertTrue(message.contains("6789ab"), "trace6 独立追加")
        XCTAssertEqual(second.state.error?.key, "error.50001")
        // 已收录但文案无 {trace6} 占位的 5xxxx 也追加（APP-08 共性第 16 条）
        let notice = Notice("error.30306", id: 1, traceId: "abc123456789", showTrace6: true)
        XCTAssertTrue(notice.message(WalletDraftTexts()).contains("456789"))
    }

    /// 登出、换账号、撤回同意、切换环境后缓存被删（G22）。
    func testCacheClearedOnAccountSwitchWithdrawalAndEnvironmentSwitch() async throws {
        let fixture = make()
        let controller = try openWallet(fixture)
        controller.load()
        await waitUntil { controller.state.summary != nil }
        // FU-IOS-0712 R1-01：缓存读写必须带固定身份的登录世代（原来存储自己读当前世代）；这里取页面固定身份的那一份，断言不变
        let ownerA = controller.state.owner
        XCTAssertNotNil(fixture.cleaner.store.read(account: "user-a", loginEpoch: ownerA.loginEpoch))
        try fixture.switchAccount(to: "user-b")
        XCTAssertNil(
            fixture.cleaner.store.read(account: "user-a", loginEpoch: ownerA.loginEpoch), "换账号删除别的账号的缓存"
        )
        // 撤回同意：清理注册表里的钱包清理项删缓存，并作废内存里的页面
        controller.load()
        await waitUntil { controller.state.summary != nil && controller.state.owner.account == "user-b" }
        let ownerB = controller.state.owner
        XCTAssertNotNil(fixture.cleaner.store.read(account: "user-b", loginEpoch: ownerB.loginEpoch))
        try fixture.cleaner.cleanForEnvironmentSwitch()
        XCTAssertNil(
            fixture.cleaner.store.read(account: "user-b", loginEpoch: ownerB.loginEpoch), "切换环境 / 撤回同意的清理项删除缓存"
        )
        XCTAssertEqual(fixture.wallet.clearedCount, 1)
        XCTAssertNil(controller.state.summary, "清理后内存里的显示同步作废")
    }

    /// 42901：Retry-After 写入共享读禁用期；之后的读取在执行层被拦下（零请求），页面按限流结算（保留旧数据、旧数据提示、【提现】置灰）。
    func testRetryAfterSharedReadGateBlocksAtExecutionLayer() async throws {
        let fixture = make()
        let controller = try openWallet(fixture)
        controller.load()
        await waitUntil { controller.state.summary != nil }
        script.fail("GET /v1/wallet/summary", 42901, headers: ["Retry-After": "30"])
        controller.refresh()
        await waitUntil { fixture.gates.read.active }
        XCTAssertEqual(fixture.gates.read.remainingMillis > 25000, true, "按 Retry-After 30 秒")
        let before = WalletStubProtocol.requests("GET", "/v1/wallet/summary").count
        XCTAssertFalse(controller.refresh(), "禁用期内不发")
        XCTAssertEqual(WalletStubProtocol.requests("GET", "/v1/wallet/summary").count, before)
        XCTAssertNotNil(controller.state.staleAt, "保留的摘要转为旧数据")
        XCTAssertFalse(controller.state.withdrawEnabled)
        // 执行层：绕过页面直接发同一类读请求也被发送前闸门拦下，零写出
        let probe = fixture.gates.read.probe()
        let result = await fixture.network.client.send(
            ApiCall(operationId: "getWalletSummary"), isValid: { true }, sendAllowed: probe.allowed, expected: nil
        )
        XCTAssertEqual(result, .localReject(reason: LocalRejectReason.sendBlocked))
        XCTAssertTrue(probe.gated(result))
        XCTAssertEqual(WalletStubProtocol.requests("GET", "/v1/wallet/summary").count, before)
    }
}

extension WalletAppFixture {
    var gates: WalletGates {
        wallet.gates
    }
}
