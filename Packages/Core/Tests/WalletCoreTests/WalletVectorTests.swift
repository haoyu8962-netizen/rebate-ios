/*
 实现前测试；只读输出，未编译运行。

 接线约定：
 - @testable import WalletCore；生产逻辑提供下列同名纯函数。
 - JSON 对象边界使用 [String: Any]，数组为 [Any]；金额是 Int64 整数分，
   无值使用 NSNull（返回可选字段也可省略）。实现可用强类型模型，
   但须提供此 JSON 接线，不能在测试适配器中实现业务判断。
 - WalletSummaryView.of(summary:masked:nowMs:) -> JSONObject。
   可见金额节点提供 fen、maskedText: String?；隐藏时每个节点均为 "****"。
 - WithdrawAmountInput.parse(text:) -> Int64?；display(fen:) -> String。
 - WithdrawRulesView.of(rules:inputFen:slaText:) -> JSONObject。
 - WithdrawEstimateGate.shouldApply(request:current:) -> Bool。
 - WithdrawBlockGuide.of(blockCode:blockReason:) -> JSONObject。
 - WithdrawConditionText.of(reason:) -> JSONObject。
 - SensitiveOutcome.of(op:phase:keyEverUnknown:result:) -> JSONObject。
   result 是已解包的判定输入，不是 HTTP 外壳；kind=ok 可省略与判定无关的 data。
   op=payout_account 对应服务端 action=payout_account_change。
 - StepUpTokenCache()；put(action:account:token:expireAtMs:)；
   take(action:account:nowMs:) -> String?；onSuccess(action:)；
   onSessionChanged()；on10003(action:)。take 不核销服务端 token。
 - WithdrawalText.of(item:slaText:) -> JSONObject；
   TradeNoRow.of(detail:) -> JSONObject；
   PayoutAccountView.of(data:) -> JSONObject；
   PayoutPendingSummary.of(form:) -> JSONObject；
   PayoutAccountForm.body(form:) -> JSONObject，fieldErrors 为字段名数组；
   RealNameForm.normalize(input:) -> JSONObject。
 - EarningsEntry.visible(flag:routeSince:appVersion:) -> Bool。
 - WalletStaleCache.isCacheable(kind:) / clearsOn(event:) -> Bool。
 - FundRouteParams.filter(route:params:) -> JSONObject。
 - nowMs/expireAtMs 为 Int64 毫秒，来自明确带 +08:00 的夹具，不读系统时间。
 - expect 缺字段不判定；显式 null 要求无值；数组长度和顺序精确。
   body、openedParams、subLines.values 精确比对，禁止请求夹带其他字段。
 - draft 文案键及 values 的接线见 vectors.gaps；金额渲染复用 CouliFormat，
   不在测试中实现金额格式化、税费、余额、限制值或月份推算。
 - anyMaskedAmountShowsDigits 是测试观察值，不要求生产对象提供该字段。
   只检查金额展示串，不把原始 fen 和月份数字当成泄漏。
 - 不使用网络、密钥库、系统剪贴板或真实提现。失败信息只含用例名和字段路径，
   不把完整姓名、账号、身份证号或请求体打印进测试日志。
 - gaps 中的页面、网络和持久化验收不由本文件替代。
 */

import Foundation
import CoreFoundation
import XCTest
@testable import WalletCore

private typealias JSONObject = [String: Any]

final class WalletVectorTests: XCTestCase {
    private let groups = [
        "summaryView", "amountInput", "amountDisplay", "rulesView",
        "estimateGate", "blockGuide", "conditionText", "outcome",
        "stepUpToken", "withdrawalText", "tradeNo", "payoutView",
        "payoutPendingSummary", "payoutForm", "realNameForm",
        "earningsEntry", "walletCache", "walletCacheClear", "routeParams",
    ]

