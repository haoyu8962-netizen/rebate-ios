@testable import Couli
import Foundation
import XCTest

/// LOCK-ios 段 3：Debug 假服务（DebugFakeWallet / DebugFakeMe）的二次验证分支，直接调假服务的回答入口（不经网络管线）。
/// - 发码 sendSmsCode purpose=step_up：带 phone → 20001 fields=[phone]；没带令牌 → 10001；假账号没绑手机 → 20001 fields=[code]；
///   其余 → 60 秒倒计时；
/// - 验证 stepUp：改收款缺摘要 / 形状不对 → 20001 fields=[summary]；提现带摘要 → 20001；
/// - 保存 PUT /v1/me/payout-account：令牌绑定的摘要与请求体推出的不一致 → 10003 且令牌不核销；提现不比对摘要；
/// - 假 Me 的 masked_phone：已绑 138****5678，没绑 null。
/// 假账号的绑定状态在 `DebugFakeOAuth.shared`（进程内单例）：第三方新号登录置为没绑，绑手机成功恢复已绑；每个用例结束恢复已绑。
@MainActor
final class LockIosFakeWalletStepUpTests: XCTestCase {
    static let walletKey = DebugFakeWallet.launchArgument
    static let alipay: [String: Any] = ["payout_method": "alipay", "alipay_logon_id": "zhangsan@example.com"]
    static let auth = ["Authorization": "Bearer debug-at"]

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.walletKey)
        UserDefaults.standard.removeObject(forKey: DebugFakeOAuth.launchArgument)
        setBound(true)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: Self.walletKey)
        setBound(true)
        try await super.tearDown()
    }

    /// 假账号的 phone_bound：false = 第三方新号登录；true = 绑手机成功（验证码 123456）。
    func setBound(_ bound: Bool) {
        let oauth = DebugFakeOAuth.shared
        if bound {
            _ = oauth.answer(method: "POST", path: "/v1/me/phone", body: ["phone": "13800000000", "code": "123456"])
        } else {
            _ = oauth.answer(method: "POST", path: "/v1/auth/login/wechat", body: [:])
        }
        XCTAssertEqual(oauth.phoneBound, bound, "前提：假账号绑定状态")
    }

    func sms(
        _ fake: DebugFakeWallet,
        _ body: [String: Any],
        headers: [String: String] = LockIosFakeWalletStepUpTests.auth
    ) -> DebugFakeWallet.Reply? {
        fake.answer(method: "POST", path: "/v1/auth/sms-codes", query: [:], body: body, headers: headers)
    }

    func stepUp(_ fake: DebugFakeWallet, _ body: [String: Any]) -> DebugFakeWallet.Reply? {
        fake.answer(method: "POST", path: "/v1/auth/step-up", query: [:], body: body, headers: [:])
    }

    func save(_ fake: DebugFakeWallet, _ body: [String: Any], key: String, token: String) -> DebugFakeWallet.Reply? {
        fake.answer(method: "PUT", path: "/v1/me/payout-account", query: [:], body: body,
                    headers: ["Idempotency-Key": key, "X-Step-Up-Token": token])
    }

    func code(_ reply: DebugFakeWallet.Reply?) -> Int? {
        if case let .answer(code, _, _) = reply {
            return code
        }
        return nil
    }

    func data(_ reply: DebugFakeWallet.Reply?) -> [String: Any] {
        guard case let .answer(_, text, _) = reply,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return [:] }
        return object
    }

    func fields(_ reply: DebugFakeWallet.Reply?) -> [String] {
        data(reply)["fields"] as? [String] ?? []
    }

    /// 改收款令牌（按 `summary` 签发）。
    func payoutToken(_ fake: DebugFakeWallet,
                     summary: [String: Any] = LockIosFakeWalletStepUpTests.alipay) throws -> String {
        let reply = stepUp(fake, ["action": "payout_account_change", "code": "123456", "summary": summary])
        XCTAssertEqual(code(reply), 0, "前提：改收款令牌签发")
        return try XCTUnwrap(data(reply)["step_up_token"] as? String)
    }

    // MARK: - 发码

    /// step_up 发码的四个分支；登录用途的发码不归钱包假服务回答。
    func testStepUpSmsBranches() {
        let fake = DebugFakeWallet()
        let withPhone = sms(fake, ["purpose": "step_up", "action": "withdraw", "phone": "13800005678"])
        XCTAssertEqual(code(withPhone), 20001)
        XCTAssertEqual(fields(withPhone), ["phone"], "带 phone → 20001 fields=[phone]")

        let anonymous = sms(fake, ["purpose": "step_up", "action": "withdraw"], headers: [:])
        XCTAssertEqual(code(anonymous), 10001, "没带令牌 → 10001")

        let ok = sms(fake, ["purpose": "step_up", "action": "payout_account_change"])
        XCTAssertEqual(code(ok), 0)
        XCTAssertEqual(data(ok)["resend_after_sec"] as? Int, 60)

        setBound(false)
        let unbound = sms(fake, ["purpose": "step_up", "action": "withdraw"])
        XCTAssertEqual(code(unbound), 20001)
        XCTAssertEqual(fields(unbound), ["code"], "没绑手机 → 20001 fields=[code]")

        XCTAssertNil(sms(fake, ["purpose": "login", "phone": "13800005678"]), "登录发码不归钱包假服务")
    }

    // MARK: - 验证

    /// 改收款：缺摘要、摘要不是对象、多了收款人姓名、方式不认识、缺账号字段、账号为空 → 20001 fields=[summary]；形状对 → 签发令牌。
    func testPayoutVerifyRequiresWellFormedSummary() {
        let fake = DebugFakeWallet()
        let bad: [Any?] = [
            nil, "p:alipay:zhangsan@example.com",
            ["payout_method": "alipay", "alipay_logon_id": "zhangsan@example.com", "payee_name": "测试三"],
            ["payout_method": "wechat", "alipay_logon_id": "zhangsan@example.com"],
            ["payout_method": "alipay"], ["payout_method": "bank_card", "alipay_logon_id": "zhangsan@example.com"],
            ["payout_method": "alipay", "alipay_logon_id": ""],
            ["payout_method": "bank_card", "card_no": "6222000000000009", "bank_name": "测试银行"],
        ]
        for (index, summary) in bad.enumerated() {
            var body: [String: Any] = ["action": "payout_account_change", "code": "123456"]
            body["summary"] = summary
            let reply = stepUp(fake, body)
            XCTAssertEqual(code(reply), 20001, "第 \(index) 种坏摘要")
            XCTAssertEqual(fields(reply), ["summary"], "第 \(index) 种坏摘要")
        }
        let bank = stepUp(fake, [
            "action": "payout_account_change", "code": "123456",
            "summary": ["payout_method": "bank_card", "card_no": "6222 0000 0000 0009"],
        ])
        XCTAssertEqual(code(bank), 0, "借记卡摘要形状对")
        XCTAssertEqual(code(stepUp(fake, ["action": "payout_account_change", "code": "123456",
                                          "summary": Self.alipay])), 0, "支付宝摘要形状对")
    }

    /// 提现带摘要 → 20001 fields=[summary]；不带 → 签发令牌（过渡期提现照旧要令牌，D10-1667）。
    func testWithdrawVerifyRejectsSummary() {
        let fake = DebugFakeWallet()
        let with = stepUp(fake, ["action": "withdraw", "code": "123456", "summary": Self.alipay])
        XCTAssertEqual(code(with), 20001)
        XCTAssertEqual(fields(with), ["summary"])
        XCTAssertEqual(code(stepUp(fake, ["action": "withdraw", "code": "123456"])), 0)
    }

    // MARK: - 保存

    /// 令牌摘要与保存请求体对不上 → 10003，且令牌不核销（step_up=always 下也还在）；对得上 → 保存成功（always 下核销）。
    /// 比对按假服务的规范化：支付宝登录号去首尾空白、卡号只留数字；收款人姓名、开户行不参与。
    func testSaveComparesTokenSummaryWithBody() throws {
        let fake = DebugFakeWallet()
        UserDefaults.standard.set("step_up=always", forKey: Self.walletKey)
        let token = try payoutToken(fake)
        let other: [String: Any] = [
            "payout_method": "alipay",
            "alipay_logon_id": "lisi@example.com",
            "payee_name": "测试三",
        ]
        XCTAssertEqual(code(save(fake, other, key: "K-other", token: token)), 10003, "摘要对不上 → 10003")
        XCTAssertTrue(fake.validTokens.contains(token), "对不上不核销")
        XCTAssertNil(fake.payout, "对不上不改收款账号")

        let same: [String: Any] = [
            "payout_method": "alipay", "alipay_logon_id": " zhangsan@example.com ", "payee_name": "测试四",
        ]
        XCTAssertEqual(code(save(fake, same, key: "K-same", token: token)), 0, "摘要对得上 → 成功")
        XCTAssertFalse(fake.validTokens.contains(token), "step_up=always：成功即核销")

        let card = try payoutToken(fake, summary: ["payout_method": "bank_card", "card_no": "6222 0000 0000 0009"])
        let bankBody: [String: Any] = [
            "payout_method": "bank_card", "card_no": "6222-0000-0000-0009", "bank_name": "测试银行", "payee_name": "测试三",
        ]
        XCTAssertEqual(code(save(fake, bankBody, key: "K-bank", token: card)), 0, "卡号只比数字")
    }

    /// 提现令牌（不带摘要签发、action 不同）不能用于改收款；提现提交不比对摘要（同一张提现令牌照常通过）。
    func testSaveRejectsTokenWithoutClaimAndWithdrawSkipsClaim() throws {
        let fake = DebugFakeWallet()
        let withdrawReply = stepUp(fake, ["action": "withdraw", "code": "123456"])
        let withdrawToken = try XCTUnwrap(data(withdrawReply)["step_up_token"] as? String)
        let body: [String: Any] = [
            "payout_method": "alipay",
            "alipay_logon_id": "zhangsan@example.com",
            "payee_name": "测试三",
        ]
        XCTAssertEqual(code(save(fake, body, key: "K-w", token: withdrawToken)), 10003, "提现令牌不能改收款")
        let posted = fake.answer(method: "POST", path: "/v1/withdrawals", query: [:], body: ["amount_fen": 1000],
                                 headers: ["Idempotency-Key": "K-post", "X-Step-Up-Token": withdrawToken])
        XCTAssertEqual(code(posted), 0, "提现提交不比对摘要")
    }

    // MARK: - 假 Me

    /// masked_phone：已绑 138****5678；没绑为 null（钱包假服务与「我的」假服务两处 GET /v1/me 同口径）。
    func testFakeMeMaskedPhone() {
        let wallet = DebugFakeWallet()
        let me = DebugFakeMe()
        let walletMe = { self.data(wallet.answer(method: "GET", path: "/v1/me", query: [:], body: [:], headers: [:])) }
        let meMe = { () -> [String: Any] in
            let text = me.answer(method: "GET", path: "/v1/me", body: [:])?.data ?? ""
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
        }
        for object in [walletMe(), meMe()] {
            XCTAssertEqual(object["phone_bound"] as? Bool, true)
            XCTAssertEqual(object["masked_phone"] as? String, "138****5678")
        }
        setBound(false)
        for object in [walletMe(), meMe()] {
            XCTAssertEqual(object["phone_bound"] as? Bool, false)
            XCTAssertTrue(object["masked_phone"] is NSNull, "没绑：masked_phone 为 null")
        }
    }
}
