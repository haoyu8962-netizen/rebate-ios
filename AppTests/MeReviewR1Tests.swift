import BridgeHost
import ClientCore
@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import Push
import Router
import XCTest

/// R1-01：设备级偏好的删除按文件系统确认（不以内存回读当落盘），跨进程（新实例读同一目录）恢复与存储失败。
@MainActor
final class MeLocalStoreR1Tests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("me-prefs-r1-" + UUID().uuidString, isDirectory: true)

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var prefsFile: ClientFile {
        ClientFile(name: MeLocalStore.fileName, baseDirectory: directory)
    }

    private func flakyStore(failDelete: Bool) -> (MeLocalStore, FlakyMeFile) {
        let file = FlakyMeFile(prefsFile)
        file.failDelete = failDelete
        return (MeLocalStore(file: file, pending: file.sibling(MeLocalStore.pendingFileName)), file)
    }

    /// 写入落盘后新进程（同目录的新实例）读得到；清理成功后盘上偏好文件与作废标记都不在，新进程读缺省值。
    func testPrefsPersistAcrossProcessAndClearIsConfirmedOnDisk() throws {
        let first = MeLocalStore(baseDirectory: directory)
        XCTAssertTrue(first.setPersonalization(false, now: 7))
        XCTAssertTrue(first.markGuideClosed(9))
        let second = MeLocalStore(baseDirectory: directory)
        XCTAssertFalse(second.personalizationOn)
        XCTAssertTrue(second.personalizationOffNow)
        XCTAssertEqual(second.guideClosedAt, 9)
        XCTAssertEqual(second.personalizationChangedAt, 7)
        try second.clearAll()
        XCTAssertNil(try prefsFile.read(), "偏好文件已删除（按文件系统确认）")
        XCTAssertNil(try prefsFile.sibling(MeLocalStore.pendingFileName).read(), "确认之后才删作废标记")
        let third = MeLocalStore(baseDirectory: directory)
        XCTAssertTrue(third.personalizationOn)
        XCTAssertNil(third.guideClosedAt)
        XCTAssertFalse(third.clearPending)
    }

    /// 删除失败：抛错、待清理保留（盘上有作废标记）；本进程不读回旧值、也不写。新进程删除仍失败 → 按缺省值读；新进程存储恢复 → 读之前先完成清理。
    func testClearFailureKeepsPendingAcrossProcess() throws {
        let (store, file) = flakyStore(failDelete: false)
        XCTAssertTrue(store.setPersonalization(false, now: 1))
        XCTAssertTrue(store.markGuideClosed(2))
        file.failDelete = true
        XCTAssertThrowsError(try store.clearAll(), "删不掉不得报成功")
        XCTAssertTrue(store.clearPending)
        XCTAssertNotNil(try prefsFile.sibling(MeLocalStore.pendingFileName).read(), "作废标记已落盘")
        XCTAssertNil(store.guideClosedAt, "待清理期间不读回旧数据")
        XCTAssertTrue(store.personalizationOn)
        XCTAssertFalse(store.markGuideClosed(3), "待清理期间不写")

        let (stuck, _) = flakyStore(failDelete: true)
        XCTAssertNil(stuck.guideClosedAt, "新进程删除仍失败：按缺省值读")
        XCTAssertTrue(stuck.personalizationOn)
        XCTAssertTrue(stuck.clearPending)

        let recovered = MeLocalStore(baseDirectory: directory)
        XCTAssertNil(recovered.guideClosedAt)
        XCTAssertTrue(recovered.personalizationOn)
        XCTAssertFalse(recovered.clearPending, "新进程读之前已完成清理")
        XCTAssertNil(try prefsFile.read())
    }
}

/// 第 1 轮评审修复（R1-01…R1-07）的 App 接线测试：经真实 ApiClient、Router 与页面渲染时取出的回调。
@MainActor
final class MeReviewR1Tests: MeTestCase {
    private func settings(_ fixture: MeAppFixture) throws -> SettingsController {
        let entry = try XCTUnwrap(fixture.open("Settings"))
        entry.appeared()
        return try XCTUnwrap(entry.controller() as? SettingsController)
    }

    private func center(_ fixture: MeAppFixture) throws -> PrivacyCenterController {
        let entry = try XCTUnwrap(fixture.open("PrivacyCenter"))
        entry.appeared()
        return try XCTUnwrap(entry.controller() as? PrivacyCenterController)
    }

    private var reports: [WalletStubProtocol.Recorded] {
        requests("POST", "/v1/devices/push-token")
    }

