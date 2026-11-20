@testable import Couli
import CouliNetwork
import Foundation
import MeCore
import Session
import WalletCore
import XCTest

/// FU-IOS-WALLETSETTLEMENT-SCOPE 写测 (a) 组「错写」：受限页（deletion_only）上点【确认】/【放弃】/首次【申请注销】，网络层先在受限会话
/// 屏障上等一次刷新，刷新回来作用域变成 full（他端已撤回等）→ 旧作用域的写请求不得写出（任务书 §1 (a)、§2 第 1、2 条）。
/// 被拦时未决记录保留（不删、不换键、原体不变），页面不当成 42901；重建后的新页按记录重建待确认卡。
/// (a-对照)：刷新回来作用域没变，照常写出 1 次（防「一律拦」）。
///
/// 现状（改前）为什么红：注销 flow 的发送前闸门只有 42901 禁用期（SensitiveFlow.swift `gate.probe()`、SensitiveFlow+Pending.swift
/// `target(_:)` 的 `gate.sendAllowed`），网络层 `expected` 也不比作用域；屏障刷新回来后 admit / sendOnce 照常放行 → 传输层多写出一次。
/// 改后为什么绿：发送前闸门 = 42901 闸门且「此刻作用域 == 注销 flow 构造时固定的作用域」，网络层每次实际写出前都调 → 刷新后本地
/// send_blocked、零写出；没写出的确认 / 放弃由网络层释放占用，记录回到 unknown。
@MainActor
final class FuIosWalletSettlementScopeSendTests: FuIosWalletSettlementScopeTestCase {
    /// 点击后等写请求进到屏障等待（记录已被占用为 in_flight 后再让一轮主线程任务跑完）。
    private func waitClaimed(_ fixture: WalletAppFixture) async {
        await waitUntil("确认 / 放弃没有占用未决记录") {
            self.deletionRecords(fixture).first?.stateRaw == PendingKeyStore.inFlight
        }
        await settle()
    }

    /// 写请求结束（占用释放或记录被结算）后再走一次会话同步出口（作用域变了就按新作用域重建注销页）。
    private func waitSettled(_ fixture: WalletAppFixture) async {
        await waitUntil("确认 / 放弃没有结束") {
            self.deletionRecords(fixture).first?.stateRaw != PendingKeyStore.inFlight
        }
        await quietWindow(0.5)
        fixture.wallet.checkSession()
        await settle()
    }

    /// 被作用域拦下后：记录仍在、键与原体不变、仍是 unknown；作用域 full 后重建的新页按记录重建待确认卡；没有 42901。
    private func assertKept(_ fixture: WalletAppFixture, _ record: PendingKeyRecord,
                            _ host: MePageHost<DeleteAccountController>, old: DeleteAccountController,
                            _ what: String) async throws {
        let after = try XCTUnwrap(deletionRecords(fixture).first, "\(what)：未决记录仍在")
        XCTAssertEqual(after.key, record.key, "\(what)：键不变")
        XCTAssertEqual(Data(after.body.utf8), Data(record.body.utf8), "\(what)：原体逐字节不变")
        XCTAssertEqual(after.stateRaw, PendingKeyStore.unknown, "\(what)：仍待确认（不进结束、不当成已发出）")
        XCTAssertTrue(after.everUnknown, "\(what)：仍是结果未知过的键")
        let rebuilt = host.controller
        XCTAssertFalse(rebuilt === old, "前提：作用域变成 full 后注销页按新作用域重建")
        XCTAssertEqual(rebuilt.identity.scope, DeletionScope.full)
        await waitUntil("\(what)：新页没有按本机记录重建待确认卡") { rebuilt.flow.state.pending?.key == record.key }
        XCTAssertFalse(fixture.gates.deletion.active, "\(what)：作用域拦截不写 42901 禁用期")
        assertNoRateLimitText([old, rebuilt], what)
    }

    // MARK: - (a1) 确认

    /// (a1) 受限页待确认卡点【确认】：点击时 deletion_only，网络层刷新期间作用域变 full → 确认请求零写出，记录、键、原体不变。
    /// 现状红：刷新回来后旧键原体照样写出（POST /v1/me/deletion 第 2 次），成功后记录被删。改后绿：作用域项拦下，零写出、记录保留。
    func testA1ConfirmSendsNothingWhenRefreshTurnsScopeFull() async throws {
        let fixture = restrictedFixture()
        let host = try await openDeletionPage(fixture)
        let old = host.controller
        let record = try await enterDeletionPending(fixture, old)
        script.on(Self.deletionWrite, Self.coolingReply)
        let refresh = try await holdNextRefresh(fixture)

        deletionActions(old).confirm()
        await waitClaimed(fixture)
        XCTAssertEqual(sent(Self.deletionWrite).count, 1, "前提：刷新回来之前确认还没写出")
        releaseRefresh(refresh, scope: SessionScope.full)
        await waitSettled(fixture)

        XCTAssertEqual(sent(Self.deletionWrite).count, 1, "(a1) 刷新期间作用域变 full：确认零写出")
        try await assertKept(fixture, record, host, old: old, "(a1)")
    }

    // MARK: - (a2) 放弃

