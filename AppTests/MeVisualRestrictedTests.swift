@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import Router
import Session
import SwiftUI
import UIKit
import XCTest

/// F-X-14（followups.md:151；03 受限会话「不拉取其他数据」；Android FU-AND-0717、鸿蒙 FU-HM-0721 已修）：受限登录（deletion_only）下「我的」的自动同步
/// 路径零 GET /v1/me，用户主动的下拉不拦（原文「主动读取除外」，Android `autoRefresh`、鸿蒙 `autoLoad` 同口径）；full 会话同样的路径照常读。
/// 走真实 AppMe、真实 ApiClient。读取可能排在屏障刷新之后，时序不定：每步等满观察窗再按次数判，不判先后。下拉走页面 `.refreshable` 同一个调用。
@MainActor
final class MeVisualRestrictedTests: MeVisualTestCase {
    private func restricted() async throws -> MeVisualHost {
        let (host, _) = try await open(Setup(scope: "deletion_only", phase: nil), waitFor: nil)
        await quietWindow()
        XCTAssertEqual(host.fixture.client.isolatedSessionScope, "deletion_only", "前提：会话确实受限")
        XCTAssertTrue(host.controller.identity.member, "前提：不是掉成游客")
        return host
    }

    /// 切 Tab 与页面出现都走 enterTab。
    func testEnterTabNoRead() async throws {
        _ = try await restricted()
        XCTAssertEqual(meReads, 0, "enterTab")
    }

    /// 身份确认后的恢复（AppMe 同步身份时调 resumeAfterIdentityConfirmed）：经会话同步一次，再直接调一次。
    func testResumeAfterIdentityConfirmedNoRead() async throws {
        let host = try await restricted()
        host.fixture.routing.sessionStateChanged(resumePending: false)
        await quietWindow()
        XCTAssertEqual(meReads, 0, "会话同步")
        host.controller.resumeAfterIdentityConfirmed()
        await quietWindow()
        XCTAssertEqual(meReads, 0, "resumeAfterIdentityConfirmed")
    }

    /// 下拉是用户主动：受限下照常恰一次，`refresh` 本身不加 guard。
    func testPullStillReadsOnce() async throws {
        let host = try await restricted()
        let reads = meReads
        XCTAssertTrue(host.controller.refresh(pull: true), "下拉不被拦")
        await quietWindow()
        XCTAssertEqual(meReads, reads + 1, "下拉恰一次")
    }

    func testForegroundNoRead() async throws {
        let host = try await restricted()
        host.fixture.me.scenePhaseChanged(.background)
        host.fixture.me.scenePhaseChanged(.active)
        await quietWindow()
        XCTAssertEqual(meReads, 0, "回前台")
    }

    /// 子页返回（用 Help：H5 页自己不读 Me；设置页 appeared 的读取不属「我的」）。
    func testChildReturnNoRead() async throws {
        let host = try await restricted()
        host.fixture.router.open(RouteRequest(route: "Help", from: .inApp))
        await settle()
        host.fixture.router.path = []
        await quietWindow()
        XCTAssertEqual(meReads, 0, "子页返回")
    }

    /// 同账号同登录世代从 full 降为受限：降级之后的进入、回前台都不读（判据看此刻的作用域，不看进入时的）。
    func testDowngradeStopsReads() async throws {
        let (host, _) = try await open(waitFor: nil)
        await quietWindow(0.5)
        let reads = meReads
        XCTAssertEqual(reads, 1, "前提：full 读过一次")
        host.script.ok("POST /v1/auth/refresh", Self.refreshBody(scope: SessionScope.deletionOnly))
        try host.fixture.tokens.save(access: "at-r", refresh: "rt-r", scope: SessionScope.deletionOnly,
                                     account: "me-visual-a")
        host.fixture.routing.sessionStateChanged(resumePending: false)
        await quietWindow()
        XCTAssertEqual(host.fixture.client.isolatedSessionScope, "deletion_only", "前提")
        XCTAssertEqual(meReads, reads, "降级后的重建不读")
        host.fixture.me.scenePhaseChanged(.background)
        host.fixture.me.scenePhaseChanged(.active)
        await quietWindow()
        XCTAssertEqual(meReads, reads, "降级后回前台不读")
    }

    /// 反面：受限解除（同世代刷新成 full）后恢复读取，门不能焊死。
    func testUpgradeResumesReads() async throws {
        let host = try await restricted()
        XCTAssertEqual(meReads, 0, "前提：受限时没读")
        try host.fixture.tokens.save(access: "at-f", refresh: "rt-f", scope: "full", account: "me-visual-a")
        host.fixture.routing.sessionStateChanged(resumePending: false)
        await waitUntil("解除受限后没有读取", timeout: 5) { self.meReads >= 1 }
    }

    /// 反面：full 会话同样的路径照常读（进入、回前台、子页返回、下拉各恰一次）。
    func testFullSessionReadsOnEveryPath() async throws {
        let (host, _) = try await open(waitFor: nil)
        await quietWindow(0.5)
        XCTAssertEqual(meReads, 1, "进入")
        host.fixture.me.scenePhaseChanged(.background)
        host.fixture.me.scenePhaseChanged(.active)
        await quietWindow(0.8)
        XCTAssertEqual(meReads, 2, "回前台")
        host.fixture.router.open(RouteRequest(route: "Help", from: .inApp))
        await settle()
        host.fixture.router.path = []
        await quietWindow(0.8)
        XCTAssertEqual(meReads, 3, "子页返回")
        XCTAssertTrue(host.controller.refresh(pull: true), "下拉")
        await quietWindow(0.8)
        XCTAssertEqual(meReads, 4, "下拉")
    }

    /// 反面：full 会话无资料时 resumeAfterIdentityConfirmed 照常补读。
    func testFullSessionResumeReads() async throws {
        let (host, _) = try await open(Setup(reply: .envelope(code: 50001, data: "null", headers: [:]), phase: .error),
                                       waitFor: nil)
        XCTAssertNil(host.repo.state.me, "前提：没有资料")
        let reads = meReads
        host.script.ok("GET /v1/me", try MeVisualData.body("me_member"))
        host.controller.resumeAfterIdentityConfirmed()
        await quietWindow(0.8)
        XCTAssertEqual(meReads, reads + 1, "补读一次")
        XCTAssertNotNil(host.repo.state.me)
    }
}
