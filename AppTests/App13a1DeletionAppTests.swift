@testable import Couli
import CouliNetwork
import Foundation
import MeCore
import Router
import Session
import WalletCore
import XCTest

/// APP-13a-1-ios 写测（独立写测方）：注销的 App 层接线——强更页「注销账号 / 撤销注销」标签、受限 → full 的同步出口（清 token、按新作用域重建）、
/// 撤回后回 Settings 的唯一导航实例并轻提示、入口来源交接。真实 AppWallet + 真实 ApiClient + 本地 WalletStubProtocol 假服务。
///
/// DeleteAccount 的 since.ios 仍是 null，Router 守卫挡着入口（D10-1562，本单不改）；这里按 App 的写法把目的地直接放进导航栈、经
/// `AppWallet.entry(for:)` 取页面（与 RouteViewRegistry 同一个入口），不经守卫。
///
/// 依据：三端任务书 §2 第 8 项（强更页已登录时取一次 getDeletion：cooling 且 can_cancel=true →「撤销注销」，其余、游客、读取失败 →「注销账号」）、
/// 共性第 32 条（标签读取与注销页共用 deletionRead 的发送前检查与 42901 结算，限流期间用兜底标签）；§0「会话换代清空」（受限 → full 按新作用域
/// 重建、内存 step_up_token 清空，§2 第 7 项「作用域从 deletion_only 变成 full 时清空」）；§2 第 4 项 / G18（从设置进入的撤回成功：出栈回 Settings
/// 的唯一导航实例并轻提示）；共性第 4 条（来源不走路由参数，由 App 按导航栈交接且只交接一次）。
@MainActor
final class App13a1DeletionAppTests: WalletFlowTestCase {
    private static let deletionPath = "GET /v1/me/deletion"

    private func cooling(_ canCancel: Bool) -> String {
        "{\"status\":\"cooling\",\"apply_at\":\"2026-10-02T09:30:00+08:00\","
            + "\"cooling_until\":\"2026-10-09T09:30:00+08:00\","
            + "\"can_cancel\":\(canCancel),\"cancelled_at\":null,\"cancel_reason\":null,\"processed_at\":null}"
    }

    private var cancelled: String {
        "{\"status\":\"cancelled\",\"apply_at\":\"2026-10-02T09:30:00+08:00\","
            + "\"cooling_until\":\"2026-10-09T09:30:00+08:00\","
            + "\"can_cancel\":false,\"cancelled_at\":\"2026-10-03T10:00:00+08:00\",\"cancel_reason\":\"user\","
            + "\"processed_at\":null}"
    }

    private func fixture(scope: String = "full") -> WalletAppFixture {
        WalletAppFixture.make(suiteName: suiteName, defaults: defaults, scope: scope)
    }

