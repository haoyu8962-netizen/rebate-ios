@testable import Couli
import DesignSystem
import Foundation
import MeCore
import SwiftUI
import UIKit
import XCTest

/// APP-12v 状态矩阵（brief §2.1 无稿部分、§2.10–12）：骨架按新结构、整页错误、禁用期、受限会话、主卡在冻结 / 待抵扣数据下版式不变。
@MainActor
final class MeVisualStateTests: MeVisualTestCase {
    /// M17：身份卡块（56 圆 + 两条横块）→ 余额卡块（通栏、高 ≥ 160、muted）→ 宫格块；浅深分别查，每块独立判，不用总面积凑数。
    func testSkeletonNewStructure() async throws {
        for dark in [false, true] {
            let setup = Setup(canvas: .init(dark: dark), reply: .hold, phase: .loading)
            let (_, image) = try await open(setup, waitFor: "me.skeleton.grid")
            let avatar = try rect("me.skeleton.avatar")
            assertNear(avatar.width, 56, 0.5, "圆块 56")
            assertNear(avatar.height, 56, 0.5, "圆块 56")
            assertNear(avatar.minX, 32, 1, "身份卡内 16")
            let name = try rect("me.skeleton.name")
            let invite = try rect("me.skeleton.invite")
            assertNear(name.minX - avatar.maxX, 12, 1, "横块在头像右 12")
            XCTAssertGreaterThanOrEqual(invite.minY, name.maxY, "第二条在第一条之下")
            XCTAssertLessThanOrEqual(invite.maxY, avatar.maxY + 0.5, "两条都在头像高度内")
            let balance = try rect("me.skeleton.balance")
            assertNear(balance.width, 358, 1, "余额卡块通栏")
            XCTAssertGreaterThanOrEqual(balance.height, 160, "主卡高度")
            let grid = try rect("me.skeleton.grid")
            assertNear(grid.minY - balance.maxY, 12, 1.5, "宫格块在下 12")
            XCTAssertGreaterThanOrEqual(grid.height, 100, "宫格块")
            let muted = pixel(CouliColor.backgroundMuted, dark: dark)
            for (id, box) in [("name", name), ("invite", invite), ("balance", balance), ("grid", grid)] {
                XCTAssertGreaterThan(share(image, in: box.insetBy(dx: 6, dy: 2), near: muted, tolerance: 3), 0.8,
                                     "\(id) 画成 muted 块（\(dark ? "深" : "浅")）")
            }
            XCTAssertEqual(meReads, 1, "骨架一次读取")
        }
    }

    /// G-M11：无缓存 50001 / 断网：ErrorState 不改，带 trace6；不回落游客、不画余额卡；【重试】恰一次读取。
    func testFullPageError() async throws {
        let (host, _) = try await open(Setup(reply: .envelope(code: 50001, data: "null", headers: [:]), phase: .error),
                                       waitFor: "me.error")
        XCTAssertTrue(try XCTUnwrap(host.repo.state.error).message(host.texts).contains("6789ab"), "带 trace6")
        XCTAssertFalse(has("me.hero"), "不画余额卡")
        XCTAssertFalse(has("me.guest"), "不回落游客")
        XCTAssertTrue(has("me.grid.orders_wallet"), "宫格照常")
        let reads = meReads
        host.actions.refresh()
        await waitUntil("重试没有发出") { self.meReads == reads + 1 }
        await quietWindow(0.5)
        XCTAssertEqual(meReads, reads + 1, "【重试】恰好一次")
        let (network, _) = try await open(Setup(reply: .disconnect, phase: .error), waitFor: "me.error")
        XCTAssertEqual(network.repo.state.phase, .error, "断网整页错误")
    }

    /// 42901 禁用期：整页错误 +【重试】不发请求；下拉不发请求（闸门不变）。
    func testBlockedWindow() async throws {
        let reply = WalletStubProtocol.Reply.envelope(code: 42901, data: "null", headers: ["Retry-After": "30"])
        let (host, _) = try await open(Setup(reply: reply, phase: .error), waitFor: "me.error")
        XCTAssertTrue(host.fixture.me.gates.read.active)
        let reads = meReads
        host.actions.refresh()
        XCTAssertFalse(host.controller.refresh(pull: true), "禁用期不可下拉")
        await quietWindow(0.5)
        XCTAssertEqual(meReads, reads, "禁用期零请求")
    }

    /// 受限会话（deletion_only）：不自动读取，停在骨架（F-X-14），新结构同样画出来。各触发路径的次数在 MeVisualRestrictedTests。
    func testRestrictedSessionNoRead() async throws {
        let (host, _) = try await open(Setup(scope: "deletion_only", phase: nil), waitFor: "me.skeleton.grid")
        await quietWindow(1.5)
        XCTAssertEqual(meReads, 0, "受限会话零读取")
        XCTAssertEqual(host.fixture.client.isolatedSessionScope, "deletion_only", "前提：会话确实受限")
        XCTAssertFalse(has("me.guest"), "前提：不是掉成游客")
        XCTAssertFalse(has("me.hero"), "没有资料就不画余额卡")
    }

    /// MeStates：待抵扣 / 冻结数据下主卡版式不变（各框与正常数据逐项一致），不加置灰与警告条（G-M03 / G-M04）。
    func testHeroLayoutSameAcrossData() async throws {
        let ids = ["me.hero", "me.hero.titleRow", "me.hero.withdraw", "me.estimate"]
        try await open(waitFor: "me.estimate")
        let normal = try ids.map { try rect($0) }
        for name in ["me_negative", "me_frozen"] {
            let (_, image) = try await open(Setup(profile: name), waitFor: "me.estimate")
            for (index, id) in ids.enumerated() {
                let box = try rect(id)
                assertNear(box.minY, normal[index].minY, 1, "\(name) \(id) 纵向位置")
                assertNear(box.height, normal[index].height, 1, "\(name) \(id) 高度")
            }
            let button = try rect("me.hero.withdraw")
            let fill = CGRect(x: button.minX + 10, y: button.midY - 4, width: 10, height: 8)
            XCTAssertGreaterThan(
                share(image, in: fill, near: pixel(CouliColor.token("rebate.solid.text"), dark: false),
                      tolerance: 4),
                0.9,
                "\(name)：【提现】不置灰"
            )
            XCTAssertFalse(allTexts.contains { $0.contains("待抵扣") }, "\(name)：不由 available<0 推算待抵扣（G-M03）")
        }
    }
}
