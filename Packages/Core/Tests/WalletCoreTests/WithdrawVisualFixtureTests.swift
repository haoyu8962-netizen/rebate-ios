import CryptoKit
import Foundation
@testable import WalletCore
import XCTest

/// APP-09v-c 共用 fixture 自检（G-W25）：`visualWithdraw` 与 Android 6770a58 合入版逐字节相同（文件 SHA-256
/// a39b53ad48e9d6f84b1b16929dcc00d05187056ccacc549960042e73ed9ec5c9），旧组只在根末尾追加；每份 rules / 收款账号按生产解析器严格解析；
/// 规则与引导表不动（G-W13 / 14 / 15 只在视图层）。草稿键 `withdraw.guide.rules` 是本组唯一预期红（缺实现）。
final class WithdrawVisualFixtureTests: XCTestCase {
    private func vectors() throws -> Data {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            directory = directory.deletingLastPathComponent()
        }
        return try Data(contentsOf: directory.appendingPathComponent("specs/wallet-vectors.json"))
    }

    private func visual() throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: vectors()) as? [String: Any])
        return try XCTUnwrap(root["visualWithdraw"] as? [String: Any], "共用向量缺 visualWithdraw（G-W25）")
    }

    /// 旧组一字不改：`"visualWithdraw"` 之前的字节 = 入场底版去掉根收尾后再加逗号（后续组继续追加在末尾也不破坏本断言）。
    func testOldGroupsByteIdentical() throws {
        let data = try vectors()
        let marker = try XCTUnwrap(data.range(of: Data("\"visualWithdraw\"".utf8)))
        let digest = SHA256.hash(data: data[..<marker.lowerBound]).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "58b87b43f2d5e9ff3e08600f72458acfa2d0ec51e4947c1e6c3d0a50eb933772")
    }

    func testRulesAndPayoutParseStrictly() throws {
        let root = try visual()
        XCTAssertEqual(((root["clock"] as? [String: Any])?["nowMillis"] as? NSNumber)?.int64Value, 1_791_772_200_000)
        let rules = try XCTUnwrap(root["rules"] as? [String: Any])
        XCTAssertEqual(rules.count, 25, "正常、估算、独立金额、压力 + 21 个 code / reason")
        for (name, raw) in rules {
            let parsed = try XCTUnwrap(WalletJSON.rules(raw), "\(name)：生产 rules 解析不出")
            XCTAssertEqual(
                parsed.withdrawableFen,
                (raw as? [String: Any])?["withdrawable_fen"].flatMap { ($0 as? NSNumber)?.int64Value },
                name
            )
        }
        let states = try XCTUnwrap(root["pageStates"] as? [String])
        XCTAssertEqual(states.count, 21)
        XCTAssertTrue(states.allSatisfy { rules[$0] != nil })
        let payout = try XCTUnwrap(root["payout"] as? [String: Any])
        let bound = try XCTUnwrap(WalletJSON.payoutAccount(payout["bound"]))
        guard case let .bound(account) = bound else {
            return XCTFail("bound 报文应解析为已绑定")
        }
        XCTAssertEqual(account.maskedAccount, "138****5678")
    }

    /// 估算只取 est_*（不做加减）、时效回落句、`amountEditable`：纯规则不动（守卫）。
    func testPureRulesUnchanged() throws {
        let root = try visual()
        let rules = try XCTUnwrap(root["rules"] as? [String: Any])
        let independent = try XCTUnwrap(WalletJSON.rules(rules["independent"]))
        XCTAssertEqual(
            WithdrawRulesView.estimate(independent, inputFen: 1000),
            .full(netFen: 876, feeFen: 34, taxFen: 56)
        )
        let realname = try XCTUnwrap(WalletJSON.rules(rules["blocked_30304"]))
        XCTAssertFalse(WithdrawRulesView.of(realname, inputFen: nil, slaText: nil).amountEditable)
        let code30309 = WithdrawBlockGuide.view(blockCode: 30309, blockReason: nil)
        XCTAssertEqual(code30309.actionRaw, WithdrawBlockGuide.notice, "G-W15 不改引导表")
        XCTAssertNil(code30309.buttonKey)
        let frozen = WithdrawBlockGuide.view(blockCode: 30303, blockReason: "account_frozen")
        XCTAssertEqual(frozen.textKey, "error.30303.account_frozen")
    }

    /// G-W15 / G-W27：草稿键（三端同名同字）。底版缺，预期红。
    func testDraftGuideRulesKey() {
        XCTAssertEqual(WalletDraftTexts.drafts["withdraw.guide.rules"], "查看提现规则")
        XCTAssertEqual(WalletDraftTexts.drafts["withdraw.guide.payout"], "去绑定收款账号")
        XCTAssertEqual(WalletDraftTexts.drafts["withdraw.guide.labor"], "去签署劳务协议")
    }
}