    private var deletionReads: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("GET", "/v1/me/deletion")
    }

    /// 把注销页目的地放进导航栈（`below` 是它下面的路由），经 AppWallet 取页面与执行器。
    private func push(_ fixture: WalletAppFixture, below: [String], fromForceUpdate: Bool = false) throws
        -> (RouteDestination, MePageHost<DeleteAccountController>) {
        let lower = below.map { RouteDestination(route: $0) }
        let destination = RouteDestination(route: DeleteAccountController.route, fromForceUpdatePage: fromForceUpdate)
        fixture.router.path = lower + [destination]
        let entry = try XCTUnwrap(fixture.wallet.entry(for: destination), "注销页没有登记到钱包页面表")
        let host = try XCTUnwrap(entry.controller as? MePageHost<DeleteAccountController>, "注销页执行器类型")
        return (destination, host)
    }

    // MARK: - 强更页标签

    /// 已登录、冷静期且 can_cancel=true：「撤销注销」。
    func testForceUpdateLabelShowsCancelDeletionWhenCancellable() async {
        script.ok(Self.deletionPath, cooling(true))
        let fixture = fixture()
        let label = fixture.wallet.forceUpdateDeletion
        label.appeared()
        await waitUntil("标签没有变成撤销注销") { label.key == "app_update.cancel_deletion" }
        XCTAssertEqual(deletionReads.count, 1, "已登录时取一次 getDeletion")
        label.disappeared()
    }

    /// 已登录、其余进度（从未申请、冷静期不可撤回、已撤回、处理中）与读取失败：「注销账号」。
    func testForceUpdateLabelFallsBackToDeleteAccount() async {
        let cases: [(String, WalletStubProtocol.Reply)] = [
            ("从未申请", .envelope(code: 0, data: "null", headers: [:])),
            ("冷静期不可撤回", .envelope(code: 0, data: cooling(false), headers: [:])),
            ("已撤回", .envelope(code: 0, data: cancelled, headers: [:])),
            ("读取失败", .envelope(code: 50001, data: "null", headers: [:])),
            ("断连", .disconnect),
        ]
        for (name, reply) in cases {
            WalletStubProtocol.reset()
            script.install()
            script.on(Self.deletionPath, reply)
            suiteName += "-x"
            let fixture = fixture()
            let label = fixture.wallet.forceUpdateDeletion
            label.appeared()
            await waitUntil("\(name)：没有取 getDeletion") { !self.deletionReads.isEmpty }
            await settle()
            XCTAssertEqual(label.key, "app_update.delete_account", name)
            label.disappeared()
        }
    }

    /// 已显示「撤销注销」后会话变成游客：重取时不发请求、回到「注销账号」。游客进入强更页同样不发、显示「注销账号」。
    func testForceUpdateLabelForGuestDoesNotRead() async throws {
        let fixture = fixture()
        try fixture.tokens.clear()
        fixture.network.client.signOut()
        let label = fixture.wallet.forceUpdateDeletion
        label.appeared()
        await settle()
        XCTAssertEqual(label.key, "app_update.delete_account")
        XCTAssertTrue(deletionReads.isEmpty, "游客不为标签发 getDeletion")
        label.disappeared()
    }

    /// 限流期间（与注销页共用 deletionRead）：不发请求，用兜底标签「注销账号」。
    func testForceUpdateLabelRespectsSharedDeletionReadGate() async {
        script.ok(Self.deletionPath, cooling(true))
        let fixture = fixture()
        fixture.wallet.gates.deletionRead.start(60_000)
        let label = fixture.wallet.forceUpdateDeletion
        label.appeared()
        await settle()
        XCTAssertEqual(label.key, "app_update.delete_account", "限流期间用兜底标签")
        XCTAssertTrue(deletionReads.isEmpty, "限流期间发送前检查拦下")
        label.disappeared()
    }

    /// 标签读取得到 42901：写入与注销页共用的 deletionRead 禁用期（共性第 32 条），标签用兜底。
    func testForceUpdateLabel42901SettlesSharedGate() async {
        script.fail(Self.deletionPath, 42901, headers: ["Retry-After": "30"])
        let fixture = fixture()
        let label = fixture.wallet.forceUpdateDeletion
        label.appeared()
        await waitUntil("42901 没有写入共用禁用期") { fixture.wallet.gates.deletionRead.active }
        XCTAssertEqual(label.key, "app_update.delete_account")
        label.disappeared()
    }

    /// r2（D10-2090，共性第 49 条）：标签读取在途时同账号、同登录世代的作用域变了（会话世代不变），迟到的旧 42901 不写进新作用域的
    /// deletionRead 闸门（否则新作用域的注销页与标签被旧限流禁用），也不改标签。
    func testForceUpdateLabelLate42901AfterScopeChangeDoesNotWriteGate() async throws {
        script.on(Self.deletionPath, .hold)
        let fixture = fixture()
        let label = fixture.wallet.forceUpdateDeletion
        label.appeared()
        await waitUntil("标签读取没有到达假服务") { WalletStubProtocol.heldIds.count == 1 }

        // 同账号、同登录世代，作用域 full → deletion_only（不换会话世代）
        try fixture.tokens.save(
            access: "at", refresh: "rt", scope: "deletion_only", account: "user-a", loginEpoch: "fixture-login-user-a"
        )
        XCTAssertEqual(fixture.wallet.deletionScopeNow(), DeletionScope.deletionOnly, "前提：作用域已变")
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: .envelope(code: 42901, data: "null", headers: ["Retry-After": "30"]))
        await quietWindow(0.8)

        XCTAssertFalse(fixture.wallet.gates.deletionRead.active, "作用域已变：旧 42901 不写进新作用域的闸门")
        XCTAssertEqual(label.key, "app_update.delete_account")
        label.disappeared()
    }

    // MARK: - 受限 → full

    /// 受限会话下打开注销页；会话刷新成 full（同账号、同登录世代）后在会话同步出口：内存 step_up_token 清空，注销页按新作用域重建（旧执行器作废），
    /// 入口来源沿用第一次交接的结论（只交接一次）。
    func testRestrictedToFullClearsTokensAndRebuildsPage() throws {
        let fixture = fixture(scope: "deletion_only")
        let (_, host) = try push(fixture, below: ["Settings"])
        let old = host.controller
        XCTAssertEqual(old.identity.scope, DeletionScope.deletionOnly, "前提：受限会话构造")
        XCTAssertEqual(old.identity.source, .settings, "前提：下面是 Settings")
        fixture.wallet.deps.tokens.put(
            action: "account_deletion", account: "user-a", token: "restricted-step-up-token", expireAtMs: Int64.max
        )

        try fixture.tokens.save(
            access: "at-full", refresh: "rt-full", scope: "full", account: "user-a", loginEpoch: "fixture-login-user-a"
        )
        fixture.router.path.removeFirst()
        fixture.wallet.checkSession()

        XCTAssertNil(
            fixture.wallet.deps.tokens.take(action: "account_deletion", account: "user-a", nowMs: 0),
            "受限 → full：内存 step_up_token 清空"
        )
        XCTAssertFalse(host.controller === old, "按新作用域重建执行器，不沿用旧控制器")
        XCTAssertFalse(old.alive, "旧执行器在同步出口作废")
        XCTAssertEqual(host.controller.identity.scope, DeletionScope.full)
        XCTAssertEqual(host.controller.identity.source, .settings, "来源只交接一次：重建沿用")
    }

    // MARK: - 撤回后回 Settings

    /// 从设置进入、冷静期撤回成功：出栈回 Settings 的那一个导航实例，并在那个实例上轻提示。
    func testCancelFromSettingsPopsToSettingsInstanceWithToast() async throws {
        script.ok(Self.deletionPath, cooling(true))
        script.ok("POST /v1/me/deletion/cancel", cancelled)
        let fixture = fixture()
        let toasted = App13a1ToastLog()
        fixture.wallet.settingsDeletionToast = { toasted.ids.append($0) }
        let (_, host) = try push(fixture, below: ["Settings"])
        let settings = try XCTUnwrap(fixture.router.path.first)
        let controller = host.controller
        controller.start()
        await waitUntil("冷静期没有读到") { controller.view.kind == .cooling && controller.view.showCancel }
        await settle()

        controller.cancelDeletion(version: controller.state.version, owner: controller.identity.owner)
        await waitUntil("没有回到 Settings") { fixture.router.path.map(\.id) == [settings.id] }
        XCTAssertEqual(toasted.ids, [settings.id], "在 Settings 那个导航实例上轻提示")
        XCTAssertEqual(WalletStubProtocol.requests("POST", "/v1/me/deletion/cancel").count, 1)
        XCTAssertTrue(WalletStubProtocol.requests("POST", "/v1/me/deletion/cancel").first?.body.isEmpty ?? false,
                      "撤回没有请求体")
    }

    // MARK: - 来源推断

    /// 来源不走路由参数，按导航栈交接：强更页次要入口 → force_update；下面是 Settings → settings；下面是 RiskNotice → risk_notice；
    /// 别处（栈底）→ other。
    func testDeletionSourceInferredFromNavigationStack() throws {
        let fixture = fixture()
        let (_, fromSettings) = try push(fixture, below: ["Settings"])
        XCTAssertEqual(fromSettings.controller.identity.source, .settings)

        let (_, fromForce) = try push(fixture, below: ["ForceUpdate"], fromForceUpdate: true)
        XCTAssertEqual(fromForce.controller.identity.source, .forceUpdate)

        let (_, fromRisk) = try push(fixture, below: ["RiskNotice"])
        XCTAssertEqual(fromRisk.controller.identity.source, .riskNotice)

        let (_, alone) = try push(fixture, below: [])
        XCTAssertEqual(alone.controller.identity.source, .other)
    }

    /// 带参数的目的地：参数被丢弃、不影响来源（DeleteAccount params 为空对象，G21）。
    func testDeletionSourceIgnoresRouteParams() throws {
        let fixture = fixture()
        let destination = RouteDestination(
            route: DeleteAccountController.route, params: ["source": .string("force_update")]
        )
        fixture.router.path = [RouteDestination(route: "Settings"), destination]
        let entry = try XCTUnwrap(fixture.wallet.entry(for: destination))
        let host = try XCTUnwrap(entry.controller as? MePageHost<DeleteAccountController>)
        XCTAssertEqual(host.controller.identity.source, .settings, "来源不从路由参数取")
    }

    // MARK: - D10-2094 冷静期文案口径

    /// D10-2094 ②（本单 brief.md「待改」）：can_cancel=false 只是不显示【撤回注销】，时间线停在「注销处理」一步（契约 deletion.timeline.processing /
    /// processing_desc），不显示自拟的 cannot_cancel 句子；撤回 10007 不用自拟的 cancel_expired（D10-2094 ①）。页面源码核对（进程内读不到 SwiftUI 文本）。
    func testCoolingPageUsesContractTimelineWithoutSelfDraftedSentences() throws {
        // 注销页源码可拆文件（DeleteAccountScreen.swift 与 DeleteAccountScreen+*.swift），全部读入再核
        let root = WalletVisualData.repo().appendingPathComponent("Packages/Features/Sources/Me")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("DeleteAccountScreen") && $0.hasSuffix(".swift") }.sorted()
        XCTAssertTrue(names.contains("DeleteAccountScreen.swift"))
        let source = try names.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "(?m)^\\s*//.*$", with: "", options: .regularExpression)
        XCTAssertFalse(source.contains("deletion.cooling.cannot_cancel"), "can_cancel=false 不新造句")
        XCTAssertFalse(source.contains("deletion.cooling.cancel_expired"), "撤回 10007 不用自拟句")
        XCTAssertTrue(source.contains("\"deletion.timeline.processing\""), "时间线有「注销处理」一步")
        XCTAssertTrue(source.contains("\"deletion.timeline.processing_desc\""), "「注销处理」说明用契约键")
    }
}

/// 记下设置页轻提示落在哪个导航实例上。
@MainActor
final class App13a1ToastLog {
    var ids: [UUID] = []
}
