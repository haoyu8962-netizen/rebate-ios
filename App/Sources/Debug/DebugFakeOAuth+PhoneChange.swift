#if DEBUG
import Foundation

/// 换手机号（APP-13a-2）的本机假服务分支（只在 Debug / Staging 编译；入口另由 `-CouliFakeMe phone_change=on` 打开，Release 恒关）。
/// 区分首次绑定与更换只看请求有没有 X-Step-Up-Token：没带的照旧走首次绑定那一支（行为不变）。第 1 步与 10003 面板的发码 / 验证仍由
/// DebugFakeWallet 回答（验证码 123456 → token fake-step-up-phone_change-n），这里只按场景截 30414。
///
/// 开关（启动参数 `-CouliFakeOAuth change=…`）：ok（缺省）| 30411 | 30411_mergeable | 30414 | 30414_sms | 30414_verify |
/// 44001 | 20903 |
/// 50401 | 42901 | 10405 | lost（第一次响应丢失 → 待确认，之后按验证码）；`abandon=completed`（放弃得到 completed 原结果 0）|
/// `abandon=completed_30411`。更换提交：token 不是本 action 的有效 token → 10003；新号 13800005678（测试号，即当前号）→ 20001
/// fields=[phone]（B1-20b 新号等于当前号）；其余按验证码：123456 → 成功，200030 → 20003，其余 → 20002。
extension DebugFakeOAuth {
    func phoneChangeAnswer(method: String, path: String, body: [String: Any], headers: [String: String]) -> Answer? {
        let mode = options["change"] ?? "ok"
        switch (method, path) {
        case ("POST", "/v1/auth/sms-codes") where body["action"] as? String == "phone_change" && mode == "30414_sms":
            return Answer(code: 30414, data: "null")
        case ("POST", "/v1/auth/step-up") where body["action"] as? String == "phone_change" && mode == "30414_verify":
            return Answer(code: 30414, data: "null")
        case ("POST", "/v1/idempotency-keys/abandon") where body["action"] as? String == "phone_change":
            return abandonChange()
        case ("POST", "/v1/me/phone") where DebugFakeWallet.header(headers, "X-Step-Up-Token") != nil:
            return change(body, headers: headers, mode: mode)
        default:
            return nil
        }
    }

    private func abandonChange() -> Answer? {
        switch options["abandon"] {
        case "completed":
            Answer(
                code: 0, data: "{\"outcome\":\"completed\",\"original\":{\"code\":0,\"msg\":\"\",\"data\":{}}}"
            )
        case "completed_30411":
            Answer(
                code: 0, data: "{\"outcome\":\"completed\",\"original\":{\"code\":30411,\"msg\":\"\",\"data\":null}}"
            )
        default:
            nil
        }
    }

    private func change(_ body: [String: Any], headers: [String: String], mode: String) -> Answer {
        let valid = DebugFakeWallet.shared.lock.withLock {
            DebugFakeWallet.shared.tokenValid(headers, action: "phone_change")
        }
        guard valid else { return Answer(code: 10003, data: "null") }
        if let scenario = Self.changeScenarios[mode] {
            return scenario
        }
        let phone = (body["phone"] as? String ?? "").filter(\.isNumber)
        if phone.hasSuffix("13800005678") {
            return Answer(code: 20001, data: "{\"fields\":[\"phone\"]}")
        }
        if mode == "lost" {
            let key = "change|" + (DebugFakeWallet.header(headers, "Idempotency-Key") ?? "")
            let first = lock.withLock { changeLost.insert(key).inserted }
            var answer = changeByCode(body["code"] as? String ?? "")
            answer.lost = first
            return answer
        }
        return changeByCode(body["code"] as? String ?? "")
    }

    private static let changeScenarios: [String: Answer] = [
        "30411": Answer(code: 30411, data: "{}"),
        "30411_mergeable": Answer(
            code: 30411, data: "{\"reason\":\"mergeable\",\"merge_ticket\":\"debug-merge-ticket-demo\"}"
        ),
        "30414": Answer(code: 30414, data: "null"),
        "44001": Answer(code: 44001, data: "{\"risk_msg_code\":\"phone_blacklisted\"}"),
        "20903": Answer(code: 20903, data: "null"),
        "50401": Answer(code: 50401, data: "null"),
        "42901": Answer(code: 42901, data: "null", headers: ["Retry-After": "30"]),
        "10405": Answer(code: 10405, data: "{\"min_supported_version\":\"99.0.0\"}"),
    ]

    private func changeByCode(_ code: String) -> Answer {
        switch code {
        case "123456": Answer(code: 0, data: "{}")
        case "200030": Answer(code: 20003, data: "null")
        default: Answer(code: 20002, data: "null")
        }
    }
}
#endif
