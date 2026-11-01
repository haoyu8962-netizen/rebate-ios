#if DEBUG
import CouliNetwork
import Foundation
import Generated
import WalletCore

/// 收款账号、二次验证、作废，以及进程内的假实名与假劳务协议（G01、G02）。调用方持有 `lock`（后端类自己取锁）。
extension DebugFakeWallet {
    func payoutAccount(_ state: [String: String]) -> [String: Any]? {
        if !payoutInitialized {
            payoutInitialized = true
            switch state["payout"] {
            case "none": payout = nil
            case "bank": payout = bank("招商银行", tail: "1234")
            default: payout = alipay("138****5678")
            }
        }
        return payout
    }

    func alipay(_ masked: String) -> [String: Any] {
        [
            "payout_method": "alipay", "masked_account": masked, "masked_payee_name": "**三",
            "change_remaining_this_month": 2,
        ]
    }

    func bank(_ name: String, tail: String) -> [String: Any] {
        [
            "payout_method": "bank_card", "masked_account": "尾号 \(tail)", "bank_name": name,
            "masked_payee_name": "**三", "change_remaining_this_month": 2,
        ]
    }

    func save(_ state: [String: String], _ body: [String: Any], _ headers: [String: String]) -> Reply {
        guard let key = Self.header(headers, "Idempotency-Key") else { return fail(20001) }
        saveSeen = true
        if let done = results[key] {
            return .answer(code: done.code, data: done.data, headers: [:])
        }
        guard stepUpPassed(headers, action: "payout_account_change", state) else { return fail(10003) }
        let account: [String: Any]
        if body["payout_method"] as? String == WalletJSON.bankCard {
            let card = (body["card_no"] as? String ?? "").filter(\.isNumber)
            guard (12...19).contains(card.count) else { return fail(20001, data: "{\"fields\":[\"card_no\"]}") }
            account = bank(body["bank_name"] as? String ?? "", tail: String(card.suffix(4)))
        } else {
            account = alipay(maskLogon(body["alipay_logon_id"] as? String ?? ""))
        }
        let outcome: (code: Int, data: String) = DebugWalletVisual.payoutSaveError ?? {
            switch state["outcome"] ?? state["save"] {
            case "30307": (30307, "null")
            case "44001": (44001, "null")
            default: (0, Self.json(account))
            }
        }()
        if outcome.code == 0 {
            payout = account
        }
        results[key] = outcome
        return state["save"] == "unknown_created" ? .offline : .answer(
            code: outcome.code,
            data: outcome.data,
            headers: [:]
        )
    }

    func maskLogon(_ logon: String) -> String {
        if let at = logon.lastIndex(of: "@"), at > logon.startIndex {
            return String(logon[..<at].prefix(2)) + "***" + String(logon[at...])
        }
        let digits = logon.filter(\.isNumber)
        return digits.count >= 7 ? String(digits.prefix(3)) + "****" + String(digits.suffix(4)) : "***"
    }

    /// 带了本 action 的有效 token（只看，不核销）。
    func tokenValid(_ headers: [String: String], action: String) -> Bool {
        guard let token = Self.header(headers, "X-Step-Up-Token") else { return false }
        return validTokens.contains(token) && token.hasPrefix("fake-step-up-\(action)-")
    }

    func stepUpPassed(_ headers: [String: String], action: String, _ state: [String: String]) -> Bool {
        guard tokenValid(headers, action: action), let token = Self.header(headers, "X-Step-Up-Token") else {
            return false
        }
        // 一次性：step_up=always 时每次都要重新验证
        if state["step_up"] == "always" {
            validTokens.remove(token)
        }
        return true
    }

    func stepUp(_ body: [String: Any]) -> Reply {
        let action = body["action"] as? String ?? ""
        switch body["code"] as? String {
        case "123456":
            serial += 1
            let token = "fake-step-up-\(action)-\(serial)"
            validTokens.insert(token)
            return ok(["step_up_token": token, "expire_at": "2099-01-01T00:05:00+08:00"])
        case "200030":
            return fail(20003)
        default:
            return fail(20002)
        }
    }

