/*
 实现前测试；只读输出，未编译运行。

 接线约定：
 - @testable import MeCore；MeCoreTests 另依赖仓库已有 DesignSystem。
 - JSON 边界使用 [String: Any]，数组使用 [[String: Any]]，空值使用
   NSNull/nil。生产强类型模型可提供同名 JSON 重载，只转换数据，不重写判定。
 - MeJson.parse(json:) -> JSONObject?；成功结果保留契约的 13 个 snake_case
   字段及嵌套形状。MeView 接受该模型的 JSON 边界表示。
 - 以下返回 JSONObject，参数标签与本文件调用一致：
   MeView.of(level:me:masked:availableRoutes:earningsFlag:)
   SettingsItems.of(level:platform:phoneBound:nicknameEditable:
                    serviceSwitchAvailable:deleteAccountAvailable:)
   PrivacyCenterView.of(level:platform:permissionEntries:permissionStatus:)
   NicknameInput.check(current:input:)；NicknameOutcome.of(result:)
   RiskNoticeView.of(risk:enteredBy10006:latestAccountAppeal:nowMs:)
   AppealView.of(appeals:frozenLayout:)；AppealForm.check(content:)
   AppealOutcome.of(result:)；CsEntryDecision.of(kfUrl:wechat:openResult:)
   AboutView.of(filingText:)；PrivacyWithdrawFlow.after(result:)。
 - NotifyGuideBar.visible(loggedIn:systemStatus:lastDeniedMs:lastClosedMs:nowMs:)
   -> Bool；RiskReasonText.key(category:) -> String?。
 - Personalization.consentBody(on:legalPrivacyVersion:nowMs:level:)
   -> JSONObject?；Personalization.header(on:level:) -> String?。
 - PrivacyWithdrawFlow.request(deviceRegistered:consentedVersion:nowMs:)
   -> JSONObject?；PendingWithdrawals.filter(items:) -> [String]。
 - PushReportPolicy()；on(event:state:) -> JSONObject；
   inFlight/pending 为 Bool。state 是补丁；响应的 session 是原请求世代，
   不得作为当前会话补丁。终止后的实例不复用。
 - CsLink.build(kfUrl:fromRoute:account:) -> String；
   Diagnostics.lines(fields:) -> [String]；
   Route10006.decide(topRoute:forceUpdateShowing:) -> String；
   MeLocalData.clearsOn(event:item:) -> Bool。
 - nowMs 为 Int64，来自显式 +08:00 夹具；client_at 比较同一时刻，
   不额外限定等价 ISO8601 的序列化形式。昵称用 Swift String.count。
 - 金额渲染复用 CouliFormat.money；本文件只断言分值和隐藏串；
   非空恢复时间直接与 CouliFormat.timeListFuture 比较。
 - 缺失期望字段不判定，显式 null 要求无值。数组长度必须一致；
   permissionRows 按 type 比较集合，其余业务数组比较顺序。
 - params/request/consentBody、宫格、设置分组、余额结构精确比较。
   申诉请求固定只含 target_type/content；未定的 content 值不比较。
 - settings 的 choices、服务开关能力标记及其他 DTO 标识见 vectors.gaps，
   不是新增路由、请求字段或用户文案键。openUrl 是按钮可打开的目标，
   此纯函数测试不执行外跳。
 - diagnostics.lines 使用值标记和无序行匹配，不断言英文字段名或分隔符。
 - 每端执行全部平台行。无网络、SDK、权限申请、文件写入或真实账号操作。
   失败信息只含用例名和字段路径，不打印输入、令牌或诊断原文。
 - 本文件不替代 vectors.gaps 所列页面、执行层及 Release 制品验收。
 */

import Foundation
import XCTest
import DesignSystem
@testable import MeCore

private typealias JSONObject = [String: Any]

final class MeVectorTests: XCTestCase {
    private let groups = [
        "meParse", "meView", "guideBar", "settingsItems", "privacyCenter",
        "personalization", "privacyWithdraw", "nickname", "nicknameOutcome",
        "riskNotice", "riskReason", "appealView", "appealSubmit", "appealOutcome",
        "pendingWithdrawals", "pushReport", "csEntry", "csLink", "diagnostics",
        "about", "route10006", "localDataClear"
    ]

