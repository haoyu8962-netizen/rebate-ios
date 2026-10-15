/*
 实现前测试；只读输出，未编译运行。沿用 Login / LoginTests target。

 接线约定：
 - @testable import Login；以下六个类型由 Login 暴露。
 - OAuthAttemptSession()：
   create() -> String；launch(_ attempt: String)；
   callback(_ attempt: String, seq: Int)；
   cancel()/leave()/timeout()；submit(_ attempt: String)。
   callback 只接收凭证，submit 是唯一提交边界；均为同步纯逻辑。
   submitted: [String]；dropped: [{attempt: String, seq: Int}]。
   dropped 只记录被拒的 callback；重复/失效 submit 不追加 submitted。
   create 步骤的 a/b 是用例别名，绑定真实返回句柄，不假定句柄格式。
   seq 是回调观测编号，不是 nonce、时间或跨 attempt 排序依据。
 - OAuthLoginRoute.map(provider: String, response: [String: Any])
   -> {routeRaw: String, saveSession: Bool, firstPurchaseTip: Bool?}。
   response 是完整响应外壳。只覆盖 full、默认开启引导的候选分流；
   saveSession 是意图，原子保存和最终路由守卫另验。
 - OAuthLoginErrorAction.map(provider: String, code: Int, data: [String: Any])
   -> {actionRaw: String, textKey: String?, showTrace6: Bool?}。
   接已有 ErrorActionMapper。reauthorize 要求用户重新授权；
   provider_unavailable 保留其他方式；二者不自动重试。
 - ThirdPartyButtons.wechatVisible(platform: String, installed: Bool,
   adapterAvailable: Bool) -> Bool；
   ThirdPartyButtons.appleVisible(platform: String) -> Bool。
   adapterAvailable 表示已允许启用；正式微信实现为 false，
   true 向量用于 Debug 假适配器/能力已获准的纯逻辑。
 - BindPhoneAction.map(_ responseOrError: [String: Any])
   -> {actionRaw: String, textKey: String?}。
   输入为本地包装 {operation, purpose?, body, headers?}；
   body 才是契约响应，purpose 来自原请求。
   retry_after 表示等待/交给倒计时组件；发码成功不等于绑定完成。
   merge_confirm 只提示确认；done 后刷新 getMe 的执行另验。
 - MergeDecision.apply(decision: String, response: [String: Any]?)
   -> {resultRaw: String, saveSession: Bool}。
   cancelled=请求前取消；rejected=确认后收到 30411。
   锁定契约缺并号成功 schema，缺失用例见 gaps，不伪造响应。
 - raw 值是测试接线名，不是新增契约路由。
 - expect 缺字段不判定；显式 null 要求无值。
 - 每行独立状态，无 SDK、网络、真实时钟、令牌解码或持久化。
 */

import Foundation
import XCTest
@testable import Login

private typealias OAuthJSONObject = [String: Any]

final class OAuthLoginVectorTests: XCTestCase {
    func testManifest() throws {
        let root = try vectors()
        let version: Int = try value(root, "version")
        let sources: [String] = try value(root, "sources")
        let gaps: [String] = try value(root, "gaps")
        XCTAssertEqual(version, 1)
        XCTAssertFalse(sources.isEmpty)
        XCTAssertFalse(gaps.isEmpty)
    }

    func testAttemptVectors() throws {
        try each("attempt") { row, expected, label in
            var session = OAuthAttemptSession()
            var handles: [String: String] = [:]
            let steps: [OAuthJSONObject] = try self.value(row, "steps")
            XCTAssertFalse(steps.isEmpty, label)

            for (index, step) in steps.enumerated() {
                let op: String = try self.value(step, "op")
                let context = "\(label).steps[\(index)].\(op)"

                switch op {
                case "create":
                    let alias: String = try self.value(step, "attempt")
                    XCTAssertNil(handles[alias], "\(context): 别名重复")
                    let handle = session.create()
                    XCTAssertFalse(handle.isEmpty, context)
                    XCTAssertFalse(
                        handles.values.contains(handle),
                        "\(context): 新尝试不能复用旧句柄"
                    )
                    handles[alias] = handle
                case "launch", "callback", "submit":
                    let alias: String = try self.value(step, "attempt")
                    let handle = try self.handle(alias, handles, context)
                    switch op {
                    case "launch":
                        session.launch(handle)
                    case "callback":
                        let seq: Int = try self.value(step, "seq")
                        session.callback(handle, seq: seq)
                    default:
                        session.submit(handle)
                    }
                case "cancel":
                    session.cancel()
                case "leave":
                    session.leave()
                case "timeout":
                    session.timeout()
                default:
                    throw self.failure("\(context): 未知操作")
                }
            }

            let submitted: [String] = try self.value(expected, "submitted")
            let expectedHandles = try submitted.map {
                try self.handle($0, handles, label)
            }
            XCTAssertEqual(
                session.submitted,
                expectedHandles,
                "\(label).submitted：内容、次数、顺序"
            )

            let dropped: [OAuthJSONObject] = try self.value(expected, "dropped")
            XCTAssertEqual(session.dropped.count, dropped.count, "\(label).dropped.count")
            for (index, pair) in zip(session.dropped, dropped).enumerated() {
                let alias: String = try self.value(pair.1, "attempt")
                let seq: Int = try self.value(pair.1, "seq")
                XCTAssertEqual(
                    pair.0.attempt,
                    try self.handle(alias, handles, label),
                    "\(label).dropped[\(index)].attempt"
                )
                XCTAssertEqual(pair.0.seq, seq, "\(label).dropped[\(index)].seq")
            }
        }
    }

