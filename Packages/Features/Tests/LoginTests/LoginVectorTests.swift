/*
 实现前测试；只读输出，未编译运行。需注册 Login / LoginTests target。

 接线约定：
 - @testable import Login；以下类型由 Login 暴露。
 - PhoneNumber.normalize(_ raw: String)
   -> { valid: Bool, normalized: String?, reasonRaw: String? }。
 - AgreementState(clock: () -> Int64)，默认未勾选；
   tapLogin()/check()/uncheck()/confirm(nowMillis: Int64)/cancel()；
   showConfirm、proceed: Bool，consentAtMillis: Int64?。
   check() 使用注入时钟，confirm 使用实参；单位均为毫秒。
 - SmsCountdown.after(code: Int, retryAfterHeader: String?, nowMillis: Int64)
   -> { countdownSec: Int, canResend: Bool, stateRaw: String, textKey: String? }。
   code 是统一响应外壳的业务码，成功为 0，不是 HTTP 状态。
 - CodeInput.accept(_ raw: String) -> { complete: Bool, digitsOnly: Bool }；
   报告原字符串形状：digitsOnly 表示没有 ASCII 数字以外的字符
   （空串为 true），complete 表示恰为六位 ASCII 数字，不测试 UI 清洗。
 - LoginErrorMapper.map(op: String, code: Int, data: [String: Any])
   -> { stateRaw: String, textKey: String?, field: String?, route: String? }；
   接已有 ErrorActionMapper，不另造错误码表。
 - InviteField.decide(_ raw: String, context: [String: Any])
   -> { showInviteField: Bool, valid: Bool?, noticeKey: String? }；
   valid 只判注册输入语法，空值可省略，不决定是否允许登录。
 - AfterLogin.plan(response: [String: Any], state: [String: Any]) -> [String]；
   response 是向量中的投影，session_scope 取实际 tokens.session_scope。
   输出完整的会话/路由计划，逐项比较顺序，不排序、不去重：
   save_session、resume_pending、discard_pending、enter_force_update。
   resume_pending 仅委托 Router 守卫；实际保存、通知和邀请提示另验。
 - stateRaw 是三端测试接线名，不是新契约枚举或路由：
   registration_blocked 对应 LoginCodeBlocked；
   deletion_processing 对应 LoginDeletionProcessing；
   session_expired 对应 LoginSessionExpired。
 - expect 字段缺失表示不判定；显式 null 表示必须无值。
 - 每行新建状态；时间固定，每步递增 1000 毫秒，无真实网络/计时器。
 */

import Foundation
import XCTest
@testable import Login

private typealias LoginJSONObject = [String: Any]

private final class LoginVectorClock {
    var nowMillis: Int64 = 0
}

final class LoginVectorTests: XCTestCase {
    func testManifest() throws {
        let root = try vectors()
        let version: Int = try value(root, "version")
        let sources: [String] = try value(root, "sources")
        let gaps: [String] = try value(root, "gaps")
        XCTAssertEqual(version, 1)
        XCTAssertFalse(sources.isEmpty)
        XCTAssertFalse(gaps.isEmpty)
    }

    func testPhoneVectors() throws {
        try each("phone") { row, expected, label in
            let raw: String = try self.value(row, "raw")
            let actual = PhoneNumber.normalize(raw)
            let valid: Bool = try self.value(expected, "valid")
            XCTAssertEqual(actual.valid, valid, "\(label).valid")
            try self.assertText(expected, "normalized", actual.normalized, label)
            try self.assertText(expected, "reason", actual.reasonRaw, label)
        }
    }

    func testAgreementVectors() throws {
        try each("agreement") { row, expected, label in
            let clock = LoginVectorClock()
            var state = AgreementState(clock: { clock.nowMillis })
            var acceptedAt: Int64?
            let steps: [LoginJSONObject] = try self.value(row, "steps")

            for (index, step) in steps.enumerated() {
                clock.nowMillis = 1_700_000_000_000 + Int64(index) * 1_000
                let op: String = try self.value(step, "op")
                let context = "\(label).steps[\(index)].\(op)"

                switch op {
                case "tapLogin":
                    state.tapLogin()
                case "check":
                    state.check()
                    acceptedAt = clock.nowMillis
                    XCTAssertEqual(state.consentAtMillis, acceptedAt, context)
                case "uncheck":
                    state.uncheck()
                    // 不规定取消勾选后的历史时间存储表示。
                case "confirmAgree":
                    // 检出“uncheck 被忽略，但 confirm 无条件放行”的错误实现。
                    XCTAssertTrue(state.showConfirm, "\(context): 应先展示确认框")
                    state.confirm(nowMillis: clock.nowMillis)
                    acceptedAt = clock.nowMillis
                    XCTAssertEqual(state.consentAtMillis, acceptedAt, context)
                case "cancelConfirm":
                    state.cancel()
                default:
                    XCTFail("\(context): 未知操作")
                    throw NSError(domain: "LoginVectors", code: 2)
                }
            }

            let showConfirm: Bool = try self.value(expected, "showConfirm")
            let proceed: Bool = try self.value(expected, "proceed")
            let recorded: Bool = try self.value(expected, "consentRecorded")
            XCTAssertEqual(state.showConfirm, showConfirm, "\(label).showConfirm")
            XCTAssertEqual(state.proceed, proceed, "\(label).proceed")
            XCTAssertEqual(
                state.consentAtMillis != nil,
                recorded,
                "\(label).consentRecorded"
            )
            if recorded {
                let clickTime = try XCTUnwrap(acceptedAt, "\(label): 缺少同意步骤")
                XCTAssertEqual(
                    state.consentAtMillis,
                    clickTime,
                    "\(label): 使用勾选/确认时刻，不能改成提交时刻"
                )
            }
        }
    }

