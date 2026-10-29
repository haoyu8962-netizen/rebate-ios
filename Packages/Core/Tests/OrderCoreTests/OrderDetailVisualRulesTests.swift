import Foundation
@testable import OrderCore
import XCTest

/// APP-08v-b 详情规则层（只新增，不改已有向量）：G-O08 未知状态按钮（BR-TEXT-05 细则「未知状态下不显示写动作按钮」）、
/// 新草稿键【刷新】三端同名；已知状态按钮集合、顺序、主次、去向在视觉 fixture 上照旧（G-O06 只改视图分区，资金页回归）。
/// 三端共用向量 `detailActions.G_O08_unknown_*` 由 OrderVectorTests 逐条执行。
final class OrderDetailVisualRulesTests: XCTestCase {
    private typealias JSONObject = [String: Any]

    private func detail(_ name: String) throws -> JSONObject {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            directory = directory.deletingLastPathComponent()
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("specs/order-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONObject)
        let visual = try XCTUnwrap(root["visualOrders"] as? JSONObject)
        if let found = (visual["details"] as? JSONObject)?[name] as? JSONObject {
            return found
        }
        return try XCTUnwrap((visual["reasonDetails"] as? JSONObject)?[name] as? JSONObject, name)
    }

    private func buttons(_ name: String, change: JSONObject = [:]) throws -> [String] {
        let view = try OrderDetailActions.view(OrderJSON.lenientDetail(detail(name).merging(change) { $1 }))
        return view.buttons.map { "\($0.actionRaw)>\($0.route)\($0.primary ? "*" : "")" }
    }

    /// 未知状态：服务端下发 CLAIM / REAUTH / APPEAL / CONTACT_CS 一律不出，只留查看类【查看流水】（→ Ledger）。
    func testUnknownStatusKeepsOnlyLedger() throws {
        XCTAssertEqual(try buttons("detail_unknown"), ["ledger>Ledger*"], "G-O08：未知状态只有查看流水")
        XCTAssertEqual(try buttons("detail_unknown", change: ["reason_action": []]), ["ledger>Ledger*"])
        let pending = try OrderDetailActions.view(OrderJSON.lenientDetail(
            detail("detail_unknown").merging(["appeal_pending": true]) { $1 }
        ))
        XCTAssertTrue(pending.appealPendingBlock, "申诉中块是查看类，未知状态照旧")
    }

    /// 已知状态在视觉 fixture 上不变（资金页回归）：BLACKLIST【去申诉】；扣回 PUNISH【联系客服】主 +【查看流水】；
    /// 已结算【去提现】；扣回【查看流水】；申诉中（reason_action=[]）无按钮。
    func testKnownStatusButtonsUnchanged() throws {
        XCTAssertEqual(try buttons("detail_blacklist"), ["appeal>Appeal*"])
        XCTAssertEqual(try buttons("detail_clawed_two"), ["contact_cs>Help*", "ledger>Ledger"])
        XCTAssertEqual(try buttons("detail_settled"), ["withdraw>Withdraw*"])
        XCTAssertEqual(try buttons("detail_clawed_back"), ["ledger>Ledger*"])
        XCTAssertEqual(try buttons("detail_appeal_pending"), [])
        XCTAssertEqual(try buttons("detail_estimated"), [])
        XCTAssertEqual(try buttons("detail_settled", change: ["reason_action": ["CONTACT_CS"]]),
                       ["contact_cs>Help*", "withdraw>Withdraw"], "两个来源同时存在时规则顺序不变（视图各归各位）")
    }

    func testRefreshDraftKey() {
        XCTAssertEqual(OrderDraftTexts().text("order_detail.refresh"), "刷新", "G-O08 新草稿键三端同名")
    }
}
