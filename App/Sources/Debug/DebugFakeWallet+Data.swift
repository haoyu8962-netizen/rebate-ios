#if DEBUG
import CouliNetwork
import Foundation
import WalletCore

/// 钱包摘要、rules、提现单与收款账号的样例（照 sample-data §12，与 Android 同一份）。调用方持有 `lock`。
extension DebugFakeWallet {
    func summary(_ scene: String?) -> [String: Any] {
        var base: [String: Any] = [
            "available_fen": 1234, "withdrawable_fen": 1234, "negative_fen": 0, "frozen_fen": 0,
            "estimated_total_fen": 5678, "estimated_fen": 2222, "pending_credit_fen": 3456,
            "pending_credit_paused_fen": 456, "next_credit_period": "2026-10", "credit_overdue": false,
            "withdrawn_fen": 500, "risk_paused_reason": NSNull(), "withdraw_enabled": true,
        ]
        switch scene {
        case "frozen":
            base["available_fen"] = 234
            base["withdrawable_fen"] = 234
            base["frozen_fen"] = 1000
            base["pending_credit_paused_fen"] = 0
        case "negative":
            base["available_fen"] = -567
            base["withdrawable_fen"] = 0
            base["negative_fen"] = 567
            base["pending_credit_paused_fen"] = 0
        case "risk":
            base["risk_paused_reason"] = "abnormal_trade"
        case "disabled":
            base["withdraw_enabled"] = false
        case "new":
            for key in ["available_fen", "withdrawable_fen", "estimated_total_fen", "estimated_fen",
                        "pending_credit_fen", "pending_credit_paused_fen", "withdrawn_fen"] {
                base[key] = 0
            }
            base["next_credit_period"] = NSNull()
        default:
            break
        }
        return base
    }

    func blockCode(_ state: [String: String]) -> Int? {
        if state["rules"] == "feature_off" {
            return 30306
        }
        if state["rules"] == "negative" {
            return 30302
        }
        // 风控冻结（G11 编排者更正）：钱包【提现】可点，rules 给 30303 account_frozen
        if state["wallet"] == "risk" {
            return 30303
        }
        if !realname(state) {
            return 30304
        }
        if payoutAccount(state) == nil {
            return 30305
        }
        if !labor(state) {
            return 10004
        }
        if state["rules"] == "below_min" {
            return 30303
        }
        return nil
    }

    func rules(_ state: [String: String], amount: Int64?) -> [String: Any] {
        let block = blockCode(state)
        let can = block == nil
        let est: Any = can ? (amount.map { $0 as Any } ?? NSNull()) : NSNull()
        let zero: Any = can && amount != nil ? 0 : NSNull()
        let reason: Any = block != 30303 ? NSNull() : (state["wallet"] == "risk" ? "account_frozen" : "below_min")
        return [
            "can_withdraw": can, "block_code": block.map { $0 as Any } ?? NSNull(), "block_reason": reason,
            "max_withdrawable_fen": can ? 1200 : 0,
            "withdrawable_fen": state["rules"] == "negative" ? 0 : 1234, "daily_remaining": 1,
            "monthly_remaining": 10, "est_fee_fen": zero, "est_tax_fen": zero, "est_net_fen": est,
            "quick_amounts_fen": can ? [500, 1000] : [],
        ]
    }

    /// 调用方持有 `lock`：建单与幂等结果在同一次持锁里一起保存（iOS R1-02）。
    func submit(_ state: [String: String], _ body: [String: Any], _ headers: [String: String]) -> Reply {
        guard let key = Self.header(headers, "Idempotency-Key") else { return fail(20001) }
        submitSeen = true
        if let done = results[key] {
            return .answer(code: done.code, data: done.data, headers: [:])
        }
        // confirm=20903：丢在路上的键再次发送时按「已作废」回 20903（确认得到 20903，iOS R2-02）
        if state["confirm"] == "20903", lostKeys.contains(key) {
            return fail(20903)
        }
        // 请求未到达（unknown_lost）：带有效 token 的提交在任何业务修改之前按传输失败结束——不建单、不记幂等结果、不核销 token
        if state["submit"] == "unknown_lost", tokenValid(headers, action: "withdraw") {
            lostKeys.insert(key)
            return .offline
        }
        guard stepUpPassed(headers, action: "withdraw", state) else { return fail(10003) }
        guard let amount = WalletJSON.int64(body["amount_fen"]) else { return fail(20001) }
        if state["submit"] == "busy" {
            return fail(42901, headers: ["Retry-After": "10"])
        }
        if state["submit"] == "5xxxx" {
            return fail(50001)
        }
        let outcome = state["outcome"].flatMap(Int.init).map { (code: $0, data: "null") }
            ?? submitOutcome(state["submit"], amount: amount)
        results[key] = outcome
        // 响应丢失（unknown_created）：业务结果与幂等结果已一起保存，之后才丢响应（确认返回原结果、作废返回 completed）
        if state["submit"] == "unknown_created" {
            return .offline
        }
        return .answer(code: outcome.code, data: outcome.data, headers: [:])
    }