    func testManifest() throws {
        let root = try vectors()
        XCTAssertEqual(try integer(root, "version"), 1)
        XCTAssertFalse(try array(root, "sources").isEmpty)
        XCTAssertFalse(try array(root, "gaps").isEmpty)

        for group in groups {
            let rows = try objects(root, group)
            XCTAssertFalse(rows.isEmpty, group)
            var names = Set<String>()
            for row in rows {
                let name = try string(row, "name")
                XCTAssertFalse(name.isEmpty, group)
                XCTAssertTrue(names.insert(name).inserted, "\(group): 重复 name")
                XCTAssertFalse(try object(row, "expect").isEmpty, "\(group).\(name)")
            }
        }

        for row in try objects(root, "summaryView") {
            XCTAssertEqual(try object(row, "summary").count, 13, "WalletSummary 字段数")
        }
        for row in try objects(root, "rulesView") {
            XCTAssertEqual(try object(row, "rules").count, 11, "WithdrawRules 字段数")
        }
        for row in try objects(root, "withdrawalText") {
            XCTAssertEqual(try object(row, "item").count, 13, "WithdrawalSummary 字段数")
        }
    }

    func testSummaryView() throws { try run("summaryView") }
    func testAmountInput() throws { try run("amountInput") }
    func testAmountDisplay() throws { try run("amountDisplay") }
    func testRulesView() throws { try run("rulesView") }
    func testEstimateGate() throws { try run("estimateGate") }
    func testBlockGuide() throws { try run("blockGuide") }
    func testConditionText() throws { try run("conditionText") }
    func testOutcome() throws { try run("outcome") }
    func testStepUpToken() throws { try run("stepUpToken") }
    func testWithdrawalText() throws { try run("withdrawalText") }
    func testTradeNo() throws { try run("tradeNo") }
    func testPayoutView() throws { try run("payoutView") }
    func testPayoutPendingSummary() throws { try run("payoutPendingSummary") }
    func testPayoutForm() throws { try run("payoutForm") }
    func testRealNameForm() throws { try run("realNameForm") }
    func testEarningsEntry() throws { try run("earningsEntry") }
    func testWalletCache() throws { try run("walletCache") }
    func testWalletCacheClear() throws { try run("walletCacheClear") }
    func testRouteParams() throws { try run("routeParams") }

    private func run(_ group: String) throws {
        let rows = try objects(try vectors(), group)
        XCTAssertFalse(rows.isEmpty, group)
        for row in rows {
            let label = "\(group).\(try string(row, "name"))"
            do {
                let actual = try evaluate(group, row, label)
                try match(actual, try object(row, "expect"), label)
            } catch {
                // 不输出 error 的原始上下文，避免框架附带敏感输入。
                XCTFail("\(label): 接线、类型或断言失败")
            }
        }
    }