    /// (a2) 同 (a1) 的【放弃】：二次确认后调作废接口，刷新期间作用域变 full → 作废请求零写出，记录保留。
    /// 现状红：POST /v1/idempotency-keys/abandon 照样写出 1 次（得到 abandoned 后键结束、记录删除）。改后绿：零写出、记录保留。
    func testA2AbandonSendsNothingWhenRefreshTurnsScopeFull() async throws {
        let fixture = restrictedFixture()
        let host = try await openDeletionPage(fixture)
        let old = host.controller
        let record = try await enterDeletionPending(fixture, old)
        let refresh = try await holdNextRefresh(fixture)

        deletionActions(old).askAbandon()
        XCTAssertEqual(old.flow.state.abandonConfirmKey, record.key, "前提：弹出放弃的二次确认")
        deletionActions(old).abandon()
        await waitClaimed(fixture)
        XCTAssertTrue(sent(Self.abandonWrite).isEmpty, "前提：刷新回来之前作废还没写出")
        releaseRefresh(refresh, scope: SessionScope.full)
        await waitSettled(fixture)

        XCTAssertTrue(sent(Self.abandonWrite).isEmpty, "(a2) 刷新期间作用域变 full：作废零写出")
        XCTAssertEqual(sent(Self.deletionWrite).count, 1, "(a2) 原请求也没有重发")
        try await assertKept(fixture, record, host, old: old, "(a2)")
    }

    // MARK: - (a3) 首次申请

    /// (a3) 受限页首次【申请注销】：申请时 deletion_only，刷新后 full → 零写出、不留未决记录、页面不显示 42901。
    /// 现状红：刷新回来后申请照样写出 1 次（可能重新进入冷静期）。改后绿：作用域项拦下，零写出（本地拒绝不登记未决记录）。
    func testA3FirstApplySendsNothingWhenRefreshTurnsScopeFull() async throws {
        let fixture = restrictedFixture()
        let host = try await openDeletionPage(fixture)
        let old = host.controller
        script.on(Self.deletionWrite, Self.coolingReply)
        deletionActions(old).toggleWaiver()
        let refresh = try await holdNextRefresh(fixture)

        deletionActions(old).apply()
        await waitUntil("申请没有进入提交中") { old.flow.state.phase == .submitting }
        await settle()
        XCTAssertTrue(sent(Self.deletionWrite).isEmpty, "前提：刷新回来之前申请还没写出")
        releaseRefresh(refresh, scope: SessionScope.full)
        await quietWindow(0.8)
        fixture.wallet.checkSession()
        await settle()

        XCTAssertTrue(sent(Self.deletionWrite).isEmpty, "(a3) 刷新期间作用域变 full：首次申请零写出")
        XCTAssertTrue(deletionRecords(fixture).isEmpty, "(a3) 没有写出：不留未决记录")
        XCTAssertFalse(fixture.gates.deletion.active, "(a3) 作用域拦截不写 42901 禁用期")
        XCTAssertFalse(host.controller === old, "前提：作用域变成 full 后注销页按新作用域重建")
        assertNoRateLimitText([old, host.controller], "(a3)")
    }

    // MARK: - (a-对照) 作用域没变

    /// (a-对照) 确认：刷新回来仍是 deletion_only（作用域没变）→ 照常用原键原体写出 1 次。现状绿、改后仍须绿（防「一律拦」）。
    func testAControlConfirmStillSendsWhenScopeUnchanged() async throws {
        let fixture = restrictedFixture()
        let host = try await openDeletionPage(fixture)
        let old = host.controller
        let record = try await enterDeletionPending(fixture, old)
        script.on(Self.deletionWrite, Self.coolingReply)
        let refresh = try await holdNextRefresh(fixture)

        deletionActions(old).confirm()
        await waitClaimed(fixture)
        releaseRefresh(refresh, scope: SessionScope.deletionOnly)
        await waitUntil("(a-对照) 确认没有写出") { self.sent(Self.deletionWrite).count == 2 }
        await waitUntil("(a-对照) 确认成功后记录没有结束") { self.deletionRecords(fixture).isEmpty }

        let writes = sent(Self.deletionWrite)
        XCTAssertEqual(writes.count, 2, "(a-对照) 作用域没变：确认照常写出 1 次")
        XCTAssertEqual(writes.last?.header("Idempotency-Key"), record.key, "(a-对照) 用原键")
        XCTAssertEqual(writes.last?.body, "", "(a-对照) 用原体（空体）")
        XCTAssertTrue(host.controller === old, "(a-对照) 作用域没变：不重建")
    }

    /// (a-对照) 首次申请：刷新回来仍是 deletion_only → 照常写出 1 次。现状绿、改后仍须绿（防「一律拦」）。
    func testAControlFirstApplyStillSendsWhenScopeUnchanged() async throws {
        let fixture = restrictedFixture()
        let host = try await openDeletionPage(fixture)
        let old = host.controller
        script.on(Self.deletionWrite, Self.coolingReply)
        deletionActions(old).toggleWaiver()
        let refresh = try await holdNextRefresh(fixture)

        deletionActions(old).apply()
        await waitUntil("申请没有进入提交中") { old.flow.state.phase == .submitting }
        await settle()
        releaseRefresh(refresh, scope: SessionScope.deletionOnly)
        await waitUntil("(a-对照) 申请没有写出") { !self.sent(Self.deletionWrite).isEmpty }
        await settle()

        XCTAssertEqual(sent(Self.deletionWrite).count, 1, "(a-对照) 作用域没变：申请照常写出 1 次")
        XCTAssertTrue(host.controller === old, "(a-对照) 作用域没变：不重建")
    }
}
