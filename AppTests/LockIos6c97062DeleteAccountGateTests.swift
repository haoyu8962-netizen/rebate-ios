@testable import Couli
import Foundation
import Generated
import Me
import MeCore
import Router
import XCTest

/// FU-IOS-CONTRACT-LOCK-6c97062 注销本地闸（D10-2903 ②(b)）：升锁到 6c97062 后契约 routes.json DeleteAccount 的 since.ios 由 null 改为
/// "1.0.0"（CT-17k #323），iOS 生成器读 since.ios，不加闸就会打开注销入口（Release 也开）。本单只升锁、加一道本地闸保持关门，开门仍归
/// APP-13a-3（前置 FU-IOS-DELETION-REAPPLY-STALE-KEY「公开发布前必须修完」、FU-IOS-DELETION-R4-S3）。
///
/// 照 PhoneChangeEntry（MeCore/PhoneChange.swift）与 App13a2EntryTests.testReleaseGateClosedUntilSinceFilled 的写法：闸是
/// `MeCore.DeleteAccountEntry.sinceIOS`（nil = 本端未发布），设置页行（AppMe.availableRoutes → SettingsController → SettingsItems）与
/// 路由（AppRouting.routeTable → Router / EntryGuard）两处都要闸住；闸不放进 WalletCore（RealnameFundsBaselineCoverageTests
/// 要求 WalletCore 每个文件都在资金底版 logicFiles 里）。
/// 现状（锁 d47f660、未实现）：`DeleteAccountEntry` 是新符号，本文件编译红；即使去掉那句，契约前提 `sinceIOS == "1.0.0"` 也红。
@MainActor
final class LockIos6c97062DeleteAccountGateTests: App13a2TestCase {
    static let route = "DeleteAccount"

    /// 前提：升锁确实打开了契约（since.ios = 1.0.0）；本地闸关着（nil）。
    func testContractReleasedButLocalGateClosed() throws {
        let spec = try XCTUnwrap(Routes.all[Self.route], "契约路由表里要有 DeleteAccount")
        XCTAssertEqual(spec.sinceIOS, "1.0.0", "前提：升锁 6c97062（CT-17k）后契约 since.ios = 1.0.0")
        XCTAssertNil(DeleteAccountEntry.sinceIOS, "开门归 APP-13a-3：本单闸保持 nil")
    }

    /// 设置页判据：真实 AppMe.availableRoutes()（直接读 Routes.all 的那条路）不含 DeleteAccount；别的已发布路由照常（对照，防止整表被关）。
    func testAvailableRoutesExcludeDeleteAccount() {
        let fixture = fixture()
        let routes = fixture.me.availableRoutes()
        XCTAssertFalse(routes.contains(Self.route), "升锁后设置页判据仍不含 DeleteAccount")
        XCTAssertTrue(routes.contains("Settings"), "对照：since.ios = 1.0.0 的 Settings 照常可用")
        XCTAssertTrue(routes.contains("About"), "对照：About 照常可用")
    }

    /// 设置页（真实 AppMe 环境，不注入路由集合）：已登录的账号与安全组里没有【注销账号】这一行。
    func testSettingsHasNoDeleteAccountRow() async throws {
        let fixture = fixture()
        let settings = try await settings(fixture)
        let ids = settings.model().groups.flatMap(\.rows).map(\.id)
        XCTAssertTrue(ids.contains(SettingsItems.idPhone), "前提：已登录，账号与安全组在")
        XCTAssertFalse(ids.contains(SettingsItems.idDelete), "升锁后【注销账号】仍不出现")
        XCTAssertFalse(
            settings.model().groups.flatMap(\.rows).contains { $0.route == Self.route }, "没有任何一行指向 DeleteAccount"
        )
    }

    /// 路由表：生产 Router 用的 AppRouting.routeTable 里 DeleteAccount 仍在（不删路由），since.ios 被闸成 nil。
    func testRouteTableGatesDeleteAccount() throws {
        let spec = try XCTUnwrap(AppRouting.routeTable[Self.route], "路由表里不删 DeleteAccount")
        XCTAssertNil(spec.sinceIOS, "本地闸关着：路由表按未发布处理")
        XCTAssertEqual(AppRouting.routeTable["Settings"]?.sinceIOS, "1.0.0", "对照：别的路由不受影响")
    }

    /// 路由守卫：已登录在 App 内请求 DeleteAccount（10007、强更页次要入口等都经 Router）→ 升级提示（unknown_route），不进注销页。
    func testRouterGivesUpgradePromptForDeleteAccount() {
        let fixture = fixture()
        let decision = fixture.router.open(RouteRequest(route: Self.route, from: .inApp))
        XCTAssertEqual(decision.kind, .upgrade)
        XCTAssertNil(decision.route)
        XCTAssertEqual(decision.reason, GuardReason.unknownRoute)
        XCTAssertFalse(fixture.router.path.contains { $0.route == Self.route }, "不进注销页")
    }

    /// 强更页次要入口（UpdatePages【注销账号】走 openFromForceUpdatePage）：同样给升级提示，强更页留在栈底。
    func testForceUpdateSecondaryEntryStillGivesUpgradePrompt() {
        let fixture = fixture()
        fixture.router.enterForceUpdate()
        let decision = fixture.router.openFromForceUpdatePage(RouteRequest(route: Self.route, from: .inApp))
        XCTAssertEqual(decision.kind, .upgrade)
        XCTAssertEqual(fixture.router.lastDecision?.reason, GuardReason.unknownRoute)
        XCTAssertEqual(fixture.router.path.first?.route, RoutePolicy.forceUpdate, "强更页留在栈底")
        XCTAssertFalse(fixture.router.path.contains { $0.route == Self.route }, "不进注销页")
    }
}