    func testLoginResultVectors() throws {
        try each("loginResult") { row, expected, label in
            let provider: String = try self.value(row, "provider")
            let response: OAuthJSONObject = try self.value(row, "response")
            let actual = OAuthLoginRoute.map(provider: provider, response: response)
            let route: String = try self.value(expected, "routeRaw")
            let save: Bool = try self.value(expected, "saveSession")
            XCTAssertEqual(actual.routeRaw, route, "\(label).routeRaw")
            XCTAssertEqual(actual.saveSession, save, "\(label).saveSession")
            try self.assertOptional(
                expected, "firstPurchaseTip", actual.firstPurchaseTip, label
            )
        }
    }

    func testLoginErrorVectors() throws {
        try each("loginError") { row, expected, label in
            let provider: String = try self.value(row, "provider")
            let code: Int = try self.value(row, "code")
            let data: OAuthJSONObject
            if row.keys.contains("data") {
                data = try self.value(row, "data")
            } else {
                data = [:]
            }
            let actual = OAuthLoginErrorAction.map(
                provider: provider, code: code, data: data
            )
            let action: String = try self.value(expected, "actionRaw")
            XCTAssertEqual(actual.actionRaw, action, "\(label).actionRaw")
            try self.assertOptional(expected, "textKey", actual.textKey, label)
            try self.assertOptional(expected, "showTrace6", actual.showTrace6, label)
        }
    }

    func testWechatButtonVectors() throws {
        try each("wechatButton") { row, expected, label in
            let platform: String = try self.value(row, "platform")
            let installed: Bool = try self.value(row, "installed")
            let available: Bool = try self.value(row, "adapterAvailable")
            let visible: Bool = try self.value(expected, "visible")
            XCTAssertEqual(
                ThirdPartyButtons.wechatVisible(
                    platform: platform,
                    installed: installed,
                    adapterAvailable: available
                ),
                visible,
                "\(label).visible"
            )
        }
    }

    func testAppleButtonVectors() throws {
        try each("appleButton") { row, expected, label in
            let platform: String = try self.value(row, "platform")
            let visible: Bool = try self.value(expected, "visible")
            XCTAssertEqual(
                ThirdPartyButtons.appleVisible(platform: platform),
                visible,
                "\(label).visible"
            )
        }
    }

    func testBindPhoneVectors() throws {
        try each("bindPhone") { row, expected, label in
            let hasResponse = row.keys.contains("response")
            let hasError = row.keys.contains("error")
            guard hasResponse != hasError else {
                throw self.failure("\(label): response/error 必须且只能有一个")
            }
            let input: OAuthJSONObject = try self.value(
                row, hasResponse ? "response" : "error"
            )
            let actual = BindPhoneAction.map(input)
            let action: String = try self.value(expected, "actionRaw")
            XCTAssertEqual(actual.actionRaw, action, "\(label).actionRaw")
            try self.assertOptional(expected, "textKey", actual.textKey, label)
        }
    }

    func testMergeVectors() throws {
        try each("merge") { row, expected, label in
            let decision: String = try self.value(row, "decision")
            let response: OAuthJSONObject?
            if row.keys.contains("response") {
                response = try self.value(row, "response")
            } else {
                response = nil
            }
            let actual = MergeDecision.apply(decision: decision, response: response)
            let result: String = try self.value(expected, "resultRaw")
            let save: Bool = try self.value(expected, "saveSession")
            XCTAssertEqual(actual.resultRaw, result, "\(label).resultRaw")
            XCTAssertEqual(actual.saveSession, save, "\(label).saveSession")
        }
    }

    private func vectors() throws -> OAuthJSONObject {
        var directory = URL(fileURLWithPath: #filePath)
            .standardizedFileURL.deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("contract.lock").path
        ) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw failure("从 \(#filePath) 向上找不到 contract.lock")
            }
            directory = parent
        }
        let url = directory.appendingPathComponent("specs/oauth-login-vectors.json")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? OAuthJSONObject,
            "\(url.path): 根节点必须是对象"
        )
    }

    private func each(
        _ group: String,
        _ body: (OAuthJSONObject, OAuthJSONObject, String) throws -> Void
    ) throws {
        let rows: [OAuthJSONObject] = try value(try vectors(), group)
        XCTAssertFalse(rows.isEmpty, "\(group): 向量不能为空")
        var names = Set<String>()
        for row in rows {
            let name: String = try value(row, "name")
            let label = "\(group).\(name)"
            XCTAssertFalse(name.isEmpty, label)
            XCTAssertTrue(names.insert(name).inserted, "\(label): 名称重复")
            let expected: OAuthJSONObject = try value(row, "expect")
            try body(row, expected, label)
        }
    }

    private func value<T>(_ object: OAuthJSONObject, _ key: String) throws -> T {
        try XCTUnwrap(object[key] as? T, "\(key): 缺失或类型错误")
    }

    private func handle(
        _ alias: String,
        _ handles: [String: String],
        _ label: String
    ) throws -> String {
        try XCTUnwrap(handles[alias], "\(label): 未创建的 attempt 别名 \(alias)")
    }

    private func assertOptional<T: Equatable>(
        _ expected: OAuthJSONObject,
        _ key: String,
        _ actual: T?,
        _ label: String
    ) throws {
        guard let raw = expected[key] else { return }
        if raw is NSNull {
            XCTAssertNil(actual, "\(label).\(key)")
        } else {
            let wanted: T = try value(expected, key)
            XCTAssertEqual(actual, Optional(wanted), "\(label).\(key)")
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(
            domain: "OAuthLoginVectors",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
