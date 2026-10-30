import CryptoKit
import Foundation
@testable import WalletCore
import XCTest

/// APP-09v-b（提现记录视觉）共用 fixture 自检与执行层守卫：`visualWithdrawRecords`（G-W25，与 Android 49a1eb9 合入版逐字节相同）
/// 每份详情 / 列表报文按生产解析器严格解析；收起行首句的来源（`WithdrawalText.render` 第一项）与旧规则输出一致（G-W08 只切展示、G-W09
/// 不改分支）；纯规则与执行器源文件指纹与底版 b0ed6f4 相同（资金逻辑零改动守卫，brief §3 / §5）。本文件全部用例在底版上应为绿。
final class RecordsVisualFixtureTests: XCTestCase {
    static func repo() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }

    private func visual() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repo().appendingPathComponent("specs/wallet-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["visualWithdrawRecords"] as? [String: Any], "共用向量缺 visualWithdrawRecords 组（G-W25）")
    }

    /// 固定时钟 2026-10-12 10:30 +08:00；27 份详情（带 channel_order_id）与 36 份列表全部严格解析，不丢条。
    func testFixtureParsesStrictly() throws {
        let root = try visual()
        let clock = try XCTUnwrap(root["clock"] as? [String: Any])
        XCTAssertEqual((clock["nowMillis"] as? NSNumber)?.int64Value, 1_791_772_200_000)
        XCTAssertEqual(clock["zone"] as? String, "Asia/Shanghai")
        let details = try XCTUnwrap(root["details"] as? [String: Any])
        XCTAssertEqual(details.count, 27)
        for (name, raw) in details {
            let object = try XCTUnwrap(raw as? [String: Any], name)
            let detail = try XCTUnwrap(WalletJSON.withdrawalDetail(object), "\(name)：生产详情解析不出")
            XCTAssertTrue(detail.isDetail, name)
            XCTAssertEqual(detail.channelOrderId, object["channel_order_id"] as? String, name)
            XCTAssertEqual(detail.amountFen, (object["amount_fen"] as? NSNumber)?.int64Value, name)
            XCTAssertEqual(detail.netFen, (object["net_fen"] as? NSNumber)?.int64Value, name)
        }
        let pages = try XCTUnwrap(root["pages"] as? [String: Any])
        XCTAssertEqual(pages.count, 36)
        for (name, raw) in pages {
            let object = try XCTUnwrap(raw as? [String: Any], name)
            let list = try XCTUnwrap(WalletJSON.withdrawalList(object), "\(name)：生产列表解析不出")
            XCTAssertEqual(list.dropped, 0, "\(name)：不丢条")
            XCTAssertEqual(list.items.count, (object["items"] as? [Any])?.count, name)
        }
        // 画板上出现的每类元素都在（brief §5「fixture 必须包含画板上出现的每类元素」）：长流水号、两种失败、税、线下转账、未知状态
        let paid = try XCTUnwrap(details["paid"] as? [String: Any])
        XCTAssertGreaterThanOrEqual((paid["channel_order_id"] as? String)?.count ?? 0, 19, "已到账流水号 ≥ 19 位")
        let stress = try XCTUnwrap(details["stress"] as? [String: Any])
        XCTAssertEqual((stress["channel_order_id"] as? String)?.count, 32, "200% 压力流水号 32 位")
        XCTAssertEqual((details["failed"] as? [String: Any])?["fail_action"] as? String, "change_payout_account")
        XCTAssertEqual((details["rejected"] as? [String: Any])?["reason_code"] as? String, "PAYEE_INFO_INVALID")
        XCTAssertEqual(((details["tax"] as? [String: Any])?["tax_fen"] as? NSNumber)?.int64Value, 80)
        XCTAssertEqual((details["manual"] as? [String: Any])?["status"] as? String, "PAID_MANUAL")
        XCTAssertEqual((details["unknown"] as? [String: Any])?["status"] as? String, "FUTURE_STATUS")
    }

    /// 收起行首句 = `WithdrawalText.render` 第一项（含原因与退回句之间的分号，G-W08）；全文不变（G-W09 / G-W11 维持现行分支）。
    func testCollapsedFirstSentenceSource() throws {
        let root = try visual()
        let pages = try XCTUnwrap(root["pages"] as? [String: Any])
        let list = try XCTUnwrap(WalletJSON.withdrawalList(pages["list"]))
        let config = try XCTUnwrap(root["config"] as? [String: Any])
        let sla = try XCTUnwrap((config["texts"] as? [String: Any])?["withdraw.sla_text"] as? String)
        let texts = WalletDraftTexts()
        let money: (Int64) -> String = { "¥\($0 / 100)" }
        let rendered = Dictionary(uniqueKeysWithValues: list.items.map { item in
            (
                item.withdrawalId,
                WithdrawalText.render(WithdrawalText.of(item, slaText: sla), texts: texts, money: money)
            )
        })
        XCTAssertEqual(rendered["PENDING"], [sla, "¥10 已冻结"])
        XCTAssertEqual(rendered["FAILED"], ["收款支付宝账号状态异常；¥8 已退回可提现余额，可修改收款账号后重新提现"])
        XCTAssertEqual(rendered["PAID"], ["已转入支付宝 138****5678，到账 ¥5"], "G-W11：维持现行句")
        XCTAssertEqual(rendered["REJECTED"]?.first, "收款信息有误，请核对后重新申请；¥6 已退回可提现余额")
        let tax = try XCTUnwrap(WalletJSON.withdrawalDetail((root["details"] as? [String: Any])?["tax"]))
        XCTAssertEqual(WithdrawalText.render(WithdrawalText.of(tax, slaText: sla), texts: texts, money: money).count, 2,
                       "税句是第二项（收起只显示首句，税句进展开与读屏）")
        let unknown = try XCTUnwrap(WalletJSON.withdrawalDetail((root["details"] as? [String: Any])?["unknown"]))
        let display = WithdrawalText.of(unknown, slaText: sla)
        XCTAssertEqual(display.titleKey, "withdrawal_status.UNKNOWN.title")
        XCTAssertEqual(texts.text(display.titleKey), "处理中")
        XCTAssertFalse(display.showChangeAccount, "未知状态不出写操作")
        XCTAssertNil(TradeNoRow.copyText(status: unknown.status, channelOrderId: unknown.channelOrderId), "未知状态不出复制")
    }

    /// 资金逻辑零改动守卫（brief §3 / §5、prompt「纯规则与执行器只做回归守卫」）：与底版 b0ed6f4 逐字节相同。
    func testRecordsLogicFilesUnchanged() throws {
        let expected = [
            "Packages/Core/Sources/WalletCore/WithdrawalText.swift":
                "5ff34329d980f5d414f2ada37cacee92822f09b23339c99218b9007fa2bf3962",
            "Packages/Core/Sources/WalletCore/WithdrawRecordSections.swift":
                "570205c5195f28ed86deed1a77c7541d70033d4786bb13a9d7fee9db942e3494",
            "Packages/Core/Sources/WalletCore/WithdrawRecordsController.swift":
                "844674f72e23d8b10b29fa446bfe89f076e1cee6ddabcabbac272da0a30680df",
            "Packages/Core/Sources/WalletCore/WithdrawRecordsController+Items.swift":
                "94bbc78d8fe73f0bbe552551fa9539134477678e048437b545ecb10edd31a202",
            "Packages/Core/Sources/WalletCore/WalletModels.swift":
                "4c8f7ce8a7beb4c8ffb5ca5d4f7fa8fdd8d70c34318cf17cb9cf3564c26b34cb",
            "Packages/Core/Sources/WalletCore/WalletRequests.swift":
                "4355d3c00a9eb0d922bfa5e93e02b009c9cc58005f8167ff8810c448b01e03d5",
        ]
        for (path, hash) in expected.sorted(by: { $0.key < $1.key }) {
            let data = try Data(contentsOf: Self.repo().appendingPathComponent(path))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual, hash, "\(path) 被改动（资金 / 纯规则文件本任务不动）")
        }
    }
}
