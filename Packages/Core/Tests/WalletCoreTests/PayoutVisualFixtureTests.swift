import CryptoKit
import Foundation
@testable import WalletCore
import XCTest

/// APP-09v-e 共用 fixture 自检（G-W25）：`specs/wallet-vectors.json` 与 Android 5a795b5 合入版逐字节相同（SHA-256 e977eade…），
/// 旧组只在根末尾追加 `visualPayout`；五份收款账号按生产解析器严格解析；纯规则不动；草稿 `payout.bank_note` 是本组预期红（G-W23）。
final class PayoutVisualFixtureTests: XCTestCase {
    private func vectors() throws -> Data {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            directory = directory.deletingLastPathComponent()
        }
        return try Data(contentsOf: directory.appendingPathComponent("specs/wallet-vectors.json"))
    }

    private func visual() throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: vectors()) as? [String: Any])
        return try XCTUnwrap(root["visualPayout"] as? [String: Any], "共用向量缺 visualPayout（G-W25）")
    }

    /// 旧组一字不改：`"visualPayout"` 之前的字节 = 入场版去掉根收尾后加逗号。
    func testOldGroupsByteIdentical() throws {
        let data = try vectors()
        let marker = try XCTUnwrap(data.range(of: Data("\"visualPayout\"".utf8)))
        let digest = SHA256.hash(data: data[..<marker.lowerBound]).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "ed1e95b8f35bd92650de69bea51f31f3787c0c3e2b90bf7a55b9f6d8def1799d")
    }

    func testPayoutParsesStrictly() throws {
        let payout = try XCTUnwrap(visual()["payout"] as? [String: Any])
        XCTAssertEqual(Set(payout.keys), ["unbound", "boundAlipay", "boundBank", "boundExhausted", "boundStress"])
        for name in ["boundAlipay", "boundBank", "boundExhausted", "boundStress"] {
            guard case .bound = try XCTUnwrap(WalletJSON.payoutAccount(payout[name]), name) else {
                return XCTFail("\(name) 应解析为已绑定")
            }
        }
    }

    /// G-W21 的「字段 null 不置灰」在 iOS 不可达：契约把 `change_remaining_this_month` 列为必填，生产解析缺字段或为 null 都整份作废。
    func testRemainingFieldIsRequired() throws {
        let payout = try XCTUnwrap(visual()["payout"] as? [String: Any])
        var missing = try XCTUnwrap(payout["boundAlipay"] as? [String: Any])
        missing["change_remaining_this_month"] = nil
        XCTAssertNil(WalletJSON.payoutAccount(missing), "缺字段")
        var null = missing
        null["change_remaining_this_month"] = NSNull()
        XCTAssertNil(WalletJSON.payoutAccount(null), "null")
    }

    /// 键名不含敏感词（gitleaks 误报经验）。
    func testKeysClean() throws {
        let text = try String(data: JSONSerialization.data(withJSONObject: visual()), encoding: .utf8) ?? ""
        for word in ["\"token\"", "\"secret\"", "\"password\""] {
            XCTAssertFalse(text.contains(word), word)
        }
    }

    /// 纯规则不动：过滤与规整（G-W13 / G-W23 只在视图层；显示对回也不改这些规则）。
    func testPureRulesUnchanged() {
        XCTAssertEqual(PayoutAccountForm.acceptCardNo(current: "6222", next: "6222x"), "6222", "卡号拒绝字母")
        XCTAssertEqual(PayoutAccountForm.acceptCardNo(current: "", next: "6222 0000-1"), "6222 0000-1", "卡号收空格连字符")
        XCTAssertEqual(RealNameForm.acceptIdNo(current: "123", next: "123a"), "123", "身份证拒绝字母")
        XCTAssertEqual(RealNameForm.acceptIdNo(current: "", next: "12x"), "12X", "小写 x 转大写")
        let tooLong = String(repeating: "1", count: 19)
        XCTAssertEqual(RealNameForm.acceptIdNo(current: "1", next: tooLong), "1", "超 18 位拒绝")
        XCTAssertEqual(PayoutAccountForm.clip("abcdef", max: 3), "abc", "按标量截断")
    }

    /// G-W23：银行卡说明不承诺三要素核验（预期红：草稿未改）。
    func testDraftBankNote() {
        XCTAssertEqual(WalletDraftTexts.drafts["payout.bank_note"], "保存时需要短信验证")
    }
}
