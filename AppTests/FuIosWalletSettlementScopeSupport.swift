@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import Router
import Session
import Wallet
import WalletCore
import XCTest

/// FU-IOS-WALLETSETTLEMENT-SCOPE 写测（独立写测方）的公共部分：真实 App 组装（WalletAppFixture：AppWallet + 真实 ApiClient + 本地
/// WalletStubProtocol 假服务），注销页经 `AppWallet.entry(for:)` 取得（与 App13a1DeletionAppTests 同一入口，不经守卫），按钮走页面同一份
/// 渲染时回调（`DeleteAccountActions.make`）。
///
/// 两种「作用域变化」的造法（都不换会话世代、同账号、同持久化登录世代）：
/// - 网络层刷新期间变化（(a) 组）：先挂起一次真实的受限会话屏障刷新（`ApiClient.updateBecameSupported()` 重新挂屏障并立即单飞刷新），
///   用户点击后的写请求在屏障上等这次刷新；放行时刷新响应的 session_scope = full（或对照组仍是 deletion_only）。
/// - 存储里直接换作用域（(b) 组）：`MemorySessionTokens.save` 只改 scope（令牌原样），需要时再调 `checkSession()` 走会话同步出口
///   （resyncDeletionScope 按新作用域重建注销页），与 App13a1DeletionAppTests 的写法相同。
///
/// 断言只看外部可观察的行为：传输层实际写出次数、PendingKeyStore 记录（键、原体、状态）、RetryAfterGate.active、重建后的注销页
/// 【申请注销】是否可点 / 是否写出、页面上是否出现 42901 文案；不依赖实现的命名。
@MainActor
class FuIosWalletSettlementScopeTestCase: WalletFlowTestCase {
    static let account = "user-a"
    static let loginEpoch = "fixture-login-user-a"
    static let deletionWrite = "POST /v1/me/deletion"
    static let abandonWrite = "POST /v1/idempotency-keys/abandon"
    static let smsSend = "POST /v1/auth/sms-codes"
    static let stepUpVerify = "POST /v1/auth/step-up"
    static let refresh = "POST /v1/auth/refresh"
    static let rateLimitKey = "error.42901"
    static let cooling = "{\"status\":\"cooling\",\"apply_at\":\"2026-10-02T09:30:00+08:00\","
        + "\"cooling_until\":\"2026-10-09T09:30:00+08:00\",\"can_cancel\":true,\"cancelled_at\":null,"
        + "\"cancel_reason\":null,\"processed_at\":null}"

    /// 刷新接口的令牌响应（TokenPairResponse）。
    static func tokens(_ suffix: String, scope: String) -> WalletStubProtocol.Reply {
        .envelope(
            code: 0,
            data: "{\"access_token\":\"at-\(suffix)\",\"refresh_token\":\"rt-\(suffix)\","
                + "\"session_scope\":\"\(scope)\",\"expires_in\":7200}",
            headers: [:]
        )
    }

    static func retryAfter(_ seconds: Int) -> WalletStubProtocol.Reply {
        .envelope(code: 42901, data: "null", headers: ["Retry-After": "\(seconds)"])
    }

    static var coolingReply: WalletStubProtocol.Reply {
        .envelope(code: 0, data: cooling, headers: [:])
    }

    // MARK: - 假服务

