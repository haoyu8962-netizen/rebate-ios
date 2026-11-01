@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import Router
import SwiftUI
import UIKit
import XCTest

/// APP-12v 入口与请求（brief §4.4、§4.5、§5「计数断言」）：挪位 / 换样式后，每个入口经页面同一份渲染时回调触发一次 → 动作恰好一次、路由与参数不变；
/// 进入 / 回前台 / 子页返回 / 下拉 / 重试各一次 getMe，游客 / 基本模式 / 受限会话零次；本任务零新增请求。进程内宿主点不到 SwiftUI 按钮：
/// 真实点击（含命中区边缘）在 UITests/MeVisualUITests，本组不重复。现状已符合、加守卫。
@MainActor
final class MeVisualBehaviorTests: MeVisualTestCase {
    private func member(_ profile: String = "me_member") async throws -> (MeVisualHost, MeVisualEnv) {
        let routes = try MeVisualData.routes("routes_public")
        let (host, _) = try await open(
            Setup(profile: profile, guide: true, custom: true, routes: routes, earnings: true),
            waitFor: nil
        )
        return try (host, XCTUnwrap(host.custom?.env))
    }

    /// 全部宫格：导航一次、空参数、路由表与改前一致；客服走统一出口（来源 Me）。
    func testGridCellsOneActionEach() async throws {
        let (host, env) = try await member()
        let expected: [(String, String?)] = [
            ("我的订单", "OrderList"), ("钱包", "Wallet"), ("余额流水", "Ledger"), ("找回订单", "FindOrder"),
            ("邀请好友", "InviteShare"), ("收益看板", "Earnings"), ("帮助中心", "Help"), ("联系客服", nil),
            ("授权管理", "AuthManage"), ("设置", "Settings"),
        ]
        let cells = host.controller.view(host.repo.state, masked: false).grid
        XCTAssertEqual(cells.map(\.item), expected.map(\.0), "顺序")
        let reads = meReads
        for (cell, (item, route)) in zip(cells, expected) {
            let before = env.opened.count
            let support = env.customerServiceFrom.count
            host.actions.tap(cell)
            if let route {
                XCTAssertEqual(env.opened.count, before + 1, "\(item) 一次")
                XCTAssertEqual(env.opened.last?.route, route, item)
                XCTAssertEqual(env.opened.last?.params, [:], "\(item) 空参数")
            } else {
                XCTAssertEqual(env.customerServiceFrom.count, support + 1, "\(item) 一次")
                XCTAssertEqual(env.customerServiceFrom.last, "Me", "来源 Me")
                XCTAssertEqual(env.opened.count, before, "\(item) 不直接导航")
            }
            host.fixture.router.path = []
            await settle()
        }
        XCTAssertEqual(meReads, reads, "宫格不发 getMe（包一层的页面没有子页返回）")
    }

    /// 铃铛 → Messages {}；【提现】→ Wallet {}（不是 Withdraw，G-M05）；复制走统一写入口恰一次；眼睛不导航不请求。
    func testHeaderAndHeroActions() async throws {
        let (host, env) = try await member()
        let reads = WalletStubProtocol.requests.count
        host.actions.bell()
        XCTAssertEqual(env.opened.map(\.route), ["Messages"])
        host.fixture.router.path = []
        await settle()
        host.actions.withdraw()
        XCTAssertEqual(env.opened.map(\.route), ["Messages", "Wallet"])
        XCTAssertEqual(env.opened.last?.params, [:])
        host.fixture.router.path = []
        await settle()
        host.actions.copyInvite()
        XCTAssertEqual(env.copies, ["K7M3QX"], "恰一次")
        XCTAssertEqual(host.fixture.clipboard.last, "K7M3QX", "统一写入口")
        host.actions.toggleMask()
        host.actions.toggleMask()
        await quietWindow(0.5)
        XCTAssertEqual(env.opened.count, 2, "眼睛不导航")
        XCTAssertEqual(WalletStubProtocol.requests.count, reads, "以上动作零新增请求")
    }