    func testMeVectors() throws {
        let root = try repositoryRoot()
        let vectors = try read(root, "specs/me-vectors.json")
        let permissions = try rows(
            read(root, "contracts/snapshot/specs/system-permissions.json"),
            "permissions"
        )
        let routeFile = try read(root, "contracts/snapshot/contracts/routes.json")
        let routes = try object(routeFile["routes"], "routes")

        XCTAssertTrue(try integer(vectors, "version") == 1, "manifest.version")
        XCTAssertTrue(try array(vectors["sources"], "sources").count > 0, "sources")
        XCTAssertTrue(try array(vectors["gaps"], "gaps").count > 0, "gaps")
        XCTAssertTrue(
            Set(vectors.keys) == Set(groups + ["version", "sources", "gaps"]),
            "manifest.groups"
        )

        for group in groups {
            let cases = try rows(vectors, group)
            XCTAssertFalse(cases.isEmpty, "\(group).empty")
            let names = try cases.map { try string($0, "name") }
            XCTAssertTrue(Set(names).count == names.count, "\(group).duplicate")

            for row in cases {
                let label = "\(group)/\(try string(row, "name"))"
                try XCTContext.runActivity(named: label) { _ in
                    if group == "pushReport" {
                        try runPush(row, label)
                    } else if group == "diagnostics" {
                        try runDiagnostics(row, label)
                    } else {
                        let expected = try object(row["expect"], label)
                        let actual = try evaluate(group, row, permissions, label)
                        try match(actual, expected, label)
                        try checkRoutes(actual, routes, label)

                        if group == "meView" {
                            XCTAssertTrue(
                                Set(actual.keys).isSubset(of: Set([
                                    "loginPrompt", "inviteCodeBlock", "inviterTextKey",
                                    "balance", "bell", "grid"
                                ])),
                                "\(label).noExtraProfileOrLevel"
                            )
                        }
                        if group == "appealSubmit",
                           try boolean(expected, "enabled") {
                            let body = try object(actual["body"], label + ".body")
                            XCTAssertTrue(
                                Set(body.keys) == Set(["target_type", "content"]),
                                "\(label).body.keys"
                            )
                            XCTAssertTrue(body["content"] is String, "\(label).body.content.type")
                        }
                        if group == "nickname" {
                            let trimmed = try string(actual, "trimmed")
                            XCTAssertTrue(
                                trimmed.count == (try integer(expected, "length")),
                                "\(label).swiftGraphemeCount"
                            )
                        }
                        if group == "riskNotice" {
                            let risk = try object(row["risk"], label)
                            if let until = risk["frozen_until"] as? String,
                               try string(expected, "layoutRaw").hasPrefix("frozen") {
                                let formatted = CouliFormat.timeListFuture(
                                    epochMillis: try milliseconds(until),
                                    nowEpochMillis: try now(row)
                                )
                                try match(
                                    actual["frozenUntilText"], formatted,
                                    label + ".frozenUntilText"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func evaluate(
        _ group: String, _ r: JSONObject, _ permissions: [JSONObject], _ label: String
    ) throws -> JSONObject {
        switch group {
        case "meParse":
            let wire = try object(r["json"], label)
            guard let me = MeJson.parse(json: wire) else { return ["ok": false] }
            try match(me, wire, label + ".allFields", exact: true)
            let balance = try object(me["balance"], label)
            let risk = try object(me["risk"], label)
            return [
                "ok": true, "nickname": me["nickname"] ?? NSNull(),
                "inviteCode": me["invite_code"] ?? NSNull(),
                "inviterBound": me["inviter_bound"] ?? NSNull(),
                "withdrawableFen": balance["withdrawable_fen"] ?? NSNull(),
                "estimatedTotalFen": balance["estimated_total_fen"] ?? NSNull(),
                "riskStateRaw": risk["state"] ?? NSNull(),
                "reasonCategory": risk["reason_category"] ?? NSNull(),
                "frozenUntil": risk["frozen_until"] ?? NSNull()
            ]
        case "meView":
            var me: JSONObject?
            if let wire = r["me"] as? JSONObject {
                me = try XCTUnwrap(MeJson.parse(json: wire), "\(label).validMe")
            }
            return MeView.of(
                level: try string(r, "levelRaw"), me: me,
                masked: try boolean(r, "masked"),
                availableRoutes: try strings(r, "availableRoutes"),
                earningsFlag: r["earningsFlag"] as? Bool
            )
        case "guideBar":
            return ["show": NotifyGuideBar.visible(
                loggedIn: try boolean(r, "loggedIn"),
                systemStatus: try string(r, "systemRaw"),
                lastDeniedMs: try optionalMilliseconds(r["lastDeniedIso"]),
                lastClosedMs: try optionalMilliseconds(r["lastClosedIso"]),
                nowMs: try now(r)
            )]
        case "settingsItems":
            return SettingsItems.of(
                level: try string(r, "levelRaw"),
                platform: try string(r, "platformRaw"),
                phoneBound: r["phoneBound"] as? Bool,
                nicknameEditable: try boolean(r, "nicknameEditable"),
                serviceSwitchAvailable: try boolean(r, "serviceSwitchAvailable"),
                deleteAccountAvailable: try boolean(r, "deleteAccountAvailable")
            )
        case "privacyCenter":
            return PrivacyCenterView.of(
                level: try string(r, "levelRaw"),
                platform: try string(r, "platformRaw"),
                permissionEntries: permissions,
                permissionStatus: try object(r["permissionStatus"], label)
            )
        case "personalization":
            let on = try boolean(r, "on")
            let level = try string(r, "levelRaw")
            return [
                "consentBody": Personalization.consentBody(
                    on: on, legalPrivacyVersion: try integer(r, "legalPrivacyVersion"),
                    nowMs: try now(r), level: level
                ) as Any? ?? NSNull(),
                "header": Personalization.header(on: on, level: level) as Any? ?? NSNull()
            ]
        case "privacyWithdraw":
            var result = PrivacyWithdrawFlow.after(result: try object(r["result"], label))
            result["request"] = PrivacyWithdrawFlow.request(
                deviceRegistered: try boolean(r, "deviceRegistered"),
                consentedVersion: try integer(r, "consentedVersion"),
                nowMs: try now(r)
            ) as Any? ?? NSNull()
            return result
        case "nickname":
            return NicknameInput.check(
                current: try string(r, "current"), input: try string(r, "input")
            )
        case "nicknameOutcome":
            return NicknameOutcome.of(result: try object(r["result"], label))
        case "riskNotice":
            return RiskNoticeView.of(
                risk: try object(r["risk"], label),
                enteredBy10006: try boolean(r, "enteredBy10006"),
                latestAccountAppeal: r["latestAccountAppeal"] as? JSONObject,
                nowMs: try now(r)
            )
        case "riskReason":
            return ["key": RiskReasonText.key(
                category: r["category"] as? String
            ) as Any? ?? NSNull()]
        case "appealView":
            return AppealView.of(
                appeals: try rows(r, "appeals"),
                frozenLayout: try boolean(r, "frozenLayout")
            )
        case "appealSubmit":
            return AppealForm.check(content: try string(r, "content"))
        case "appealOutcome":
            return AppealOutcome.of(result: try object(r["result"], label))
        case "pendingWithdrawals":
            return ["shownIds": PendingWithdrawals.filter(items: try rows(r, "items"))]
        case "csEntry":
            return CsEntryDecision.of(
                kfUrl: r["kfUrl"] as? String, wechat: try string(r, "wechatRaw"),
                openResult: r["openResult"] as? String
            )
        case "csLink":
            return ["url": CsLink.build(
                kfUrl: try string(r, "kfUrl"), fromRoute: try string(r, "fromRoute"),
                account: try object(r["account"], label)
            )]
        case "about":
            return AboutView.of(filingText: r["filingText"] as? String)
        case "route10006":
            return ["actionRaw": Route10006.decide(
                topRoute: try string(r, "topRoute"),
                forceUpdateShowing: try boolean(r, "forceUpdateShowing")
            )]
        case "localDataClear":
            return ["clear": MeLocalData.clearsOn(
                event: try string(r, "event"), item: try string(r, "item")
            )]
        default:
            throw failure(label + ".unhandledGroup")
        }
    }

    private func runPush(_ row: JSONObject, _ label: String) throws {
        var policy = PushReportPolicy()
        let steps = try rows(row, "steps")
        XCTAssertFalse(steps.isEmpty, label + ".steps")
        for (index, step) in steps.enumerated() {
            var actual = policy.on(
                event: try string(step, "event"),
                state: step["state"] as? JSONObject ?? [:]
            )
            actual["inFlight"] = policy.inFlight
            actual["pending"] = policy.pending
            try match(actual, try object(step["expect"], label), "\(label)[\(index)]")
        }
    }

    private func runDiagnostics(_ row: JSONObject, _ label: String) throws {
        let actual = Diagnostics.lines(fields: try object(row["fields"], label))
        let expected = try object(row["expect"], label)
        let markers = try strings(expected, "lines")
        XCTAssertTrue(actual.count == markers.count, label + ".lineCount")
        XCTAssertTrue(
            actual.allSatisfy { !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") },
            label + ".oneItemPerLine"
        )
        var used = Set<Int>()
        for (index, marker) in markers.enumerated() {
            let pieces = marker.components(separatedBy: "|")
            let found = actual.indices.first { line in
                !used.contains(line) &&
                pieces.allSatisfy { piece in actual[line].contains(piece) }
            }
            XCTAssertNotNil(found, "\(label).valueGroup[\(index)]")
            if let found { used.insert(found) }
        }
        let joined = actual.joined(separator: "\n")
        for (index, forbidden) in try strings(expected, "forbiddenAbsent").enumerated() {
            XCTAssertFalse(joined.contains(forbidden), "\(label).forbidden[\(index)]")
        }
    }

    private func match(
        _ actual: Any?, _ expected: Any, _ path: String, exact: Bool = false
    ) throws {
        if expected is NSNull {
            XCTAssertTrue(actual == nil || actual is NSNull, path + ".null")
            return
        }
        if let e = expected as? JSONObject {
            let a = try object(actual, path)
            if exact {
                XCTAssertTrue(Set(a.keys) == Set(e.keys), path + ".keys")
            }
            let exactChildren: Set<String> = [
                "request", "consentBody", "params", "grid", "groups",
                "balance", "bell", "inviteCodeBlock", "permissionRows"
            ]
            for key in e.keys.sorted() {
                try match(
                    a[key], e[key]!, path + "." + key,
                    exact: exact || exactChildren.contains(key)
                )
            }
            return
        }
        if var e = expected as? [Any] {
            var a = try array(actual, path)
            if path.hasSuffix(".permissionRows") {
                a = try a.sorted { try string(object($0, path), "type") <
                    string(object($1, path), "type") }
                e = try e.sorted { try string(object($0, path), "type") <
                    string(object($1, path), "type") }
            }
            XCTAssertTrue(a.count == e.count, path + ".count")
            guard a.count == e.count else { return }
            for index in e.indices {
                try match(a[index], e[index], "\(path)[\(index)]", exact: exact)
            }
            return
        }
        if path.hasSuffix(".client_at"),
           let a = actual as? String, let e = expected as? String {
            XCTAssertTrue(
                try milliseconds(a) == milliseconds(e), path + ".instant"
            )
            return
        }
        guard let actual else { XCTFail(path + ".missing"); return }
        let a = try JSONSerialization.data(withJSONObject: [actual], options: [.sortedKeys])
        let e = try JSONSerialization.data(withJSONObject: [expected], options: [.sortedKeys])
        XCTAssertTrue(a == e, path + ".value")
    }

    private func checkRoutes(_ value: Any, _ routes: JSONObject, _ path: String) throws {
        if let object = value as? JSONObject {
            for (key, child) in object {
                if (key == "route" || key == "withdrawRoute"), let route = child as? String {
                    XCTAssertNotNil(routes[route], path + "." + key + ".registered")
                }
                try checkRoutes(child, routes, path + "." + key)
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                try checkRoutes(child, routes, "\(path)[\(index)]")
            }
        }
    }

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("contract.lock").path
            ) { return directory }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { throw failure("找不到 contract.lock") }
            directory = parent
        }
    }

    private func read(_ root: URL, _ relative: String) throws -> JSONObject {
        try object(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent(relative))
            ),
            relative
        )
    }

    private func failure(_ path: String) -> NSError {
        NSError(domain: "MeVectorTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: path])
    }

    private func object(_ value: Any?, _ path: String) throws -> JSONObject {
        guard let value = value as? JSONObject else { throw failure(path + ".object") }
        return value
    }

    private func array(_ value: Any?, _ path: String) throws -> [Any] {
        guard let value = value as? [Any] else { throw failure(path + ".array") }
        return value
    }

    private func rows(_ object: JSONObject, _ key: String) throws -> [JSONObject] {
        try array(object[key], key).map { try self.object($0, key) }
    }

    private func strings(_ object: JSONObject, _ key: String) throws -> [String] {
        guard let value = object[key] as? [String] else { throw failure(key + ".strings") }
        return value
    }

    private func string(_ object: JSONObject, _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw failure(key + ".string") }
        return value
    }

    private func boolean(_ object: JSONObject, _ key: String) throws -> Bool {
        guard let value = object[key] as? Bool else { throw failure(key + ".bool") }
        return value
    }

    private func integer(_ object: JSONObject, _ key: String) throws -> Int {
        guard let value = object[key] as? Int else { throw failure(key + ".int") }
        return value
    }

    private func milliseconds(_ iso: String) throws -> Int64 {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) {
            return Int64((date.timeIntervalSince1970 * 1_000).rounded())
        }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else { throw failure("非法 ISO 时刻") }
        return Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private func optionalMilliseconds(_ value: Any?) throws -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        guard let iso = value as? String else { throw failure("时间字段类型") }
        return try milliseconds(iso)
    }

    private func now(_ row: JSONObject) throws -> Int64 {
        let iso = try string(row, "nowIso")
        guard iso.hasSuffix("+08:00") else { throw failure("nowIso 时区") }
        return try milliseconds(iso)
    }
}
