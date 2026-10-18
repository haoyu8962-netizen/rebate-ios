#if DEBUG
import Foundation
import Generated
import Router
import SecureStore
import Session

/// 本机假服务（APP-05a 截图、冒烟与设计稿比对用；只在 Debug / Staging 编译，APP-04 共性 2）：URLProtocol 桩，
/// 全部请求在本机回答，不连任何地址。启动参数 `-CouliFakeLoginServer` 打开时才接管 ApiClient 的会话配置。
/// Release 制品扫描查 `marker` 与类名（tools/ci/release-scan.sh）。第三方登录与绑手机见 `DebugFakeOAuth`（APP-05b）。
///
/// 场景按输入值选：
/// - 发码：13900000000 → 42901（Retry-After 120）；13700000000 第一次成功、之后 42901（Retry-After 3600，共性 12 演示）；
///   其余成功（60 秒）。
/// - 登录：验证码 200020 → 20002、200030 → 20003、444444 → 44001、100070 → 10007 processing、104050 → 10405 no_account；
///   其余成功：13600000000 拿 deletion_only，其余 full；带邀请码时按新号，语法合法 bound，否则 failed 30401。
final class DebugFakeLoginServer: URLProtocol {
    /// 一次回答：业务码、data 的 JSON 文本、响应头。
    struct Reply {
        let code: Int
        let data: String
        var headers: [String: String] = [:]
    }

    static let marker = "COULI_FAKE_LOGIN_SERVER_APP05A_IOS_3f8e21"
    static let launchArgument = "-CouliFakeLoginServer"

    private static let lock = NSLock()
    private nonisolated(unsafe) static var sentPhones: Set<String> = []

    /// 启动参数里有 `-CouliFakeLoginServer` 时返回接管所有请求的会话配置；否则 nil。打开时从游客开始：清掉本机会话与
    /// pending_action（截图与 UI 测试每次冷启动状态一致）。
    /// 假登录的 access_token（不是凭据）。
    static let fakeTradeAccess = "debug-at-trade"