    func submitOutcome(_ scene: String?, amount: Int64) -> (code: Int, data: String) {
        switch scene {
        case "44001": (44001, "{\"risk_msg_code\":\"fixture_unlisted_reason\"}")
        case "30303": (30303, "{\"reason\":\"daily_count\"}")
        default: (0, Self.json(withdrawal(amount)))
        }
    }

    func withdrawal(_ amount: Int64) -> [String: Any] {
        serial += 1
        let item = record("W20261012001\(serial)", "PENDING_REVIEW", "manual", amount, "2026-10-12T10:00:00+08:00")
        created.insert(item, at: 0)
        return item
    }

    func samples() -> [[String: Any]] {
        [
            record("W2026101200001", "PENDING_REVIEW", "manual", 1000, "2026-10-12T10:00:00+08:00"),
            record("W2026100800003", "FAILED", "manual", 800, "2026-10-08T11:30:00+08:00",
                   reason: "PAYEE_ACCOUNT_STATUS_ERROR", failAction: "change_payout_account"),
            record("W2026092700002", "PAID_API", "auto", 500, "2026-09-27T15:20:00+08:00",
                   channelOrderId: "20260928200040011100"),
            record("W2026092500001", "REJECTED", "manual", 600, "2026-09-25T10:00:00+08:00"),
        ]
    }

    func list(_ state: [String: String], _ query: [String: String]) -> Reply {
        var all = state["records"] == "empty" ? created : created + samples()
        if state["records"] == "empty_once" {
            // 第一次读取为空；之后每次多一张以读取序号命名的单（UI 用例据此确认空态下拉只发了一次请求，iOS R3-02）
            listCalls += 1
            let marker = record("W-call-\(listCalls)", "PENDING_REVIEW", "manual", 700, "2026-10-13T09:00:00+08:00")
            all = listCalls == 1 ? created : [marker] + created + samples()
        }
        let page = Int(query["cursor"]?.replacingOccurrences(of: "p", with: "") ?? "") ?? 0
        let size = 20
        let chunk = all.dropFirst(page * size).prefix(size).map { item -> [String: Any] in
            var copy = item
            copy["channel_order_id"] = nil
            return copy
        }
        let more = all.count > (page + 1) * size
        return ok(["items": Array(chunk), "next_cursor": more ? "p\(page + 1)" : NSNull()] as [String: Any])
    }

    func detail(_ id: String) -> Reply {
        guard let item = (created + samples()).first(where: { ($0["withdrawal_id"] as? String) == id }) else {
            return fail(30701)
        }
        return ok(item)
    }

    func record(_ id: String, _ status: String, _ mode: String?, _ amount: Int64, _ createdAt: String,
                reason: String? = nil, failAction: String? = nil, channelOrderId: String? = nil) -> [String: Any] {
        [
            "withdrawal_id": id, "status": status, "review_mode": mode.map { $0 as Any } ?? NSNull(),
            "amount_fen": amount, "fee_fen": 0, "tax_fen": 0, "net_fen": amount, "payout_channel": "alipay",
            "payout_channel_name": "支付宝", "masked_account": "138****5678",
            "reason_code": reason.map { $0 as Any } ?? NSNull(),
            "fail_action": failAction.map { $0 as Any } ?? NSNull(),
            "created_at": createdAt, "channel_order_id": channelOrderId.map { $0 as Any } ?? NSNull(),
        ]
    }
}
#endif
