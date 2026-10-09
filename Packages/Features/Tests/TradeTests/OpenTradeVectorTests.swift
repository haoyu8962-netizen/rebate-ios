/*
 实现前测试；只读交付，未编译运行。需注册 TradeTests target。

 接线约定：
 - @testable import Trade；直接调用以下生产纯逻辑，不在测试内实现替身。
 - JSONObject = [String: Any]，传入完整 open 成功 envelope。
   金额由生产适配层读为 Int64；保留 null，不补 0。
 - OpenAttempt(keyGenerator: () -> String)；
   start()/timeout()/retry()/authRequired(code: Int)/
   resendAfterAuth()/cancel()/abandon()；
   currentKey: String?、abandonCalled: Bool。
   键生成器同步调用；每行从 k1 开始。
   start、retry、resendAfterAuth 后各采样一次 currentKey，组成 expect.keys。
   cancel/abandon 后是否清空 currentKey 不作规定。
   abandonCalled 表示请求过服务端 abandon 接口，不是调用过 abandon()。
   open 不在该接口的四类 action 内，所以本组应始终为 false。
 - OpenResponseAction.map(response: JSONObject, context: JSONObject)
   -> { actionRaw: String, replaceLinkId: String?, requoteNotice: Bool }。
   confirm_coupon 是券失效确认的接线名；其余标签同向量。
   replaceLinkId 表示无论确认/取消均应更新卡片，不是待确认后的操作。
 - OpenErrorAction.map(code: Int, data: JSONObject)
   -> { actionRaw: String, textKey: String?, showTrace6: Bool }。
   接已有错误映射。notice 是业务提示分类，error 是购买受阻错误态；
   两者不能代替按钮、路由、卡片置灰等未表达的效果，见 gaps。
 - LateResponsePolicy.decide(interrupt: String)
   -> { jump: Bool, updateCard: Bool }。
   只判最近一次点击；jump 是继续响应流程的许可，不越过确认框。
 - JumpPlanRunner.simulate(plan: JSONObject, installed: JSONObject,
   stepResults: [String]) -> { executed: [String], final: String }。
   installed.app 是注入的目标 App 检测结果，不实际访问设备。
   stepResults 按 primary + fallbacks 的位置排列；未执行步骤的结果不消费。
   executed 记录尝试过的步骤类型，包含初始化失败的 sdk；
   sdk_init_failed 是初始化重试后仍失败；本组不验证初始化次数。
   browser 指系统浏览器；not_installed 行指未安装时复制口令后的安装提示。
   离线模拟不读取系统时钟，不据示例日期判断过期。
 - LinkJumpEvents.build(attemptId: String?, linkId: String?,
   steps: [JSONObject], isAuthJump: Bool) -> [JSONObject]。
   steps 是每步观测：phase/union_platform/step/result，
   purchase 另含 duration_ms、installed 字符串；可带不得上报的 value。
   返回事件业务字段，不含 Tracker 公共外壳；严格比较完整字段及数组顺序。
 - AuthMethodPicker.pick(platform: String, authMethods: [String],
   supported: [String]) -> String?；platform 是联盟平台；
   supported 注入当前端能力，不表示三端 SDK 已验证。
 - actionRaw/final 是测试接线标签，不新增契约枚举。
   expect 缺字段不判定，显式 null 必须无值。
 - 从 #filePath 向上找到 contract.lock；只读 specs/open-trade-vectors.json。
 */

import Foundation
import XCTest
@testable import Trade

private typealias OpenJSONObject = [String: Any]

final class OpenTradeVectorTests: XCTestCase {
    func testManifest() throws {
        let root = try vectors()
        let version: Int = try value(root, "version")
        let sources: [String] = try value(root, "sources")
        let gaps: [String] = try value(root, "gaps")
        XCTAssertEqual(version, 1)
        XCTAssertFalse(sources.isEmpty)
        XCTAssertFalse(gaps.isEmpty)
    }

