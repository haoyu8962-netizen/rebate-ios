@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Me
import MeCore
import Router
import UIKit
import XCTest

/// APP-12v 余额卡沿用资金页口径（brief §0、§4；类名含 Money，D10-512 不吃 verify 重试）：金额只取服务端字段、不相加不推算、缺字段 / null / 字符串不补 0、
/// 金额隐藏覆盖全部文字；【提现】任何数据下都去 Wallet。读屏覆盖在 UITests/MeVisualMoneyUITests。
@MainActor
final class MeVisualMoneyTests: MeVisualTestCase {
    /// me_no_sum 的 available（9900）故意与可提现不同：页面只显示 withdrawable / estimated_total，不出现 available 与任何相加相减结果。
    func testNoSumShowsServerFieldsOnly() async throws {
        try await open(Setup(profile: "me_no_sum"), waitFor: "me.estimate.value")
        XCTAssertEqual(try text("me.hero.amount"), MeVisualData.money(1234), "可提现 = withdrawable_fen（不是 available）")
        XCTAssertEqual(try text("me.estimate.value"), MeVisualData.money(5678), "预估 = estimated_total_fen")
        for fen: Int64 in [9900, 1234 + 5678, 5678 - 1234, 9900 + 1234, 9900 - 1234, 9900 + 5678] {
            XCTAssertFalse(allTexts.contains(MeVisualData.money(fen)), "出现了非服务端字段的金额 \(fen)")
        }
    }

    /// 负 available：可提现照服务端 0，不由 available<0 推算、不显示负数。
    func testNegativeAvailableIsNotShown() async throws {
        try await open(Setup(profile: "me_negative"), waitFor: "me.estimate.value")
        XCTAssertEqual(try text("me.hero.amount"), MeVisualData.money(0))
        XCTAssertEqual(try text("me.estimate.value"), MeVisualData.money(5678))
        XCTAssertFalse(allTexts.contains(MeVisualData.money(567)), "不显示待抵扣金额")
        XCTAssertFalse(allTexts.contains(MeVisualData.money(-567)), "不显示负数")
    }

    /// 0 只来自合法服务端 0。
    func testZeroFromServer() async throws {
        try await open(Setup(profile: "me_new_user"), waitFor: "me.estimate.value")
        XCTAssertEqual(try text("me.hero.amount"), MeVisualData.money(0))
        XCTAssertEqual(try text("me.estimate.value"), MeVisualData.money(0))
    }

    /// 隐藏：两处「****」，任何测量文字都没有原金额、没有货币符号。
    func testHiddenCoversEveryAmount() async throws {
        try await open(Setup(hidden: true), waitFor: "me.estimate.value")
        XCTAssertEqual(try text("me.hero.amount"), MeView.mask)
        XCTAssertEqual(try text("me.estimate.value"), MeView.mask)
        for wrong in [MeVisualData.money(1234), MeVisualData.money(5678), "¥"] {
            XCTAssertFalse(allTexts.contains { $0.contains(wrong) }, "隐藏时出现 \(wrong)")
        }
    }

    /// 缺字段 / null / 字符串：首读整页错误，不画主卡（不显示 ¥0）；已有内容时刷新到坏数据，金额保持上一份合法值。
    func testMalformedBalanceNotZeroFilled() async throws {
        let base = try MeVisualData.profile("me_member")
        for field in ["available_fen", "withdrawable_fen", "estimated_total_fen"] {
            let bad: [(String, Any?)] = [("缺字段", nil), ("null", NSNull()), ("字符串", "5678")]
            for (name, value) in bad {
                var object = base
                var balance = try XCTUnwrap(base["balance"] as? [String: Any])
                balance[field] = value
                object["balance"] = balance
                let data = try WalletVisualData.json(object)
                let first = WalletStubProtocol.Reply.envelope(code: 0, data: data, headers: [:])
                let (host, _) = try await open(Setup(reply: first, phase: .error), waitFor: nil)
                XCTAssertNil(host.repo.state.me, "\(field) \(name)：不造快照")

                let (kept, _) = try await open(waitFor: nil)
                let before = kept.repo.state.me
                kept.script.on("GET /v1/me", first)
                let reads = meReads
                kept.actions.refresh()
                await waitUntil("\(field) \(name)：刷新没有发出") { self.meReads == reads + 1 }
                await settle()
                await quietWindow(0.3)
                let after = kept.repo.state.me
                XCTAssertEqual(after?.withdrawableFen, before?.withdrawableFen, "\(field) \(name)：保留上一份")
                XCTAssertEqual(after?.estimatedTotalFen, before?.estimatedTotalFen, "\(field) \(name)：保留上一份")
            }
        }
    }

    /// 【提现】任何数据下可点并去 Wallet（G-M03 / G-M04 / G-M05）：空参数、一次；不预取 rules、无写请求、不直接开 Withdraw。
    func testWithdrawAlwaysGoesToWallet() async throws {
        for name in ["me_member", "me_negative", "me_frozen", "me_new_user"] {
            let setup = Setup(profile: name, custom: true)
            let (host, _) = try await open(setup, waitFor: nil)
            let env = try XCTUnwrap(host.custom?.env)
            let before = WalletStubProtocol.requests.count
            host.actions.withdraw()
            XCTAssertEqual(env.opened.map(\.route), ["Wallet"], "\(name)：恰一次、去 Wallet")
            XCTAssertEqual(env.opened.first?.params, [:], "\(name)：空参数")
            await quietWindow(0.3)
            let after = WalletStubProtocol.requests.dropFirst(before)
            XCTAssertFalse(after.contains { $0.path == "/v1/withdrawals/rules" }, "\(name)：不预取 rules")
            XCTAssertFalse(after.contains { $0.method != "GET" }, "\(name)：无写请求")
        }
    }

    /// 长金额（9999999 / 99999999 分）按 DS 格式化原样显示。
    func testLongAmountsVerbatim() async throws {
        try await open(Setup(profile: "me_long"), waitFor: "me.estimate.value")
        XCTAssertEqual(try text("me.hero.amount"), MeVisualData.money(9_999_999))
        XCTAssertEqual(try text("me.estimate.value"), MeVisualData.money(99_999_999))
        XCTAssertFalse(allTexts.contains(MeVisualData.money(9_999_999 + 99_999_999)), "不相加")
    }
}
