#if DEBUG
import Foundation
import Login

/// 第三方登录与绑手机的本机假服务、假适配器（APP-05b 截图、冒烟与设计稿比对用；只在 Debug / Staging 编译，APP-04 共性 2）。由
/// `DebugFakeLoginServer`（启动参数 `-CouliFakeLoginServer`）接管时回答；Release 制品扫描查 `marker` 与类型名。全部在本机回答，不调任何
/// SDK、不连任何地址；授权码、identity token、并号凭据都是明显的演示值，不是凭证。
///
/// 开关（启动参数 `-CouliFakeOAuth login=existing,auth=cancel,…`）：
/// - login=new（缺省，第三方新号）| existing（老用户）| risk（44001）| unavailable（50305）| invalid（20004）| limited（42901）；
/// - auth=ok（缺省，0.6 秒后带回演示凭证）| cancel（用户取消）| fail（拉起失败）；wechat=hidden（假微信适配器不可用，同 Release）。
/// 绑手机（POST /v1/me/phone）：13800005678 → 30411 mergeable（带演示并号凭据）、13800001111 → 30411、13800004444 → 44001、
/// 13800007777 → 10007 cooling、13800009999 → 第一次响应丢失（结果未知 → 待确认），之后按验证码；验证码 123456 → 成功、200030 → 20003、
/// 429010 → 42901（Retry-After 30），其余 → 20002。作废（action=phone_change）→ abandoned。
final class DebugFakeOAuth: @unchecked Sendable {
    static let marker = "COULI_FAKE_OAUTH_SERVER_APP05B_IOS_4c7e1d"
    static let launchArgument = "CouliFakeOAuth"
    static let shared = DebugFakeOAuth()

    private let lock = NSLock()
    private var bound = true
    private var lostKeys: Set<String> = []

