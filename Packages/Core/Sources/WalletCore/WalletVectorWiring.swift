import CouliNetwork
import Foundation

// 三端向量（specs/wallet-vectors.json）的 JSON 接线：判定都在强类型的入口里，这里只把 JSON 转成强类型、把结论转回 JSON，不做业务判定。
// 坏数据（向量不含）一律按「接线错误」返回空对象，由测试判失败。

typealias WireObject = [String: Any]

private func nullable(_ value: Any?) -> Any {
    value ?? NSNull()
}

private func amountJSON(_ amount: MaskableAmount?) -> Any {
    guard let amount else { return NSNull() }
    var out: WireObject = ["fen": amount.fen]
    if let masked = amount.maskedText {
        out["maskedText"] = masked
    }
    return out
}

private func lineJSON(_ line: TextLine) -> WireObject {
    var values: WireObject = [:]
    for (key, value) in line.strings {
        values[key] = value
    }
    for (key, value) in line.amounts {
        values[key] = value
    }
    return values.isEmpty ? ["key": line.key] : ["key": line.key, "values": values]
}

public extension WalletSummaryView {
    static func of(summary: [String: Any], masked: Bool, nowMs: Int64) -> [String: Any] {
        guard let parsed = WalletJSON.summary(summary) else { return [:] }
        let view = of(parsed, masked: masked, nowMs: nowMs)
        let banner: WireObject = view.riskBanner.show
            ? ["show": true, "textKey": nullable(view.riskBanner.textKey)] : ["show": false]
        var button: WireObject = ["enabled": view.withdrawEnabled]
        if let reason = view.withdrawReasonKey {
            button["reasonKey"] = reason
        }
        return [
            "hero": amountJSON(view.hero), "negativeLine": amountJSON(view.negativeLine),
            "frozen": amountJSON(view.frozen), "withdrawn": amountJSON(view.withdrawn),
            "estimated": amountJSON(view.estimated), "receivedLine": amountJSON(view.receivedLine),
            "earliestMonth": view.earliestMonth.map { ["monthText": $0] as Any } ?? NSNull(),
            "overdueNote": view.overdueNote, "pausedLine": amountJSON(view.pausedLine), "riskBanner": banner,
            "withdrawButton": button,
        ]
    }
}

public extension WithdrawAmountInput {
    static func parse(text: String) -> Int64? {
        parse(text)
    }

    static func display(fen: Int64) -> String {
        display(fen)
    }
}

public extension WithdrawRulesView {
    static func of(rules: [String: Any], inputFen: Int64?, slaText: String?) -> [String: Any] {
        guard let parsed = WalletJSON.rules(rules) else { return [:] }
        let view = of(parsed, inputFen: inputFen, slaText: slaText)
        let estimate: Any = switch view.estimate {
        case .hidden: "hidden"
        case let .netOnly(net): ["key": estimateNetOnlyKey, "net": net] as WireObject
        case let .full(net, fee, tax): ["key": estimateKey, "net": net, "fee": fee, "tax": tax] as WireObject
        }
        var all: WireObject = ["enabled": view.allEnabled]
        if let fen = view.allFen {
            all["fen"] = fen
        }
        return [
            "balanceLine": ["fen": view.balanceFen],
            "remaining": ["daily": view.dailyRemaining, "monthly": view.monthlyRemaining],
            "maxLine": view.maxLineFen.map { ["fen": $0] as Any } ?? NSNull(), "allButton": all, "quick": view.quick,
            "estimate": estimate, "slaKeyOrText": view.slaText, "submitEnabled": view.submitEnabled,
            "amountEditable": view.amountEditable,
        ]
    }
}

public extension WithdrawEstimateGate {
    static func shouldApply(request: [String: Any], current: [String: Any]) -> Bool {
        shouldApply(
            Request(
                account: request["account"] as? String, pageInstance: request["pageInstance"] as? String ?? "",
                seq: WalletJSON.int64(request["seq"]) ?? -1, amountFen: WalletJSON.int64(request["amountFen"])
            ),
            Current(
                account: current["account"] as? String, pageInstance: current["pageInstance"] as? String ?? "",
                latestSeq: WalletJSON.int64(current["latestSeq"]) ?? -1, inputFen: WalletJSON.int64(current["inputFen"])
            )
        )
    }
}

public extension WithdrawBlockGuide {
    static func of(blockCode: Int?, blockReason: String?) -> [String: Any] {
        let view = view(blockCode: blockCode, blockReason: blockReason)
        var out: WireObject = ["actionRaw": view.actionRaw, "textKey": view.textKey]
        if let route = view.route {
            out["route"] = route
        }
        if let fallback = view.fallbackUsed {
            out["fallbackUsed"] = fallback
        }
        return out
    }
}