    func abandon(_ state: [String: String], _ body: [String: Any]) -> Reply {
        guard let key = body["idempotency_key"] as? String else { return fail(20001) }
        if state["abandon"] == "busy" {
            return fail(40901)
        }
        guard let done = results[key] else {
            // 没有受理过：作废，之后同一个键回 20903
            results[key] = (20903, "null")
            return ok(["outcome": "abandoned", "original": NSNull()] as [String: Any])
        }
        let original = "{\"code\":\(done.code),\"msg\":\"\",\"data\":\(done.data)}"
        return .answer(code: 0, data: "{\"outcome\":\"completed\",\"original\":\(original)}", headers: [:])
    }

    static let laborVersion = "v1"
    /// 协议正文（法务定稿前的演示文本，设计稿 LaborAgreement 的占位说明）。
    static let laborText = "协议正文（待法务提供）\n法务定稿后，全文放在这里，可上下滚动阅读。\n"
        + (1...12).map { "第 \($0) 条　演示条款，用于检查长文滚动与读屏完整读到。" }.joined(separator: "\n")

    static func failure(_ code: Int, data: String = "{}") -> ApiResult {
        .failure(code: code, msg: "", data: Data(data.utf8), traceId: "fake-trace-\(code)00",
                 effect: ErrorEffect(code: code, kind: .toast), idempotencyKey: nil)
    }

    static func success(_ data: String) -> ApiResult {
        .success(data: Data(data.utf8), traceId: "fake-trace-wallet", idempotencyKey: nil)
    }
}

/// 假的实名提交：姓名非空 + 任意 18 位通过；身份证号末位 1 → 30406；末位 2 → 30410；末位 3 → 20001 fields=[id_no]（字段错误定位，
/// iOS R2-06）。不落盘、不打印。
final class FakeRealName: RealNameBackend, @unchecked Sendable {
    let fake: DebugFakeWallet

    init(fake: DebugFakeWallet) {
        self.fake = fake
    }

    func submit(name: String, idNo: String, idempotencyKey _: String, owner _: RequestOwnership?) async -> ApiResult {
        DebugWalletLog.backend(.realnameSubmit)
        try? await Task.sleep(nanoseconds: 300_000_000)
        if name.isEmpty {
            return DebugFakeWallet.failure(20001, data: "{\"fields\":[\"name\"]}")
        }
        if idNo.hasSuffix("1") {
            return DebugFakeWallet.failure(30406)
        }
        if idNo.hasSuffix("2") {
            return DebugFakeWallet.failure(30410)
        }
        if idNo.hasSuffix("3") {
            return DebugFakeWallet.failure(20001, data: "{\"fields\":[\"id_no\"]}")
        }
        fake.lock.withLock { fake.realnameVerified = true }
        return DebugFakeWallet.success("{\"realname_status\":\"verified\"}")
    }
}

/// 假的劳务协议：取协议给演示正文与它的 sha256；签署要求版本与 sha256 原样回传。
final class FakeLabor: LaborBackend, @unchecked Sendable {
    let fake: DebugFakeWallet

    init(fake: DebugFakeWallet) {
        self.fake = fake
    }

    func current(owner _: RequestOwnership?) async -> ApiResult {
        DebugWalletLog.backend(.laborCurrent)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let signed = fake.lock.withLock { fake.labor(fake.options) }
        let data: [String: Any] = [
            "version": DebugFakeWallet.laborVersion, "text": DebugFakeWallet.laborText,
            "text_sha256": DebugFakeWallet.sha256(DebugFakeWallet.laborText), "need_sign": !signed,
        ]
        return DebugFakeWallet.success(DebugFakeWallet.json(data))
    }

    func sign(version: String, textSha256: String, owner _: RequestOwnership?) async -> ApiResult {
        DebugWalletLog.backend(.laborSign)
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard version == DebugFakeWallet.laborVersion, textSha256 == DebugFakeWallet.sha256(DebugFakeWallet.laborText)
        else { return DebugFakeWallet.failure(20001) }
        fake.lock.withLock { fake.laborSigned = true }
        return DebugFakeWallet.success("{}")
    }
}
#endif