    var options: [String: String] {
        var out: [String: String] = [:]
        for part in (UserDefaults.standard.string(forKey: Self.launchArgument) ?? "").split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            out[pair[0]] = pair.count == 2 ? pair[1] : "1"
        }
        return out
    }

    /// 假账号此刻的 phone_bound（GET /v1/me 用）：第三方新号登录后为 false，绑定成功后为 true；缺省 true（短信登录）。
    var phoneBound: Bool {
        lock.withLock { bound }
    }

    /// 冷启动直接是已登录假账号（`-CouliFakeLoginServer -CouliFakeTradeLoggedIn`）时：按短信登录的账号记「已绑手机」。
    @MainActor
    static func seedLoggedInPhone(_ login: AppLogin, arguments: [String]) {
        guard arguments.contains(DebugFakeLoginServer.launchArgument),
              arguments.contains(DebugFakeTrade.loggedInArgument)
        else { return }
        login.phone.record(true, generation: login.client.sessionGeneration)
    }

    /// Debug / Staging 的第三方适配器（编排裁定 N-41、第 1 轮 R1-06）：
    /// - 不论有没有 `-CouliFakeLoginServer`，Apple 按钮都显示，并走本机假授权（演示 identity token，之后的 loginByApple 发给当前环境；
    ///   没开本机假服务时由真实后端判定，演示凭证会被拒，只用于看界面与走流程）；Release 不编译这里，仍由 AppleSignInSwitch 控制；
    /// - 打开本机假服务时微信也用假适配器（可用；`wechat=hidden` 模拟 Release 的不可用）；没开时微信用正式的「不可用」适配器。
    @MainActor
    static func authorizers(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> [String: ThirdPartyAuthorizer] {
        let mode = shared.options["auth"] ?? "ok"
        guard arguments.contains(DebugFakeLoginServer.launchArgument) else {
            return [
                OAuthProvider.wechat: UnavailableWechatAuthorizer(),
                OAuthProvider.apple: DebugFakeAuthorizer(provider: OAuthProvider.apple, available: true, mode: mode),
            ]
        }
        return [
            OAuthProvider.wechat: DebugFakeAuthorizer(
                provider: OAuthProvider.wechat, available: shared.options["wechat"] != "hidden", mode: mode
            ),
            OAuthProvider.apple: DebugFakeAuthorizer(provider: OAuthProvider.apple, available: true, mode: mode),
        ]
    }

    /// 一次回答：业务码、data 的 JSON 文本、响应头；`lost` = 响应丢失（按传输失败结束）。
    struct Answer {
        let code: Int
        let data: String
        var headers: [String: String] = [:]
        var lost = false
    }

    /// 回答第三方登录与绑手机路径；不是本服务的为 nil。
    func answer(method: String, path: String, body: [String: Any]) -> Answer? {
        switch (method, path) {
        case ("POST", "/v1/auth/oauth-attempts"):
            let data = "{\"attempt_id\":\"debug-attempt-0001\",\"nonce\":\"debug-nonce-not-secret-0001\","
                + "\"expire_at\":\"2099-01-01T00:10:00+08:00\"}"
            return Answer(code: 0, data: data)
        case ("POST", "/v1/auth/login/wechat"), ("POST", "/v1/auth/login/apple"):
            return login()
        case ("POST", "/v1/me/phone"):
            return bindPhone(body)
        case ("POST", "/v1/idempotency-keys/abandon") where (body["action"] as? String) == "phone_change":
            return Answer(code: 0, data: "{\"outcome\":\"abandoned\",\"original\":null}")
        default:
            return nil
        }
    }

    private func login() -> Answer {
        let mode = options["login"] ?? "new"
        switch mode {
        case "risk": return Answer(code: 44001, data: "{}")
        case "unavailable": return Answer(code: 50305, data: "{\"provider\":\"wechat\"}")
        case "invalid": return Answer(code: 20004, data: "{}")
        case "limited": return Answer(code: 42901, data: "{}", headers: ["Retry-After": "30"])
        default: break
        }
        let isNew = mode != "existing"
        lock.withLock { bound = !isNew }
        let data = "{\"user_id\":\"debug-oauth-user\",\"is_new_user\":\(isNew),\"tokens\":{\"access_token\":"
            + "\"debug-at-oauth\",\"refresh_token\":\"debug-rt-oauth\",\"session_scope\":\"full\"}}"
        return Answer(code: 0, data: data)
    }

    private func bindPhone(_ body: [String: Any]) -> Answer {
        let phone = body["phone"] as? String ?? ""
        let code = body["code"] as? String ?? ""
        if let byPhone = Self.byPhone[phone] {
            return byPhone
        }
        if phone == "13800009999" {
            // 响应丢失：业务结果先落下（验证码正确时已绑定），再丢响应（APP-09 共性第 69 条）；同键确认回同一结果
            let first = lock.withLock { lostKeys.insert(phone).inserted }
            if first {
                var answer = byCode(code)
                answer.lost = true
                return answer
            }
        }
        return byCode(code)
    }

    private static let byPhone: [String: Answer] = [
        "13800005678": Answer(
            code: 30411,
            data: "{\"reason\":\"mergeable\",\"merge_ticket\":\"debug-merge-ticket-demo\"}"
        ),
        "13800001111": Answer(code: 30411, data: "{}"),
        "13800004444": Answer(code: 44001, data: "{}"),
        "13800007777": Answer(code: 10007, data: "{\"stage\":\"cooling\"}"),
    ]

    private func byCode(_ code: String) -> Answer {
        switch code {
        case "123456":
            lock.withLock { bound = true }
            return Answer(code: 0, data: "{}")
        case "200030": return Answer(code: 20003, data: "{}")
        case "429010": return Answer(code: 42901, data: "{}", headers: ["Retry-After": "30"])
        default: return Answer(code: 20002, data: "{}")
        }
    }
}

/// 假第三方适配器（只在 Debug / Staging）：不调任何 SDK；0.6 秒后带回演示凭证，或按开关取消 / 失败。
@MainActor
final class DebugFakeAuthorizer: ThirdPartyAuthorizer {
    let provider: String
    let available: Bool
    let installed: Bool? = true
    private let mode: String
    private var waiting: CheckedContinuation<OAuthAuthorization, Never>?

    init(provider: String, available: Bool, mode: String) {
        self.provider = provider
        self.available = available
        self.mode = mode
    }

    func authorize(nonce _: String) async -> OAuthAuthorization {
        await withCheckedContinuation { continuation in
            waiting = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                self?.finish()
            }
        }
    }

    private func finish() {
        let result: OAuthAuthorization = switch mode {
        case "cancel": .cancelled
        case "fail": .failed
        default: Self.credential(provider)
        }
        resume(result)
    }

    private static func credential(_ provider: String) -> OAuthAuthorization {
        if provider == OAuthProvider.wechat {
            return .credential(.wechat(code: "debug-wechat-code-demo"))
        }
        return .credential(.apple(
            identityToken: "debug-apple-identity-demo",
            authorizationCode: "debug-apple-code-demo"
        ))
    }

    func abort() {
        resume(.cancelled)
    }

    private func resume(_ result: OAuthAuthorization) {
        let pending = waiting
        waiting = nil
        pending?.resume(returning: result)
    }
}
#endif