    func testIdempotency() throws {
        try each("idempotency") { row, expected, label in
            var generated = 0
            var attempt = OpenAttempt(keyGenerator: {
                generated += 1
                return "k\(generated)"
            })
            var keys: [String] = []
            let steps: [OpenJSONObject] = try self.value(row, "steps")

            for (index, step) in steps.enumerated() {
                let op: String = try self.value(step, "op")
                let stepLabel = "\(label).steps[\(index)].\(op)"
                var sent = false

                switch op {
                case "start":
                    attempt.start()
                    sent = true
                case "timeout":
                    let before = attempt.currentKey
                    attempt.timeout()
                    XCTAssertEqual(attempt.currentKey, before, stepLabel)
                case "retry":
                    attempt.retry()
                    sent = true
                case "authRequired":
                    let code: Int = try self.value(step, "code")
                    attempt.authRequired(code: code)
                case "resendAfterAuth":
                    attempt.resendAfterAuth()
                    sent = true
                case "cancel":
                    attempt.cancel()
                case "abandon":
                    attempt.abandon()
                default:
                    XCTFail("\(stepLabel): 未知操作")
                    throw NSError(domain: "OpenTradeVectors", code: 1)
                }

                if sent {
                    keys.append(try XCTUnwrap(attempt.currentKey, stepLabel))
                }
            }

            let expectedKeys: [String] = try self.value(expected, "keys")
            XCTAssertEqual(keys, expectedKeys, "\(label).keys")
            XCTAssertEqual(generated, Set(expectedKeys).count, "\(label).generated")
            try self.assertFlag(expected, "abandonCalled", attempt.abandonCalled, label)
        }
    }

    func testOpenResponse() throws {
        try each("openResponse") { row, expected, label in
            let response: OpenJSONObject = try self.value(row, "response")
            let context: OpenJSONObject = try self.value(row, "context")
            let actual = OpenResponseAction.map(response: response, context: context)
            let action: String = try self.value(expected, "actionRaw")
            XCTAssertEqual(actual.actionRaw, action, "\(label).actionRaw")
            try self.assertText(expected, "replaceLinkId", actual.replaceLinkId, label)
            try self.assertFlag(expected, "requoteNotice", actual.requoteNotice, label)
        }
    }

    func testOpenError() throws {
        try each("openError") { row, expected, label in
            let code: Int = try self.value(row, "code")
            let data: OpenJSONObject
            if row.keys.contains("data") {
                data = try self.value(row, "data")
            } else {
                data = [:]
            }
            let actual = OpenErrorAction.map(code: code, data: data)
            let action: String = try self.value(expected, "actionRaw")
            XCTAssertEqual(actual.actionRaw, action, "\(label).actionRaw")
            try self.assertText(expected, "textKey", actual.textKey, label)
            try self.assertFlag(expected, "showTrace6", actual.showTrace6, label)
        }
    }

    func testLateResponse() throws {
        try each("lateResponse") { row, expected, label in
            let interrupt: String = try self.value(row, "interrupt")
            let actual = LateResponsePolicy.decide(interrupt: interrupt)
            let jump: Bool = try self.value(expected, "jump")
            let updateCard: Bool = try self.value(expected, "updateCard")
            XCTAssertEqual(actual.jump, jump, "\(label).jump")
            XCTAssertEqual(actual.updateCard, updateCard, "\(label).updateCard")
        }
    }

    func testJumpPlan() throws {
        try each("jumpPlan") { row, expected, label in
            let plan: OpenJSONObject = try self.value(row, "plan")
            let installed: OpenJSONObject = try self.value(row, "installed")
            let results: [String] = try self.value(row, "stepResults")
            let fallbacks: [OpenJSONObject] = try self.value(plan, "fallbacks")
            XCTAssertEqual(results.count, fallbacks.count + 1, "\(label).fixture")

            let actual = JumpPlanRunner.simulate(
                plan: plan,
                installed: installed,
                stepResults: results
            )
            let executed: [String] = try self.value(expected, "executed")
            let final: String = try self.value(expected, "final")
            XCTAssertEqual(actual.executed, executed, "\(label).executed")
            XCTAssertEqual(actual.final, final, "\(label).final")
        }
    }

