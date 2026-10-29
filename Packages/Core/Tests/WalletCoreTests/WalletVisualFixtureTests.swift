import Foundation
@testable import WalletCore
import XCTest

/// APP-09v-a 共用 fixture 自检与执行层守卫：visualWallet（G-W25，与 Android 33d6b62 版逐字节相同）每份摘要严格解析；no_sum 的显示结论只取
/// 服务端字段；草稿键按 G-W06 / G-W07 改（三端同名同字）。
final class WalletVisualFixtureTests: XCTestCase {
    private let names = ["normal", "frozen", "negative", "risk", "disabled", "no_month", "overdue", "received_zero",
                         "long_amounts", "no_sum"]

    func testVisualWalletSummariesParseStrictly() throws {
        let root = try visual()
        XCTAssertEqual(root["clock"] as? String, "2026-10-22T10:32:00+08:00")
        XCTAssertEqual(root["cachedAt"] as? String, "2026-10-22T09:30:00+08:00")
        let summaries = try XCTUnwrap(root["summaries"] as? [String: Any])
        XCTAssertEqual(Set(summaries.keys), Set(names))
        for name in names {
            let object = try XCTUnwrap(summaries[name] as? [String: Any], name)
            XCTAssertEqual(object.count, 13, "\(name)：WalletSummary 13 个字段")
            let summary = try XCTUnwrap(WalletJSON.summary(object), "\(name)：生产解析不出")
            XCTAssertEqual(summary.withdrawableFen, (object["withdrawable_fen"] as? NSNumber)?.int64Value, name)
            XCTAssertEqual(summary.estimatedTotalFen, (object["estimated_total_fen"] as? NSNumber)?.int64Value, name)
        }
    }

    /// no_sum：可提现、冻结、已提现、预估、已收货、暂缓逐项取服务端字段，不相加、不用 available / estimated_fen 代替。
    func testNoSumDisplayTakesServerFields() throws {
        let object = try XCTUnwrap((try visual()["summaries"] as? [String: Any])?["no_sum"] as? [String: Any])
        let summary = try XCTUnwrap(WalletJSON.summary(object))
        let view = WalletSummaryView.of(summary, masked: false, nowMs: 1_792_636_320_000)
        XCTAssertEqual(view.hero.fen, 1234)
        XCTAssertEqual(view.frozen.fen, 456)
        XCTAssertEqual(view.withdrawn.fen, 789)
        XCTAssertEqual(view.estimated.fen, 5678)
        XCTAssertEqual(view.receivedLine.fen, 2)
        XCTAssertEqual(view.pausedLine?.fen, 3)
        XCTAssertTrue(view.withdrawEnabled)
    }

    /// 置灰判定不变（视觉任务一字不改）：待抵扣、withdraw_enabled=false 置灰；风控冻结不置灰。
    func testWithdrawEnabledRulesUnchanged() throws {
        let summaries = try XCTUnwrap(try visual()["summaries"] as? [String: Any])
        let expected = ["normal": true, "frozen": true, "negative": false, "risk": true, "disabled": false]
        for (name, enabled) in expected {
            let summary = try XCTUnwrap(WalletJSON.summary(summaries[name]))
            XCTAssertEqual(WalletSummaryView.of(summary, masked: false, nowMs: 0).withdrawEnabled, enabled, name)
        }
    }

    /// G-W06：待抵扣首行草稿改为「待抵扣 {amount}」（次行取契约键 error.30302）；G-W07：新增「结算进度」草稿（TODO(N-32)）。
    func testDraftKeysPerGW06GW07() {
        XCTAssertEqual(WalletDraftTexts.drafts["wallet.negative"], "待抵扣 {amount}", "G-W06")
        XCTAssertEqual(WalletDraftTexts.drafts["wallet.settle_progress"], "结算进度", "G-W07")
        XCTAssertTrue(WalletDraftTexts().has("error.30302"), "次行用契约键")
    }

    private func visual() throws -> [String: Any] {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { throw XCTSkip("找不到 contract.lock") }
            directory = parent
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("specs/wallet-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["visualWallet"] as? [String: Any], "缺 visualWallet（G-W25）")
    }
}