    /// 引导条：正文只跳系统通知设置、不经权限申请；关闭落盘固定时钟并收起；旧回调零动作。
    func testGuideBarActions() async throws {
        let (host, _) = try await member()
        await waitUntil("引导条没判定显示") { host.controller.guideVisible }
        let stale = host.actions
        stale.openGuide()
        XCTAssertEqual(host.fixture.system.notificationSettingsOpened, 1, "只跳系统通知设置")
        XCTAssertEqual(host.fixture.system.permissionRequests, 0, "不申请权限（AC-S1-84）")
        stale.closeGuide()
        XCTAssertFalse(host.controller.guideVisible, "收起")
        XCTAssertEqual(host.fixture.local.guideClosedAt, try MeVisualData.nowMillis(), "关闭时刻落盘")
        stale.openGuide()
        XCTAssertEqual(host.fixture.system.notificationSettingsOpened, 1, "收起后旧回调零动作")
    }

    /// 回调捕获渲染时值（共性第 63 条）：快照换版本后，旧【提现】、旧复制零动作。
    func testStaleVersionCallbacks() async throws {
        let (host, env) = try await member()
        let stale = host.actions
        host.script.ok("GET /v1/me", try MeVisualData.body("me_new_user"))
        let version = host.repo.state.version
        host.actions.refresh()
        await waitUntil("新快照没到") { host.repo.state.version > version }
        stale.withdraw()
        stale.copyInvite()
        XCTAssertEqual(env.opened.count, 0, "旧【提现】不导航")
        XCTAssertEqual(env.copies, [], "旧复制不写")
    }

    /// 游客：【登录 / 注册】→ Login；帮助中心、设置各一次；getMe 零次。
    func testGuestActions() async throws {
        let setup = try Setup(profile: nil, guest: true, phase: nil, custom: true,
                              routes: MeVisualData.routes("routes_beta").union(["Login"]))
        let (host, _) = try await open(setup, waitFor: nil)
        let env = try XCTUnwrap(host.custom?.env)
        host.actions.login()
        XCTAssertEqual(env.opened.map(\.route), ["Login"])
        host.fixture.router.path = []
        await settle()
        for cell in host.controller.view(host.repo.state, masked: false).grid {
            host.actions.tap(cell)
            host.fixture.router.path = []
            await settle()
        }
        XCTAssertEqual(env.opened.map(\.route), ["Login", "Help", "Settings"])
        await quietWindow(0.5)
        XCTAssertEqual(meReads, 0, "游客零读取")
    }

    /// 真实 Tab：进入、回前台、子页返回、下拉、重试各恰一次 getMe（G36）。
    func testReadsExactlyOncePerTrigger() async throws {
        let (host, _) = try await open(waitFor: nil)
        await quietWindow(0.5)
        XCTAssertEqual(meReads, 1, "进入一次（onAppear 与切 Tab 不重复）")
        let me = host.fixture.me
        me.scenePhaseChanged(.background)
        me.scenePhaseChanged(.active)
        await waitUntil("回前台没有读取") { self.meReads == 2 }
        await quietWindow(0.5)
        XCTAssertEqual(meReads, 2, "回前台一次")
        host.fixture.router.open(RouteRequest(route: "Settings", from: .inApp))
        await settle()
        host.fixture.router.path = []
        await waitUntil("子页返回没有读取") { self.meReads == 3 }
        await quietWindow(0.5)
        XCTAssertEqual(meReads, 3, "子页返回一次")
        await waitUntil("进入没有落定") { host.repo.state.phase == .content && !host.repo.state.refreshing }
        XCTAssertTrue(host.controller.refresh(pull: true), "下拉")
        await waitUntil("下拉没有读取") { self.meReads == 4 }
        await quietWindow(0.5)
        XCTAssertEqual(meReads, 4, "下拉一次")
        host.actions.refresh()
        await waitUntil("重试没有读取") { self.meReads == 5 }
        await quietWindow(0.5)
        XCTAssertEqual(meReads, 5, "重试一次")
        XCTAssertEqual(WalletStubProtocol.requests("GET", "/v1/wallet/summary").count, 0, "不为余额卡附注调钱包摘要（G-M02）")
    }

    /// 基本模式零读取。
    func testBasicModeNoRead() async throws {
        try await open(Setup(profile: nil, decision: "basic_mode", phase: nil), waitFor: nil)
        await quietWindow(0.5)
        XCTAssertEqual(meReads, 0, "基本模式零读取")
    }
}
