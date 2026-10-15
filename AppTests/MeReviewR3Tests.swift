@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Me
import MeCore
import Router
import SwiftUI
import Wallet
import WalletCore
import XCTest

/// 第 3 轮评审修复（R3-01）：一次性提示经真实宿主视图（UIWindow 里的 UIHostingController，onChange 照常执行）呈现——首次提示不丢、
/// 连续两次不同结果各显示自己的内容、每个提示只交给轻提示（播报）一次。
@MainActor
final class MeReviewR3Tests: MeTestCase {
    private func toastLog() -> SpokenLog {
        let log = SpokenLog()
        MeAnnounceProbe.toast = { log.lines.append($0) }
        return log
    }

    /// AC-S1-136①：关于页首次复制诊断信息 → 轻提示「已复制」一次（不是什么都不显示）；再复制一次再提示一次。
    func testAboutFirstCopyDiagnosticsShowsToastOnce() async throws {
        let fixture = make()
        await fixture.loadConfig()
        let entry = try XCTUnwrap(fixture.open("About"))
        entry.appeared()
        let controller = try XCTUnwrap(entry.controller() as? AboutController)
        let toasts = toastLog()
        defer { MeAnnounceProbe.toast = nil }
        let host = HostedPage(entry.screen())
        defer { host.close() }
        await host.pump()
        XCTAssertTrue(toasts.lines.isEmpty)
        let done = fixture.me.deps.texts.text(AboutController.copiedKey)

        controller.copyDiagnostics()
        await host.pump(until: { !toasts.lines.isEmpty })
        XCTAssertEqual(toasts.lines, [done], "首次复制即提示一次")
        XCTAssertNil(controller.toast, "提示已消费")
        await host.pump(rounds: 10)
        XCTAssertEqual(toasts.lines.count, 1, "重绘不重复提示")

        controller.copyDiagnostics()
        await host.pump(until: { toasts.lines.count == 2 })
        XCTAssertEqual(toasts.lines, [done, done], "再复制再提示一次")
    }

    /// AC-S1-137③ 与连续两种不同结果：设置页先「重新显示下单须知」失败（5xxxx，带 trace6），再清除缓存成功 → 依次提示失败与「已清除」，
    /// 各一次，第二条不是上一条的内容。
    func testSettingsFailureThenClearCacheShowEachOwnResult() async throws {
        let fixture = make()
        let entry = try XCTUnwrap(fixture.open("Settings"))
        entry.appeared()
        let controller = try XCTUnwrap(entry.controller() as? SettingsController)
        await waitUntil("Me 没到") { fixture.me.deps.repo.state.me != nil }
        await waitUntil("缓存大小没算出") { controller.state.cacheBytes != nil }
        let toasts = toastLog()
        defer { MeAnnounceProbe.toast = nil }
        let host = HostedPage(entry.screen())
        defer { host.close() }
        await host.pump()
        XCTAssertTrue(toasts.lines.isEmpty)
        let texts = fixture.me.deps.texts

        script.fail("DELETE /v1/me/tips/jump_tip", 50001)
        let reset = try XCTUnwrap(controller.model().groups.flatMap(\.rows).first { $0.id == "重新显示下单须知" })
        SettingsActions.make(controller, controller.state).row(reset)
        await host.pump(until: { !toasts.lines.isEmpty })
        XCTAssertEqual(toasts.lines.count, 1, "首次失败即提示：\(toasts.lines)")
        XCTAssertTrue(toasts.lines[0].contains("6789ab"), "5xxxx 带 trace6：\(toasts.lines)")
        XCTAssertNil(controller.state.toast, "提示已消费")

        let clear = try XCTUnwrap(controller.model().groups.flatMap(\.rows).first { $0.id == "清除缓存" })
        SettingsActions.make(controller, controller.state).row(clear)
        SettingsActions.make(controller, controller.state).confirmClear(try XCTUnwrap(controller.state.dialog))
        await host.pump(until: { toasts.lines.count == 2 })
        XCTAssertEqual(toasts.lines.last, texts.text(SettingsController.clearedKey), "第二条是清除成功，不是上一条失败")
        XCTAssertNil(controller.state.toast)
        await host.pump(rounds: 10)
        XCTAssertEqual(toasts.lines.count, 2, "每个提示只交出一次")
    }