    private func supported(_ fixture: MeAppFixture) async {
        await waitUntil("强更检查没结果") { fixture.me.updateRaw() == "supported" }
        fixture.me.syncIdentity()
    }

    /// R1-01：撤回清理里设备级偏好删不掉 → 全局待清理标记保留、凭据不可读；存储恢复后重试才解除。
    func testWithdrawCleanupKeepsGlobalPendingUntilPrefsDeleted() {
        let fixture = make()
        XCTAssertTrue(fixture.local.markGuideClosed(5))
        fixture.localFile.failDelete = true
        XCTAssertFalse(fixture.runner.run().isEmpty, "偏好清理项失败")
        XCTAssertTrue(fixture.runner.isPending, "确认删除之前不解除全局待清理标记")
        XCTAssertFalse(fixture.runner.credentialsReadable)
        XCTAssertNil(fixture.local.guideClosedAt)
        fixture.localFile.failDelete = false
        XCTAssertTrue(fixture.runner.retryIfPending())
        XCTAssertFalse(fixture.runner.isPending)
        XCTAssertFalse(fixture.local.clearPending)
    }

    /// R1-02：桥 auth.getUser 的 42901 —— 同一会话照常写共享读取闸门；网络结果已返回、主线程结算之前换了账号 → 旧结果不写闸门（不限流 B）。
    func testBridgeLate42901AfterSwitchDoesNotGateNewSession() async {
        let fixture = make()
        let gate = fixture.me.gates.read
        let network = fixture.network
        script.fail("GET /v1/me", 42901, headers: ["Retry-After": "60"])
        _ = await AppBridgeServices.user(
            client: fixture.client, gate: gate, owner: { network.ownershipNow() }, validity: BridgeCallValidity()
        )
        XCTAssertTrue(gate.active, "同一会话的 42901 写共享闸门")
        gate.reset()

        // 网络结果（A 的 42901）已经返回、在主线程结算的那一刻之前换成 B 并同步身份（共享闸门随之重置）：结算时第二次取归属的钩子里换号
        var reads = 0
        let owner: @MainActor () -> RequestOwnership? = {
            reads += 1
            if reads == 2 {
                try? fixture.switchAccount(to: "user-b")
                fixture.me.syncIdentity()
            }
            return network.ownershipNow()
        }
        _ = await AppBridgeServices.user(
            client: fixture.client, gate: gate, owner: owner, validity: BridgeCallValidity()
        )
        await settle()
        XCTAssertFalse(gate.active, "A 的迟到 42901 不得限流 B")
        XCTAssertEqual(network.ownershipNow().account, "user-b")
    }

    /// R1-03：撤回确认通过后、外层 Task 执行之前换了账号 → 撤回记录按确认时的归属零发送（不发给 B 的会话），本地撤回照常完成。
    func testWithdrawRecordBoundToConfirmOwnership() async throws {
        let fixture = make()
        let controller = try center(fixture)
        PrivacyCenterActions.make(controller, controller.state).askWithdraw()
        PrivacyCenterActions.make(controller, controller.state).confirmWithdraw(try XCTUnwrap(controller.state.dialog))
        try fixture.switchAccount(to: "user-b")
        await waitUntil("本地撤回没完成") { fixture.me.privacy.state.decision == .basicMode }
        await settle()
        XCTAssertTrue(requests("POST", "/v1/consents").isEmpty, "旧确认的撤回记录不发给新会话")
        XCTAssertFalse(fixture.me.deps.withdraw.busy)
    }

    /// R1-04：退出确认之后、Task 执行之前已保存 B 会话 → 不发 logout、不退出 B。
    func testLogoutBoundToConfirmOwnershipKeepsNewSession() async throws {
        let fixture = make()
        let controller = try settings(fixture)
        SettingsActions.make(controller, controller.state).askLogout()
        SettingsActions.make(controller, controller.state).confirmLogout(try XCTUnwrap(controller.state.dialog))
        try fixture.switchAccount(to: "user-b")
        await waitUntil("退出流程没结束") { !fixture.me.loggingOutNow }
        await settle()
        XCTAssertTrue(fixture.login.loggedIn, "B 仍登录")
        XCTAssertEqual(fixture.network.ownershipNow().account, "user-b")
        XCTAssertTrue(requests("POST", "/v1/auth/logout").isEmpty, "不带 B 的会话发 logout")
    }

