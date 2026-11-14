import Foundation
@testable import WalletCore
import XCTest

/// LOCK-ios 段 3：二次验证令牌的业务摘要（BR-ID-08 细则「绑定业务摘要」；openapi StepUpBySmsRequest.summary）的纯函数与令牌缓存。
/// - `StepUpSummary.payoutChange(body:)`：只认改收款的两种形状——支付宝 {payout_method, alipay_logon_id}、借记卡 {payout_method, card_no}，
///   账号字段原样上送（服务端规范化），不带收款人姓名、开户行；读不出、方式不认识、账号缺失 / 为空 / 不是字符串都为 nil；
/// - `StepUpSummary.key(_:)`：令牌缓存的摘要键，与字典插入顺序无关；
/// - `StepUpSummary.verifyBody`：有摘要才加 summary；
/// - `StepUpTokenCache`：带摘要的令牌只给摘要相同的请求；不带摘要的（提现）照旧按同 action 复用（D10-1667）。
final class LockIosStepUpSummaryTests: XCTestCase {
    private func json(_ object: [String: Any]) -> String {
        WalletJSON.text(object)
    }

    private func object(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - payoutChange

    /// 支付宝：摘要只有 payout_method 与 alipay_logon_id 两个键，登录号原样（不脱敏、不去空白——表单已去首尾空白）；不含收款人姓名。
    func testAlipaySummaryKeepsMethodAndLogonOnly() {
        let body = json([
            "payout_method": "alipay", "alipay_logon_id": "zhangsan@example.com", "payee_name": "测试三",
        ])
        XCTAssertEqual(
            StepUpSummary.payoutChange(body: body),
            ["payout_method": "alipay", "alipay_logon_id": "zhangsan@example.com"]
        )
    }

    /// 借记卡：摘要只有 payout_method 与 card_no，卡号原样上送（空格不在客户端去掉，服务端规范化）；不含开户行、收款人姓名。
    func testBankCardSummaryKeepsMethodAndCardOnly() {
        let body = json([
            "payout_method": "bank_card", "card_no": "6222 0000 0000 0009", "bank_name": "测试银行",
            "payee_name": "测试三",
        ])
        let summary = StepUpSummary.payoutChange(body: body)
        XCTAssertEqual(summary, ["payout_method": "bank_card", "card_no": "6222 0000 0000 0009"])
        XCTAssertNil(summary?["bank_name"], "不带开户行")
        XCTAssertNil(summary?["payee_name"], "不带收款人姓名")
    }

    /// 与生产表单组出的请求体同口径（PayoutAccountForm.build → WalletJSON.text，SensitiveFlow 保存的就是这份）。
    func testSummaryFromFormBuiltBodies() throws {
        let alipay = try XCTUnwrap(PayoutAccountForm.build(PayoutForm(
            method: WalletJSON.alipay, alipayLogonId: " 13800135678 ", payeeName: " 测试三 "
        )).body)
        XCTAssertEqual(
            StepUpSummary.payoutChange(body: WalletJSON.text(alipay)),
            ["payout_method": "alipay", "alipay_logon_id": "13800135678"]
        )
        let bank = try XCTUnwrap(PayoutAccountForm.build(PayoutForm(
            method: WalletJSON.bankCard, cardNo: "6222-0000-0000-0009", bankName: "测试银行", payeeName: "测试三"
        )).body)
        XCTAssertEqual(
            StepUpSummary.payoutChange(body: WalletJSON.text(bank)),
            ["payout_method": "bank_card", "card_no": "6222-0000-0000-0009"]
        )
    }

    /// 请求体读不出：nil、空串、不是 JSON、不是对象、空对象、payout_method 不是字符串 → nil。
    func testUnreadableBodiesGiveNil() {
        let bodies: [String?] = [
            nil, "", "not json", "[]", "\"alipay\"", "{}", "{\"payout_method\":1,\"alipay_logon_id\":\"a@b.c\"}",
            "{\"payout_method\":null,\"card_no\":\"6222000000000009\"}",
        ]
        for body in bodies {
            XCTAssertNil(StepUpSummary.payoutChange(body: body), "读不出的请求体：\(body ?? "nil")")
        }
    }

    /// 方式不认识（含 iOS 没有的微信收款、大小写不同）→ nil。
    func testUnknownMethodGivesNil() {
        for method in ["wechat", "Alipay", "BANK_CARD", "", "debit_card"] {
            let body = json(["payout_method": method, "alipay_logon_id": "a@b.c", "card_no": "6222000000000009"])
            XCTAssertNil(StepUpSummary.payoutChange(body: body), "方式 \(method) 不认识")
        }
    }

    /// 账号字段缺失、为空串、不是字符串，或给的是另一种方式的账号字段 → nil。
    func testMissingAccountFieldGivesNil() {
        let bodies: [[String: Any]] = [
            ["payout_method": "alipay", "payee_name": "测试三"],
            ["payout_method": "alipay", "alipay_logon_id": ""],
            ["payout_method": "alipay", "alipay_logon_id": 13_800_135_678],
            ["payout_method": "alipay", "alipay_logon_id": NSNull()],
            ["payout_method": "alipay", "card_no": "6222000000000009"],
            ["payout_method": "bank_card", "bank_name": "测试银行"],
            ["payout_method": "bank_card", "card_no": ""],
            ["payout_method": "bank_card", "card_no": 6_222_000_000_000_009],
            ["payout_method": "bank_card", "alipay_logon_id": "a@b.c"],
        ]
        for body in bodies {
            XCTAssertNil(StepUpSummary.payoutChange(body: json(body)), "缺账号字段：\(body.keys.sorted())")
        }
    }

    // MARK: - key / verifyBody

    /// 摘要键稳定：同一份摘要不论字典插入顺序、不论从哪份请求体推出（姓名、开户行不同）都相同；账号不同则不同；没有摘要为 nil。
    func testSummaryKeyIsStable() throws {
        var first: [String: String] = [:]
        first["payout_method"] = "alipay"
        first["alipay_logon_id"] = "zhangsan@example.com"
        var second: [String: String] = [:]
        second["alipay_logon_id"] = "zhangsan@example.com"
        second["payout_method"] = "alipay"
        let key = try XCTUnwrap(StepUpSummary.key(first))
        XCTAssertEqual(key, StepUpSummary.key(second))
        XCTAssertEqual(key, "{\"alipay_logon_id\":\"zhangsan@example.com\",\"payout_method\":\"alipay\"}")
        let fromBodies = [
            json(["payout_method": "alipay", "alipay_logon_id": "zhangsan@example.com", "payee_name": "测试三"]),
            json(["payee_name": "测试四", "alipay_logon_id": "zhangsan@example.com", "payout_method": "alipay"]),
        ].map { StepUpSummary.key(StepUpSummary.payoutChange(body: $0)) }
        XCTAssertEqual(fromBodies, [key, key], "收款人姓名不进摘要键")
        XCTAssertNotEqual(
            StepUpSummary.key(["payout_method": "alipay", "alipay_logon_id": "lisi@example.com"]), key
        )
        XCTAssertNil(StepUpSummary.key(nil))
    }

    /// verifyBody：有摘要 → {action, code, summary}；没有（提现）→ 只有 {action, code}，不出现 summary 键。
    func testVerifyBodyAddsSummaryOnlyWhenGiven() throws {
        let summary = ["payout_method": "bank_card", "card_no": "6222000000000009"]
        let with = try object(StepUpSummary.verifyBody(
            action: "payout_account_change", code: "123456", summary: summary
        ))
        XCTAssertEqual(Set(with.keys), ["action", "code", "summary"])
        XCTAssertEqual(with["summary"] as? [String: String], summary)
        XCTAssertEqual(with["action"] as? String, "payout_account_change")
        XCTAssertEqual(with["code"] as? String, "123456")
        let without = try object(StepUpSummary.verifyBody(action: "withdraw", code: "654321", summary: nil))
        XCTAssertEqual(Set(without.keys), ["action", "code"])
    }

    // MARK: - StepUpTokenCache

    /// 带摘要的令牌：摘要相同复用，摘要不同、不带摘要都不复用；不带摘要的旧令牌也不用于带摘要的请求。
    func testCacheReusesOnlyForSameSummary() {
        let cache = StepUpTokenCache()
        let alipay = StepUpSummary.key(["payout_method": "alipay", "alipay_logon_id": "zhangsan@example.com"])
        let other = StepUpSummary.key(["payout_method": "alipay", "alipay_logon_id": "lisi@example.com"])
        cache.put(action: "payout_account_change", account: "user-a", token: "t-a", expireAtMs: .max, summary: alipay)
        XCTAssertEqual(
            cache.take(action: "payout_account_change", account: "user-a", nowMs: 1, summary: alipay), "t-a"
        )
        XCTAssertNil(cache.take(action: "payout_account_change", account: "user-a", nowMs: 1, summary: other))
        XCTAssertNil(cache.take(action: "payout_account_change", account: "user-a", nowMs: 1, summary: nil))
        XCTAssertNil(cache.take(action: "payout_account_change", account: "user-b", nowMs: 1, summary: alipay))
        XCTAssertEqual(
            cache.take(action: "payout_account_change", account: "user-a", nowMs: 1, summary: alipay), "t-a",
            "take 只读不核销"
        )
        cache.put(action: "payout_account_change", account: "user-a", token: "t-old", expireAtMs: .max)
        XCTAssertNil(
            cache.take(action: "payout_account_change", account: "user-a", nowMs: 1, summary: alipay),
            "不带摘要的旧令牌不用于带摘要的请求"
        )
    }

    /// 提现不带摘要：同 action、同账号、未过期就复用；过期、换账号不复用；成功核销后丢弃。
    func testWithdrawCacheReusesBySameAction() {
        let cache = StepUpTokenCache()
        cache.put(action: "withdraw", account: "user-a", token: "t-w", expireAtMs: 100)
        XCTAssertEqual(cache.take(action: "withdraw", account: "user-a", nowMs: 99), "t-w")
        XCTAssertEqual(cache.take(action: "withdraw", account: "user-a", nowMs: 50, summary: nil), "t-w")
        XCTAssertNil(cache.take(action: "withdraw", account: "user-a", nowMs: 100), "到期不带")
        XCTAssertNil(cache.take(action: "withdraw", account: "user-b", nowMs: 1))
        XCTAssertNil(cache.take(action: "payout_account_change", account: "user-a", nowMs: 1), "action 隔离")
        cache.onSuccess(action: "withdraw")
        XCTAssertNil(cache.take(action: "withdraw", account: "user-a", nowMs: 1), "成功后丢弃")
    }
}