    /// MeTab：已有资料时首次刷新失败 → 轻提示（统一错误 + trace6）一次、保留资料；随后复制邀请码 → 提示「已复制」（不是上一条错误）。
    func testMeTabFirstRefreshFailureWithProfileShowsToastOnce() async {
        let fixture = make()
        _ = await loadedTab(fixture)
        let repo = fixture.me.deps.repo
        XCTAssertNotNil(repo.state.me)
        let toasts = toastLog()
        defer { MeAnnounceProbe.toast = nil }
        let host = HostedPage(AnyView(MeTabScreen(host: fixture.me.tabHost, mask: fixture.me.mask,
                                                  scroll: fixture.me.scroll)))
        defer { host.close() }
        await host.pump()
        await waitUntil("出现时的读取没结束") { !repo.state.refreshing && repo.state.phase != .loading }
        await host.pump()
        XCTAssertTrue(toasts.lines.isEmpty)

        script.fail("GET /v1/me", 50002)
        let before = requests("GET", "/v1/me").count
        fixture.me.tabHost.controller.refresh()
        await host.pump(until: { !toasts.lines.isEmpty })
        XCTAssertGreaterThan(requests("GET", "/v1/me").count, before)
        XCTAssertEqual(toasts.lines.count, 1, "首次刷新失败即提示：\(toasts.lines)")
        XCTAssertTrue(toasts.lines[0].contains("6789ab"), "带 trace6：\(toasts.lines)")
        XCTAssertNotNil(repo.state.me, "保留上次资料")
        XCTAssertNil(repo.state.error, "提示已消费")
        await host.pump(rounds: 10)
        XCTAssertEqual(toasts.lines.count, 1, "重绘不重复提示")

        MeTabActions.make(fixture.me.tabHost.controller, repo.state).copyInvite()
        await host.pump(until: { toasts.lines.count == 2 })
        XCTAssertEqual(toasts.lines.last, fixture.me.deps.texts.text(MeTabController.copied), "第二条是复制结果")
        await host.pump(rounds: 10)
        XCTAssertEqual(toasts.lines.count, 2)
    }
}