    private func evaluate(
        _ group: String,
        _ row: JSONObject,
        _ label: String
    ) throws -> JSONObject {
        switch group {
        case "summaryView":
            let masked = try boolean(row, "masked")
            let actual = WalletSummaryView.of(
                summary: try object(row, "summary"),
                masked: masked,
                nowMs: try milliseconds(row, "nowIso")
            )
            return try auditMask(actual, masked, label)

        case "amountInput":
            let fen = WithdrawAmountInput.parse(text: try string(row, "text"))
            return ["fen": fen.map { NSNumber(value: $0) } ?? NSNull()]

        case "amountDisplay":
            let fen = try integer(row, "fen")
            let text = WithdrawAmountInput.display(fen: fen)
            // round-trip 的期望仍来自夹具 fen，不由 display 生成期望。
            XCTAssertEqual(
                WithdrawAmountInput.parse(text: text), fen, "\(label).roundTrip"
            )
            return ["text": text]

        case "rulesView":
            return WithdrawRulesView.of(
                rules: try object(row, "rules"),
                inputFen: try nullableInteger(row, "inputFen"),
                slaText: try nullableString(row, "slaText")
            )

        case "estimateGate":
            return [
                "apply": WithdrawEstimateGate.shouldApply(
                    request: try object(row, "request"),
                    current: try object(row, "current")
                )
            ]

        case "blockGuide":
            return WithdrawBlockGuide.of(
                blockCode: try nullableInteger(row, "blockCode").map(Int.init),
                blockReason: try nullableString(row, "blockReason")
            )

        case "conditionText":
            return WithdrawConditionText.of(reason: try nullableString(row, "reason"))

        case "outcome":
            return SensitiveOutcome.of(
                op: try string(row, "op"),
                phase: try string(row, "phase"),
                keyEverUnknown: try boolean(row, "keyEverUnknown"),
                result: try object(row, "result")
            )

        case "stepUpToken":
            return try tokenResult(row, label)

        case "withdrawalText":
            return WithdrawalText.of(
                item: try object(row, "item"),
                slaText: try nullableString(row, "slaText")
            )

        case "tradeNo":
            return TradeNoRow.of(detail: try object(row, "detail"))

        case "payoutView":
            return PayoutAccountView.of(data: try object(row, "data"))

        case "payoutPendingSummary":
            return PayoutPendingSummary.of(form: try object(row, "form"))

        case "payoutForm":
            return PayoutAccountForm.body(form: try object(row, "form"))

        case "realNameForm":
            return RealNameForm.normalize(input: try object(row, "input"))

        case "earningsEntry":
            return [
                "show": EarningsEntry.visible(
                    flag: try nullableBoolean(row, "flag"),
                    routeSince: try nullableString(row, "routeSinceForThisPlatform"),
                    appVersion: try string(row, "appVersion")
                )
            ]

        case "walletCache":
            return [
                "cacheable": WalletStaleCache.isCacheable(kind: try string(row, "kind"))
            ]

        case "walletCacheClear":
            return [
                "clear": WalletStaleCache.clearsOn(event: try string(row, "event"))
            ]

        case "routeParams":
            return FundRouteParams.filter(
                route: try string(row, "route"),
                params: try object(row, "params")
            )

        default:
            throw invalid("未知组")
        }
    }

    private func tokenResult(_ row: JSONObject, _ label: String) throws -> JSONObject {
        let cache = StepUpTokenCache()
        let request = try object(row, "request")
        let action = try string(request, "action")
        let account = try string(request, "account")
        let now = try milliseconds(request, "nowIso")
        let token = "fixture-token"

        if let cached = try nullableObject(row, "cached") {
            cache.put(
                action: try string(cached, "action"),
                account: try string(cached, "account"),
                token: token,
                expireAtMs: try milliseconds(cached, "expireAtIso")
            )
        }

        if row["events"] != nil {
            for value in try array(row, "events") {
                guard let event = value as? String else { throw invalid("events") }
                switch event {
                case "success": cache.onSuccess(action: action)
                case "session_changed": cache.onSessionChanged()
                case "got_10003": cache.on10003(action: action)
                default: throw invalid("未知 token 事件")
                }
            }
        }

        let actual = cache.take(action: action, account: account, nowMs: now)
        if actual != nil {
            XCTAssertTrue(actual == token, "\(label).tokenIdentity")
            XCTAssertTrue(
                cache.take(action: action, account: account, nowMs: now) == token,
                "\(label).takeDoesNotConsume"
            )
        }
        return ["reuse": actual != nil]
    }

    private func auditMask(
        _ actual: JSONObject,
        _ masked: Bool,
        _ label: String
    ) throws -> JSONObject {
        var result = actual
        var hasDigits = false
        let amountNodes = [
            "hero", "negativeLine", "frozen", "withdrawn",
            "estimated", "receivedLine", "pausedLine",
        ]

        for key in amountNodes {
            guard let raw = actual[key], !(raw is NSNull) else { continue }
            guard let cell = raw as? JSONObject else { throw invalid(key) }
            if masked {
                let text = try string(cell, "maskedText")
                XCTAssertTrue(text == "****", "\(label).\(key).maskedText")
                hasDigits = hasDigits || text.range(
                    of: "[0-9０-９]", options: .regularExpression
                ) != nil
            }
        }
        result["anyMaskedAmountShowsDigits"] = hasDigits
        return result
    }