    /// 按「方法 路径」取传输层实际写出的请求。
    func sent(_ key: String) -> [WalletStubProtocol.Recorded] {
        let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return [] }
        return WalletStubProtocol.requests(parts[0], parts[1])
    }

    /// 挂起中的这一类请求（最近一个）。
    func heldId(_ key: String) -> Int? {
        let held = Set(WalletStubProtocol.heldIds)
        return sent(key).map(\.id).last { held.contains($0) }
    }

    func deletionRecords(_ fixture: WalletAppFixture) -> [PendingKeyRecord] {
        fixture.pendingBackend.list(account: Self.account).filter { $0.operationId == "requestDeletion" }
    }

    // MARK: - 组合与页面

    /// 受限会话（deletion_only）的 App 组合：启动屏障刷新照常通过（仍回 deletion_only），getDeletion 为从未申请。
    func restrictedFixture() -> WalletAppFixture {
        script.on(Self.refresh, Self.tokens("barrier", scope: SessionScope.deletionOnly))
        script.ok("GET /v1/me/deletion", "null")
        return WalletAppFixture.make(suiteName: suiteName, defaults: defaults, scope: SessionScope.deletionOnly)
    }

    /// 把注销页放进导航栈（下面是 Settings），经 AppWallet 取页面、启动，并等到可申请的初始态（启动屏障已过）。
    func openDeletionPage(_ fixture: WalletAppFixture) async throws -> MePageHost<DeleteAccountController> {
        let destination = RouteDestination(route: DeleteAccountController.route)
        fixture.router.path = [RouteDestination(route: "Settings"), destination]
        let entry = try XCTUnwrap(fixture.wallet.entry(for: destination), "注销页没有登记到钱包页面表")
        let host = try XCTUnwrap(entry.controller as? MePageHost<DeleteAccountController>, "注销页执行器类型")
        host.controller.start()
        await ready(host.controller, "进页")
        return host
    }

    func ready(_ controller: DeleteAccountController, _ what: String, file: StaticString = #filePath,
               line: UInt = #line) async {
        await waitUntil("\(what)：注销页没有进入可申请的初始态", timeout: 8, file: file, line: line) {
            controller.view.kind == .initial && controller.view.applyEnabledWhenChecked
        }
    }

    /// 页面渲染时取出的按钮回调（与 DeleteAccountScreen 同一个构造）。
    func deletionActions(_ controller: DeleteAccountController) -> DeleteAccountActions {
        DeleteAccountActions.make(controller, controller.state, controller.flow.state)
    }

    /// 勾选（没勾时）后点【申请注销】。
    func tapApply(_ controller: DeleteAccountController) {
        if !controller.state.waiver {
            deletionActions(controller).toggleWaiver()
        }
        deletionActions(controller).apply()
    }

    /// 首次申请得到结果未知（断连）→ 待确认卡；返回此刻的未决记录（unknown）。
    func enterDeletionPending(_ fixture: WalletAppFixture, _ controller: DeleteAccountController) async throws
        -> PendingKeyRecord {
        script.on(Self.deletionWrite, .disconnect)
        tapApply(controller)
        await waitUntil("没有进入待确认") { controller.flow.state.pending != nil }
        await settle()
        XCTAssertEqual(sent(Self.deletionWrite).count, 1, "前提：首次申请写出 1 次、结果未知")
        let record = try XCTUnwrap(deletionRecords(fixture).first, "前提：有未决记录")
        XCTAssertEqual(record.stateRaw, PendingKeyStore.unknown, "前提：记录为 unknown")
        XCTAssertEqual(controller.flow.state.pending?.key, record.key)
        return record
    }

    // MARK: - 作用域变化

    /// 挂起下一次刷新：重新挂上受限会话屏障并立即单飞刷新（存储的会话仍是 deletion_only），等刷新请求到达假服务。之后带令牌的请求
    /// 都在屏障上等这次刷新。返回挂起的刷新请求编号。
    func holdNextRefresh(_ fixture: WalletAppFixture) async throws -> Int {
        script.on(Self.refresh, .hold)
        let before = sent(Self.refresh).count
        fixture.network.client.updateBecameSupported()
        await waitUntil("屏障刷新没有到达假服务") { self.sent(Self.refresh).count > before && self.heldId(Self.refresh) != nil }
        XCTAssertEqual(fixture.wallet.deletionScopeNow(), DeletionScope.deletionOnly, "前提：刷新回来之前仍是受限会话")
        return try XCTUnwrap(heldId(Self.refresh))
    }

    /// 放行挂起的刷新：响应的 session_scope = `scope`；之后的刷新（若有）照同一作用域回答。
    func releaseRefresh(_ id: Int, scope: String) {
        script.on(Self.refresh, Self.tokens("after", scope: scope))
        WalletStubProtocol.release(id, with: Self.tokens("after", scope: scope))
    }

    /// 存储里只换作用域（同账号、同持久化登录世代、令牌原样；会话世代不变）。`sync` = 随后走会话同步出口（checkSession）。
    func switchScope(_ fixture: WalletAppFixture, to scope: String, sync: Bool = true,
                     file: StaticString = #filePath, line: UInt = #line) throws {
        let live = try XCTUnwrap(fixture.tokens.readSession(), "前提：有会话", file: file, line: line)
        try fixture.tokens.save(
            access: live.access, refresh: live.refresh, scope: scope, account: Self.account, loginEpoch: Self.loginEpoch
        )
        XCTAssertEqual(fixture.wallet.deletionScopeNow(), DeletionScope.normalized(scope), "前提：作用域已变",
                       file: file, line: line)
        if sync {
            fixture.wallet.checkSession()
        }
    }

    // MARK: - 页面文案

    /// 页面上（写请求错误条、待确认卡提示、本页提示、二次验证面板）没有 42901 文案。
    func assertNoRateLimitText(_ controllers: [DeleteAccountController], _ what: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        for controller in controllers {
            let keys = [
                controller.flow.state.error?.key, controller.flow.state.pendingNotice?.key,
                controller.state.notice?.key, controller.flow.stepUp.state?.error?.key,
            ]
            XCTAssertFalse(keys.contains(Self.rateLimitKey), "\(what)：作用域拦截不得显示 42901 文案（\(keys)）",
                           file: file, line: line)
        }
    }
}
