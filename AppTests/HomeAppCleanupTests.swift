import ClientCore
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import HomeCore
import Privacy
import Router
import SwiftUI
import XCTest

/// 首页本机数据的清理接线（brief §0「缓存与清理」；G11、G16 ②；cross-platform-lessons 第 8 条）：生产注册表、设置页【清除缓存】不碰首页数据、
/// 删除失败的待清理标记与重启补清。
final class HomeAppCleanupTests: HomeAppTestCase {
    private func page(_ version: Int, _ sections: [[String: Any]]) -> [String: Any] {
        ["page_key": "home", "version": version, "sections": sections]
    }

    /// 生产组合（宿主 App 启动时已登记）：首页本机数据的清理器在撤回同意与切换环境两个真实注册表里，各一次。
    func testProductionRegistriesCarryHomeDataCleaner() {
        let withdrawal = PrivacyWithdrawalCleanup.registry.registeredNames
        let environmentSwitch = EnvironmentSwitchCleanerRegistry.shared.registeredNames
        XCTAssertEqual(withdrawal.filter { $0 == HomeDataCleaner.name }.count, 1)
        XCTAssertEqual(environmentSwitch.filter { $0 == HomeDataCleaner.name }.count, 1)
    }

    /// 设置页【清除缓存】（生产实现）不碰首页 LKG、关闭记录、弹窗计数；重启后被关闭且未改版本的公告仍不出现。
    func testClearCacheKeepsHomeDataAndClosedNoticeStaysHidden() async throws {
        let port = TestHomePort(page: page(
            43,
            [HomeAppSamples.notice("nb", item: "n1"), HomeAppSamples.activity("act", action: ["route": "Help"])]
        ))
        let fixture = make(port: port)
        await fixture.launch()
        let identity = fixture.controller.identity
        fixture.controller.closeNotice(try XCTUnwrap(fixture.controller.state.section("nb")?.items.first?.close))
        let cleared = await IOSMeSystem(permissions: AppPermissions()).clearCache()
        XCTAssertTrue(cleared)
        XCTAssertEqual(fixture.lkgVersion(identity), 43)
        XCTAssertEqual(fixture.storage.prefs.closedKeys().count, 1)
        let restarted = make(port: port)
        await restarted.launch()
        XCTAssertEqual(restarted.controller.state.sectionIds, ["act"])
    }

    /// LKG 删除失败：待清理标记在目录外保留；「重启」后读 LKG 前补清，没清完不读回旧页面。
    func testLkgDeleteFailureKeepsFlagAndRestartNeverShowsOldPage() async {
        let fixture = make()
        await fixture.launch()
        let lkgRoot = storageRoot.appendingPathComponent(HomeLkgStore.directoryName)
        lock(lkgRoot)
        defer { unlock(lkgRoot) }
        try? fixture.environment.switchTo(.staging)
        XCTAssertTrue(fixture.storage.lkg.isPendingClear)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.storage.lkg.pendingFlagURL.path))
        // 重启（同一份本机数据）：网络不可用，没清完的旧 LKG 不得读回 → 满 1.5 秒显示包内默认
        let port = TestHomePort()
        port.set(result: .transportFailure(
            kind: "disconnect",
            httpStatus: nil,
            idempotencyKey: nil,
            pendingKeyUnknown: false
        ))
        let restarted = make(port: port)
        await restarted.launch()
        XCTAssertNotEqual(restarted.controller.state.source, .lkg, "没清完就读回了旧页面")
        restarted.clock.advance(1500)
        await restarted.controller.whenIdle()
        XCTAssertEqual(restarted.controller.state.source, .bundled)
    }

    // MARK: - 工具

    private func lock(_ url: URL) {
        let manager = FileManager.default
        for child in (manager.enumerator(atPath: url.path)?.allObjects as? [String]) ?? [] {
            try? manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.appendingPathComponent(child).path)
        }
        try? manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
    }

    private func unlock(_ url: URL) {
        let manager = FileManager.default
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        for child in (manager.enumerator(atPath: url.path)?.allObjects as? [String]) ?? [] {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appendingPathComponent(child).path)
        }
    }
}