    func testSmsSendVectors() throws {
        try each("smsSend") { row, expected, label in
            let response: LoginJSONObject = try self.value(row, "response")
            let headers = response["headers"] as? [String: String]
            let code: Int = try self.value(response, "code")
            let now: NSNumber = try self.value(row, "nowMillis")
            let actual = SmsCountdown.after(
                code: code,
                retryAfterHeader: headers?["Retry-After"],
                nowMillis: now.int64Value
            )
            let seconds: Int = try self.value(expected, "countdownSec")
            let canResend: Bool = try self.value(expected, "canResend")
            let stateRaw: String = try self.value(expected, "stateRaw")
            XCTAssertEqual(actual.countdownSec, seconds, "\(label).countdownSec")
            XCTAssertEqual(actual.canResend, canResend, "\(label).canResend")
            XCTAssertEqual(actual.stateRaw, stateRaw, "\(label).stateRaw")
            try self.assertText(expected, "textKey", actual.textKey, label)
        }
    }

    func testCodeVectors() throws {
        try each("code") { row, expected, label in
            let input: String = try self.value(row, "input")
            let actual = CodeInput.accept(input)
            let complete: Bool = try self.value(expected, "complete")
            let digitsOnly: Bool = try self.value(expected, "digitsOnly")
            XCTAssertEqual(actual.complete, complete, "\(label).complete")
            XCTAssertEqual(actual.digitsOnly, digitsOnly, "\(label).digitsOnly")
        }
    }

    func testLoginErrorVectors() throws {
        try each("loginError") { row, expected, label in
            let op: String = try self.value(row, "op")
            let code: Int = try self.value(row, "code")
            let data: LoginJSONObject = row["data"] as? LoginJSONObject ?? [:]
            let actual = LoginErrorMapper.map(op: op, code: code, data: data)
            let stateRaw: String = try self.value(expected, "stateRaw")
            XCTAssertEqual(actual.stateRaw, stateRaw, "\(label).stateRaw")
            try self.assertText(expected, "textKey", actual.textKey, label)
            try self.assertText(expected, "field", actual.field, label)
            try self.assertText(expected, "route", actual.route, label)
        }
    }

    func testInviteVectors() throws {
        try each("invite") { row, expected, label in
            let raw: String = try self.value(row, "raw")
            let context: LoginJSONObject = try self.value(row, "context")
            let actual = InviteField.decide(raw, context: context)
            let visible: Bool = try self.value(expected, "showInviteField")
            XCTAssertEqual(
                actual.showInviteField,
                visible,
                "\(label).showInviteField"
            )
            if expected.keys.contains("valid") {
                let valid: Bool = try self.value(expected, "valid")
                XCTAssertEqual(actual.valid, valid, "\(label).valid")
            }
            try self.assertText(expected, "noticeKey", actual.noticeKey, label)
        }
    }

    func testAfterLoginVectors() throws {
        try each("afterLogin") { row, expected, label in
            let response: LoginJSONObject = try self.value(row, "response")
            let state: LoginJSONObject = try self.value(row, "state")
            let actions: [String] = try self.value(expected, "actions")
            let actual = AfterLogin.plan(response: response, state: state)
            XCTAssertEqual(actual, actions, "\(label).actions：内容、次数、顺序")
        }
    }

    private func vectors() throws -> LoginJSONObject {
        var directory = URL(fileURLWithPath: #filePath)
            .standardizedFileURL.deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("contract.lock").path
        ) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw NSError(
                    domain: "LoginVectors",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "从 \(#filePath) 向上找不到 contract.lock",
                    ]
                )
            }
            directory = parent
        }
        let url = directory.appendingPathComponent("specs/login-vectors.json")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? LoginJSONObject,
            "\(url.path): 根节点必须是对象"
        )
    }

    private func each(
        _ group: String,
        _ body: (LoginJSONObject, LoginJSONObject, String) throws -> Void
    ) throws {
        let rows: [LoginJSONObject] = try value(try vectors(), group)
        XCTAssertFalse(rows.isEmpty, "\(group): 向量不能为空")
        var names = Set<String>()
        for row in rows {
            let name: String = try value(row, "name")
            let label = "\(group).\(name)"
            XCTAssertFalse(name.isEmpty, label)
            XCTAssertTrue(names.insert(name).inserted, "\(label): 名称重复")
            let expected: LoginJSONObject = try value(row, "expect")
            try body(row, expected, label)
        }
    }

    private func value<T>(_ object: LoginJSONObject, _ key: String) throws -> T {
        try XCTUnwrap(object[key] as? T, "\(key): 缺失或类型错误")
    }

    private func assertText(
        _ expected: LoginJSONObject,
        _ key: String,
        _ actual: String?,
        _ label: String
    ) throws {
        guard let raw = expected[key] else {
            return
        }
        if raw is NSNull {
            XCTAssertNil(actual, "\(label).\(key)")
        } else {
            let text: String = try value(expected, key)
            XCTAssertEqual(actual, text, "\(label).\(key)")
        }
    }
}