    private func match(
        _ actual: Any?,
        _ expected: Any,
        _ path: String,
        exact: Bool = false
    ) throws {
        if expected is NSNull {
            XCTAssertTrue(actual == nil || actual is NSNull, "\(path): 应无值")
            return
        }

        if let expectedObject = expected as? JSONObject {
            guard let actualObject = actual as? JSONObject else {
                XCTFail("\(path): 应为对象")
                return
            }
            if exact {
                XCTAssertTrue(
                    Set(actualObject.keys) == Set(expectedObject.keys),
                    "\(path): 字段集合"
                )
            }
            for key in expectedObject.keys.sorted() {
                let childExact = exact || ["body", "openedParams", "values"].contains(key)
                try match(
                    actualObject[key],
                    expectedObject[key]!,
                    "\(path).\(key)",
                    exact: childExact
                )
            }
            return
        }

        if let expectedArray = expected as? [Any] {
            guard let actualArray = actual as? [Any] else {
                XCTFail("\(path): 应为数组")
                return
            }
            XCTAssertEqual(actualArray.count, expectedArray.count, "\(path).length")
            guard actualArray.count == expectedArray.count else { return }
            for index in expectedArray.indices {
                try match(
                    actualArray[index], expectedArray[index],
                    "\(path)[\(index)]", exact: exact
                )
            }
            return
        }

        guard let actual else {
            XCTFail("\(path): 缺字段")
            return
        }
        // 序列化标量保留 boolean/number/string 类型，避免 NSNumber 宽松相等。
        XCTAssertTrue(
            try canonical(actual) == canonical(expected),
            "\(path): 值或类型不符"
        )
    }

    private func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .fragmentsAllowed]
        )
    }

    private func vectors() throws -> JSONObject {
        let url = try repositoryRoot().appendingPathComponent("specs/wallet-vectors.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let root = raw as? JSONObject else { throw invalid("manifest") }
        return root
    }

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().standardizedFileURL
        while true {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("contract.lock").path
            ) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                throw invalid("从 #filePath 向上找不到 contract.lock")
            }
            directory = parent
        }
    }

    private func object(_ row: JSONObject, _ key: String) throws -> JSONObject {
        guard let value = row[key] as? JSONObject else { throw invalid(key) }
        return value
    }

    private func nullableObject(_ row: JSONObject, _ key: String) throws -> JSONObject? {
        guard let value = row[key] else { throw invalid(key) }
        return value is NSNull ? nil : try object(row, key)
    }

    private func array(_ row: JSONObject, _ key: String) throws -> [Any] {
        guard let value = row[key] as? [Any] else { throw invalid(key) }
        return value
    }

    private func objects(_ row: JSONObject, _ key: String) throws -> [JSONObject] {
        try array(row, key).map {
            guard let value = $0 as? JSONObject else { throw invalid(key) }
            return value
        }
    }

    private func string(_ row: JSONObject, _ key: String) throws -> String {
        guard let value = row[key] as? String else { throw invalid(key) }
        return value
    }

    private func nullableString(_ row: JSONObject, _ key: String) throws -> String? {
        guard let value = row[key] else { throw invalid(key) }
        return value is NSNull ? nil : try string(row, key)
    }

    private func integer(_ row: JSONObject, _ key: String) throws -> Int64 {
        guard let number = row[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              abs(number.doubleValue) <= 9_007_199_254_740_991
        else { throw invalid(key) }
        return number.int64Value
    }

    private func nullableInteger(_ row: JSONObject, _ key: String) throws -> Int64? {
        guard let value = row[key] else { throw invalid(key) }
        return value is NSNull ? nil : try integer(row, key)
    }

    private func boolean(_ row: JSONObject, _ key: String) throws -> Bool {
        guard let number = row[key] as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { throw invalid(key) }
        return number.boolValue
    }

    private func nullableBoolean(_ row: JSONObject, _ key: String) throws -> Bool? {
        guard let value = row[key] else { throw invalid(key) }
        return value is NSNull ? nil : try boolean(row, key)
    }

    private func milliseconds(_ row: JSONObject, _ key: String) throws -> Int64 {
        let text = try string(row, key)
        guard text.hasSuffix("+08:00"),
              let date = ISO8601DateFormatter().date(from: text)
        else { throw invalid(key) }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private func invalid(_ field: String) -> NSError {
        NSError(
            domain: "WalletVectorTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "夹具或接线错误：\(field)"]
        )
    }
}