/// 清除缓存的成功口径（R3-01 裁定）：清理动作都完成、没有 I/O 错误即成功；系统缓存占用没有同步缩小不算失败，清后大小照实显示。
@MainActor
final class ClearCacheCriterionR3Tests: MeTestCase {
    /// 生产实现 IOSMeSystem：URLCache 清完后占用仍是 5 MB（系统不保证同步缩小）→ 仍算成功；两步清理都执行了；重算的大小照实给出。
    func testIOSClearCacheSucceedsWhenDiskUsageDoesNotShrink() async throws {
        let cache = StickyURLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: nil)
        let web = SpokenLog()
        let system = IOSMeSystem(permissions: nil, urlCache: cache, removeWebData: { web.lines.append("web") })
        let ok = await system.clearCache()
        XCTAssertTrue(ok, "清理动作完成即成功，不看清后的占用")
        XCTAssertEqual(cache.removed, 1, "清了 URLCache")
        XCTAssertEqual(web.lines.count, 1, "清了网页缓存")
        let bytes = await system.cacheBytes()
        let after = try XCTUnwrap(bytes)
        XCTAssertGreaterThanOrEqual(after, StickyURLCache.usage, "清后大小照实计算（不为 0 也照实显示）")
    }

    /// 设置页：清理成功但占用没降 → 提示「已清除」并显示重算后的实际大小；清理动作有 I/O 错误 → 失败提示。
    func testSettingsClearCacheSuccessKeepsActualSizeAndFailsOnlyOnError() async throws {
        let fixture = make()
        fixture.system.bytesAfterClear = nil
        let entry = try XCTUnwrap(fixture.open("Settings"))
        entry.appeared()
        let controller = try XCTUnwrap(entry.controller() as? SettingsController)
        await waitUntil("缓存大小没算出") { controller.state.cacheBytes != nil }
        let before = try XCTUnwrap(controller.state.cacheBytes)
        let row = try XCTUnwrap(controller.model().groups.flatMap(\.rows).first { $0.id == "清除缓存" })

        SettingsActions.make(controller, controller.state).row(row)
        SettingsActions.make(controller, controller.state).confirmClear(try XCTUnwrap(controller.state.dialog))
        await waitUntil("没有清完") { controller.state.toast != nil }
        XCTAssertEqual(controller.state.toast?.key, SettingsController.clearedKey, "占用没降也算清除成功")
        XCTAssertEqual(controller.state.cacheBytes, before, "显示重算后的实际大小")
        controller.consumeToast(try XCTUnwrap(controller.state.toast).id)

        fixture.system.clearSucceeds = false
        SettingsActions.make(controller, controller.state).row(row)
        SettingsActions.make(controller, controller.state).confirmClear(try XCTUnwrap(controller.state.dialog))
        await waitUntil("没有清完") { controller.state.toast != nil }
        XCTAssertEqual(controller.state.toast?.key, "error.50001", "只有清理动作出错才提示失败")
        XCTAssertEqual(fixture.system.cleared, 2)
    }
}

/// 清后占用不变的 URLCache 替身（模拟系统缓存占用不同步缩小）。
final class StickyURLCache: URLCache, @unchecked Sendable {
    static let usage: Int64 = 5 * 1024 * 1024
    private(set) var removed = 0

    override var currentDiskUsage: Int {
        Int(Self.usage)
    }

    override func removeAllCachedResponses() {
        removed += 1
    }
}

/// R3-01 全仓库同类排查：提现页的一次性读屏播报（档位 / 全部提现的「提现金额 x，预计到账 y」）经真实宿主视图，首次即播报、内容是这一次的。
@MainActor
final class WithdrawAnnounceR3Tests: WalletFlowTestCase {
    func testFirstQuickFillAnnouncedWithCurrentLine() async throws {
        let spoken = SpokenLog()
        WalletAnnounceProbe.observe = { spoken.lines.append($0) }
        defer { WalletAnnounceProbe.observe = nil }
        let fixture = make()
        let controller = try await withdraw(fixture)
        let entry = try XCTUnwrap(fixture.page(WalletRoutes.withdraw))
        let host = HostedPage(entry.screen())
        defer { host.close() }
        await host.pump()
        XCTAssertTrue(spoken.lines.isEmpty)
        let texts = WalletDraftTexts()
        let spokenMoney: (Int64) -> String = { CouliFormat.moneySpoken(fen: $0) }

        actions(controller).fillAll()
        await host.pump(until: { !spoken.lines.isEmpty })
        let first = TextLine("withdraw.spoken.quick", amounts: ["amount": 1200, "net": 1200])
        XCTAssertEqual(spoken.lines, [first.render(texts, money: spokenMoney)], "首次即播报这一次的金额")
        XCTAssertNil(controller.state.announce, "已消费")

        actions(controller).quick(500)
        await host.pump(until: { spoken.lines.count == 2 })
        XCTAssertNotEqual(spoken.lines.last, spoken.lines.first, "第二次不是上一条")
        XCTAssertTrue(spoken.lines.last?.contains(spokenMoney(500)) == true, "\(spoken.lines)")
        await host.pump(rounds: 10)
        XCTAssertEqual(spoken.lines.count, 2, "不重复播报")
    }
}