    static func configurationIfEnabled(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> URLSessionConfiguration? {
        guard arguments.contains(launchArgument) else { return nil }
        let tokens = SecureSessionTokens.production()
        // FU-IOS-0712：冷启动直接是已登录假账号时沿用上一次假登录的持久化登录世代（模拟同一次登录跨进程保留：断网冷启动读订单 / 钱包缓存
        // 的截图与冒烟用例要它）；其余一律从游客开始
        let keptEpoch = arguments.contains(DebugFakeTrade.loggedInArgument)
            ? (try? tokens.readSession()).flatMap(\.self).flatMap { $0.access == fakeTradeAccess ? $0.loginEpoch : nil }
            : nil
        try? tokens.clear()
        UserDefaultsPendingBackend().delete()
        // APP-08：订单 Tab 的恢复记录每次冷启动从空开始（`-CouliFakeOrdersKeepState` 时保留，截进程恢复用）
        if !arguments.contains("-CouliFakeOrdersKeepState") {
            UserDefaults.standard.removeObject(forKey: "orders.page_state")
            UserDefaults.standard.removeObject(forKey: "amount_mask.hidden")
            UserDefaults.standard.removeObject(forKey: "orders.push_row_used")
        }
        // APP-06b：购买场景（`-CouliFakeTradeLoggedIn` 冷启动直接是已登录的假账号，截购买流程用；假令牌不是凭据）。
        DebugFakeTrade.prepare(arguments: arguments)
        if arguments.contains(DebugFakeTrade.loggedInArgument) {
            try? tokens.save(
                access: fakeTradeAccess, refresh: "debug-rt-trade", scope: "full", account: "debug-fake-user",
                loginEpoch: keptEpoch ?? SessionLoginEpoch.make()
            )
            // APP-09（iOS R1-01）：未决记录默认保留（brief §0 第 3 条，冷启动照常恢复待确认）；只有截图 / 冒烟 UI 测试的夹具显式带
            // `-CouliFakeWalletResetPending` 时才清假账号的未决记录与金额草稿。
            DebugFakeWallet.prepareColdStart(arguments: arguments)
        }
        // 商品图走系统 AsyncImage（URLSession.shared）：只接管假图片主机（APP-06a 共性 22）。
        URLProtocol.registerClass(DebugFakeSearchImages.self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DebugFakeLoginServer.self]
        return configuration
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    private let stoppedLock = NSLock()
    private nonisolated(unsafe) var stopped = false

    override func startLoading() {
        let path = request.url?.path ?? ""
        var query: [String: String] = [:]
        for item in URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?
            .queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let body = Self.object(Self.bodyData(request))
        // APP-12：「我的」场景（DebugFakeMe）先于其他场景：Me、申诉、同意记录、推送令牌、配置（kf 与 AI 公示），封禁场景下白名单外回 10006。
        if let me = DebugFakeMe.shared.answer(method: request.httpMethod ?? "GET", path: path, body: body) {
            answerOrders(.answer(code: me.code, data: me.data, headers: [:], delay: 0.3))
            return
        }
        // APP-05b：第三方登录与绑手机（DebugFakeOAuth）；「响应丢失」按传输失败结束（结果未知 → 待确认）。
        if let oauth = DebugFakeOAuth.shared.answer(method: request.httpMethod ?? "GET", path: path, body: body) {
            answerOrders(oauth.lost ? .offline : .answer(code: oauth.code, data: oauth.data, headers: oauth.headers,
                                                         delay: 0.3))
            return
        }
        // APP-09：钱包场景（DebugFakeWallet）先于其他场景；offline 与「响应丢失」按传输失败结束。
        if let wallet = DebugFakeWallet.shared.answer(
            method: request.httpMethod ?? "GET", path: path, query: query, body: body,
            headers: request.allHTTPHeaderFields ?? [:]
        ) {
            answerWallet(wallet)
            return
        }
        // APP-08：订单场景（DebugFakeOrders）先于其他场景；offline 开关时按传输失败结束（断网演示）。
        if let orders = DebugFakeOrders.answer(method: request.httpMethod ?? "GET", path: path, query: query) {
            answerOrders(orders)
            return
        }
        // APP-06b：购买场景（DebugFakeTrade）先于搜索与详情。
        let trade = DebugFakeTrade.answer(path: path, query: query, request: request, body: body)
        // APP-06a：搜索与详情场景（DebugFakeSearch）。
        // APP-07：剪贴板 parse（DebugFakeSearch.parse）。
        let search = trade == nil
            ? (path == "/v1/inputs/parse" ? DebugFakeSearch.parse(body) : DebugFakeSearch.answer(
                path: path,
                query: query
            ))
            : nil
        let reply = trade.map { Reply(code: $0.code, data: $0.data, headers: $0.headers) }
            ?? search.map { Reply(code: $0.code, data: $0.data, headers: $0.headers) }
            ?? homeOrDefault(path: path, body: body)
        let (code, data, headers) = (reply.code, reply.data, reply.headers)
        let trace = search?.traceId ?? (trade != nil ? "0199a3b4-5c6d-7e8f-9a0b-1c2d3e5d81a7" : "debug-fake-000000")
        let text = "{\"code\":\(code),\"msg\":\"\",\"data\":\(data),\"trace_id\":\"\(trace)\"}"
        let url = request.url ?? URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(
            url: url, statusCode: code == 0 ? 200 : 400, httpVersion: "HTTP/1.1", headerFields: headers
        )
        // 略等一下，界面上能看到加载态。被 ApiClient 取消（换条件、离开页面）的请求不再回答。
        DispatchQueue.global().asyncAfter(deadline: .now() + (trade?.delay ?? search?.delay ?? 0.3)) { [self] in
            guard !stoppedLock.withLock({ stopped }) else { return }
            client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func homeOrDefault(path: String, body: [String: Any]) -> Reply {
        DebugFakeHome.answer(request) ?? Self.answer(path: path, body: body)
    }

    private func answerWallet(_ reply: DebugFakeWallet.Reply) {
        switch reply {
        case .offline:
            answerOrders(.offline)
        case let .answer(code, data, headers):
            answerOrders(.answer(code: code, data: data, headers: headers, delay: 0.3))
        }
    }

    private func answerOrders(_ reply: DebugFakeOrders.Reply) {
        let url = request.url ?? URL(fileURLWithPath: "/")
        switch reply {
        case .offline:
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
                guard !stoppedLock.withLock({ stopped }) else { return }
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            }
        case let .answer(code, data, headers, delay):
            let trace = "0199a3b4-5c6d-7e8f-9a0b-1c2d3e6a2f19"
            let text = "{\"code\":\(code),\"msg\":\"\",\"data\":\(data),\"trace_id\":\"\(trace)\"}"
            let response = HTTPURLResponse(
                url: url, statusCode: code == 0 ? 200 : 400, httpVersion: "HTTP/1.1", headerFields: headers
            )
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                guard !stoppedLock.withLock({ stopped }) else { return }
                client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(text.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        stoppedLock.withLock { stopped = true }
    }

    private static let refreshed =
        "{\"access_token\":\"debug-at-2\",\"refresh_token\":\"debug-rt-2\",\"session_scope\":\"full\"}"

    static func answer(path: String, body: [String: Any]) -> Reply {
        switch path {
        case "/v1/devices":
            Reply(code: 0, data: "{\"device_id\":\"debug-fake-device\",\"install_secret\":\"debug-fake-placeholder\"}")
        case "/v1/config":
            Reply(code: 0, data: DebugFakeSearch.config())
        case "/v1/auth/sms-codes":
            sms(phone: body["phone"] as? String ?? "")
        case "/v1/auth/login/sms":
            login(body)
        case "/v1/auth/refresh":
            Reply(code: 0, data: refreshed)
        default:
            Reply(code: 0, data: "{}")
        }
    }

    private static func sms(phone: String) -> Reply {
        if phone == "13900000000" {
            return Reply(code: 42901, data: "{}", headers: ["Retry-After": "120"])
        }
        let repeated = lock.withLock { !sentPhones.insert(phone).inserted }
        if phone == "13700000000", repeated {
            return Reply(code: 42901, data: "{}", headers: ["Retry-After": "3600"])
        }
        return Reply(code: 0, data: "{\"resend_after_sec\":60,\"expires_in_sec\":300}")
    }

    private static let noAccount = "{\"reason\":\"no_account\",\"min_supported_version\":\"9.9.9\"}"

    private static func login(_ body: [String: Any]) -> Reply {
        switch body["code"] as? String ?? "" {
        case "200020": return Reply(code: 20002, data: "{}")
        case "200030": return Reply(code: 20003, data: "{}")
        case "444444": return Reply(code: 44001, data: "{}")
        case "100070": return Reply(code: 10007, data: "{\"stage\":\"processing\"}")
        case "104050": return Reply(code: 10405, data: noAccount)
        default: break
        }
        let scope = (body["phone"] as? String) == "13600000000" ? "deletion_only" : "full"
        var bind = ""
        if let invite = body["invite_code"] as? String {
            let valid = invite.count == 6 && invite.allSatisfy { "23456789ABCDEFGHJKLMNPQRSTUVWXYZ".contains($0) }
            bind = valid ? ",\"invite_bind\":{\"result\":\"bound\",\"code\":null}"
                : ",\"invite_bind\":{\"result\":\"failed\",\"code\":30401}"
        }
        let data = "{\"user_id\":\"debug-user\",\"is_new_user\":\(!bind.isEmpty),\"tokens\":{\"access_token\":"
            + "\"debug-at-1\",\"refresh_token\":\"debug-rt-1\",\"session_scope\":\"\(scope)\"}\(bind)}"
        return Reply(code: 0, data: data)
    }

    private static func bodyData(_ request: URLRequest) -> Data {
        if let data = request.httpBody {
            return data
        }
        guard let stream = request.httpBodyStream else { return Data() }
        var data = Data()
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        stream.close()
        return data
    }

    private static func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
#endif