public extension WithdrawConditionText {
    static func of(reason: String?) -> [String: Any] {
        let view = view(reason)
        return ["textKey": view.textKey, "useFallback": view.useFallback]
    }
}

public extension SensitiveOutcome {
    static func of(op: String, phase: String, keyEverUnknown: Bool, result: [String: Any]) -> [String: Any] {
        let code = (WalletJSON.int64(result["code"])).flatMap { Int(exactly: $0) }
        let data = result["data"] as? [String: Any] ?? [:]
        var strings: [String: String] = [:]
        for (key, value) in data {
            if let text = value as? String {
                strings[key] = text
            }
        }
        let headers = (result["headers"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        var input = OutcomeInput(
            result["kind"] as? String ?? OutcomeInput.transportKind, code: code, data: strings,
            fields: (data["fields"] as? [Any])?.compactMap { $0 as? String } ?? [],
            retryAfterMillis: code == 42901 ? ErrorActionMapper.retryAfterMillis(headers) : nil
        )
        input.abandonOutcome = result["outcome"] as? String
        input.originalCode = ((result["original"] as? [String: Any])?["code"]).flatMap(WalletJSON.int64)
            .flatMap { Int(exactly: $0) }
        let out = of(op: op, phase: phase, keyEverUnknown: keyEverUnknown, input: input)
        var json: WireObject = [
            "actionRaw": out.actionRaw, "keyEnds": out.keyEnds, "nextSubmitNewKey": out.nextSubmitNewKey,
        ]
        json["textKey"] = out.textKey
        json["route"] = out.route
        json["disableMs"] = out.disableMillis
        if out.showTrace6 {
            json["showTrace6"] = true
        }
        return json
    }
}

public extension WithdrawalText {
    static func of(item: [String: Any], slaText: String?) -> [String: Any] {
        guard let parsed = WalletJSON.withdrawal(item) else { return [:] }
        let view = of(parsed, slaText: slaText)
        return [
            "titleKey": view.titleKey, "subLines": view.subLines.map(lineJSON),
            "showChangeAccount": view.showChangeAccount, "netKey": nullable(view.netKey),
        ]
    }
}

public extension TradeNoRow {
    static func of(detail: [String: Any]) -> [String: Any] {
        let text = copyText(
            status: detail["status"] as? String ?? "",
            channelOrderId: detail["channel_order_id"] as? String
        )
        return text.map { ["show": true, "copyText": $0] } ?? ["show": false]
    }
}

public extension PayoutAccountView {
    static func of(data: [String: Any]) -> [String: Any] {
        guard let parsed = WalletJSON.payoutAccount(data) else { return [:] }
        let view = view(parsed)
        guard view.bound else { return ["bound": false] }
        return [
            "bound": true, "methodRaw": nullable(view.methodRaw), "maskedAccount": nullable(view.maskedAccount),
            "bankName": nullable(view.bankName), "maskedPayee": nullable(view.maskedPayee),
            "changeRemaining": nullable(view.changeRemaining),
        ]
    }
}

private func formOf(_ object: [String: Any]) -> PayoutForm {
    PayoutForm(
        method: object[PayoutAccountForm.payoutMethod] as? String ?? WalletJSON.alipay,
        alipayLogonId: object[PayoutAccountForm.alipayLogonId] as? String ?? "",
        cardNo: object[PayoutAccountForm.cardNo] as? String ?? "",
        bankName: object[PayoutAccountForm.bankName] as? String ?? "",
        payeeName: object[PayoutAccountForm.payeeName] as? String ?? ""
    )
}

public extension PayoutPendingSummary {
    static func of(form: [String: Any]) -> [String: Any] {
        let view = summarize(formOf(form))
        return ["account": nullable(view.account), "payee": nullable(view.payee)]
    }
}

public extension PayoutAccountForm {
    static func body(form: [String: Any]) -> [String: Any] {
        let result = build(formOf(form))
        return ["body": nullable(result.body), "fieldErrors": result.fieldErrors]
    }
}

public extension RealNameForm {
    static func normalize(input: [String: Any]) -> [String: Any] {
        let view = normalize(name: input["name"] as? String ?? "", idNo: input["idNo"] as? String ?? "")
        return ["name": view.name, "idNo": view.idNo, "submitEnabled": view.submitEnabled]
    }
}

public extension FundRouteParams {
    static func filter(route: String, params: [String: Any]) -> [String: Any] {
        let view = filtered(route: route, paramCount: params.count)
        return ["openedParams": view.keepsParams ? params : [:], "dropped": view.dropped, "event": nullable(view.event)]
    }
}