    func testLinkJump() throws {
        try each("linkJump") { row, expected, label in
            let attemptId = try self.nullableText(row, "attemptId")
            let linkId = try self.nullableText(row, "linkId")
            let steps: [OpenJSONObject] = try self.value(row, "steps")
            let isAuthJump: Bool = try self.value(row, "isAuthJump")
            let actual = LinkJumpEvents.build(
                attemptId: attemptId,
                linkId: linkId,
                steps: steps,
                isAuthJump: isAuthJump
            )
            let events: [OpenJSONObject] = try self.value(expected, "events")
            // 对象键排序仅消除字典顺序差异；数组顺序、重复项和 JSON 类型均保留。
            let actualJSON = try JSONSerialization.data(
                withJSONObject: actual,
                options: [.sortedKeys]
            )
            let expectedJSON = try JSONSerialization.data(
                withJSONObject: events,
                options: [.sortedKeys]
            )
            XCTAssertEqual(actualJSON, expectedJSON, "\(label).events")
        }
    }

    func testAuthMethods() throws {
        try each("authMethods") { row, expected, label in
            let platform: String = try self.value(row, "platform")
            let methods: [String] = try self.value(row, "authMethods")
            let supported: [String] = try self.value(row, "supported")
            let actual = AuthMethodPicker.pick(
                platform: platform,
                authMethods: methods,
                supported: supported
            )
            let chosen = try self.nullableText(expected, "chosen")
            XCTAssertEqual(actual, chosen, "\(label).chosen")
        }
    }

    private func vectors() throws -> OpenJSONObject {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let manager = FileManager.default

        while !manager.fileExists(
            atPath: directory.appendingPathComponent("contract.lock").path
        ) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw NSError(
                    domain: "OpenTradeVectors",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "从 #filePath 向上找不到 contract.lock"]
                )
            }
            directory = parent
        }

        let url = directory.appendingPathComponent("specs/open-trade-vectors.json")
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(parsed as? OpenJSONObject, "向量根节点必须是对象")
    }

    private func each(
        _ group: String,
        _ body: (OpenJSONObject, OpenJSONObject, String) throws -> Void
    ) throws {
        let rows: [OpenJSONObject] = try value(try vectors(), group)
        XCTAssertFalse(rows.isEmpty, "\(group): 不得为空")
        var names: Set<String> = []

        for row in rows {
            let name: String = try value(row, "name")
            XCTAssertFalse(name.isEmpty, "\(group): 缺少名称")
            XCTAssertTrue(names.insert(name).inserted, "\(group).\(name): 名称重复")
            let expected: OpenJSONObject = try value(row, "expect")
            try body(row, expected, "\(group).\(name)")
        }
    }

    private func value<T>(_ object: OpenJSONObject, _ key: String) throws -> T {
        try XCTUnwrap(object[key] as? T, "\(key): 缺少字段或类型不符")
    }

    private func nullableText(_ object: OpenJSONObject, _ key: String) throws -> String? {
        let raw = try XCTUnwrap(object[key], "\(key): 缺少字段")
        if raw is NSNull {
            return nil
        }
        return try XCTUnwrap(raw as? String, "\(key): 应为字符串或 null")
    }

    private func assertText(
        _ expected: OpenJSONObject,
        _ key: String,
        _ actual: String?,
        _ label: String
    ) throws {
        guard expected.keys.contains(key) else { return }
        XCTAssertEqual(actual, try nullableText(expected, key), "\(label).\(key)")
    }

    private func assertFlag(
        _ expected: OpenJSONObject,
        _ key: String,
        _ actual: Bool,
        _ label: String
    ) throws {
        guard expected.keys.contains(key) else { return }
        let flag: Bool = try value(expected, key)
        XCTAssertEqual(actual, flag, "\(label).\(key)")
    }
}