    /// R1-05 / R1-06：已有快照时设置页刷新失败也呈现（统一文案 + trace6）与受共享读取闸门约束的【重试】；42901 禁用期开始即置灰、到期即恢复。
    func testSettingsRefreshFailureWithSnapshotAndGatedRetry() async throws {
        let fixture = make()
        _ = await loadedTab(fixture)
        XCTAssertNotNil(fixture.me.deps.repo.state.me)
        script.fail("GET /v1/me", 50001)
        let controller = try settings(fixture)
        let repo = fixture.me.deps.repo
        await waitUntil("刷新失败没呈现") { controller.accountNotice(repo.state) != nil }
        let notice = try XCTUnwrap(controller.accountNotice(repo.state))
        XCTAssertTrue(notice.refreshFailed)
        let text = notice.message(fixture.me.deps.texts)
        XCTAssertTrue(text.contains("6789ab"), "带 trace6：\(text)")
        XCTAssertNotNil(repo.me(of: controller.identity), "旧资料保留")
        XCTAssertFalse(controller.readBlocked)

        script.fail("GET /v1/me", 42901, headers: ["Retry-After": "1"])
        SettingsActions.make(controller, controller.state).retryMe()
        await waitUntil("42901 没呈现") { controller.accountNotice(repo.state)?.notice.key == MeCodes.rateKey }
        XCTAssertTrue(controller.readBlocked, "禁用期开始即置灰")
        await waitUntil("到期没恢复", timeout: 5) { !controller.readBlocked }
    }

    /// R1-06：「重新显示下单须知」行按 resetTip 闸门置灰，到期恢复。
    func testResetTipRowFollowsGate() async throws {
        let fixture = make()
        let controller = try settings(fixture)
        XCTAssertFalse(controller.resetTipBlocked)
        script.fail("DELETE /v1/me/tips/jump_tip", 42901, headers: ["Retry-After": "1"])
        let row = try XCTUnwrap(controller.model().groups.flatMap(\.rows).first { $0.id == "重新显示下单须知" })
        SettingsActions.make(controller, controller.state).row(row)
        await waitUntil("禁用期没开始") { controller.resetTipBlocked }
        await waitUntil("到期没恢复", timeout: 5) { !controller.resetTipBlocked }
    }

    /// R1-07：上报在途时令牌变化（待报）→ 在途那条 42901、Retry-After=60 → 先结算禁用期，禁用期内不补发待报、新的令牌变化也不发。
    func testReport42901SettlesRetryAfterBeforePending() async throws {
        let fixture = make(account: nil, pushToken: "t1")
        await supported(fixture)
        script.on("POST /v1/devices/push-token", .hold)
        try fixture.loginCompleted(as: "user-b")
        await waitUntil("登录成功没上报") { self.reports.count == 1 }
        fixture.push.change("t2")
        await settle()
        script.ok("POST /v1/devices/push-token", "{}")
        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first),
                                   with: .envelope(code: 42901, data: "null", headers: ["Retry-After": "60"]))
        await waitUntil("42901 没结算") { fixture.me.push.limited }
        await settle()
        XCTAssertEqual(reports.count, 1, "禁用期内不补发待报")
        fixture.push.change("t3")
        await settle()
        XCTAssertEqual(reports.count, 1, "禁用期内的新触发也不发")
        XCTAssertGreaterThan(fixture.me.push.gate.remainingMillis, 50000)
    }

    /// R1-07：Retry-After 非法按 5 秒；失败的旧请求不自动重试。Retry-After=1 时禁用期内的令牌变化到期后补发一次最新值。
    func testReport42901DefaultsAndDeferredTriggerSendsOnce() async {
        script.fail("POST /v1/devices/push-token", 42901, headers: ["Retry-After": "abc"])
        let fixture = make(pushToken: "t1")
        await supported(fixture)
        await waitUntil("42901 没结算") { fixture.me.push.limited }
        let remaining = fixture.me.push.gate.remainingMillis
        XCTAssertGreaterThan(remaining, 3000)
        XCTAssertLessThanOrEqual(remaining, 5000)
        await settle()
        XCTAssertEqual(reports.count, 1, "失败的旧请求不自动重试")

        script.fail("POST /v1/devices/push-token", 42901, headers: ["Retry-After": "1"])
        let short = make(pushToken: "s1")
        await supported(short)
        await waitUntil("42901 没结算") { short.me.push.limited }
        script.ok("POST /v1/devices/push-token", "{}")
        let before = reports.count
        short.push.change("s2")
        await settle()
        XCTAssertEqual(reports.count, before, "禁用期内不发")
        await waitUntil("到期没补发", timeout: 5) { self.reports.count == before + 1 }
        XCTAssertEqual(reports.last?.json["token"] as? String, "s2")
        await settle(50)
        XCTAssertEqual(reports.count, before + 1, "只补一次")
    }
}
