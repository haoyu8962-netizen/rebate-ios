import BridgeHost
import ClientCore
import CouliNetwork
import Foundation
import Generated
import Router
import UIKit

/// BridgeHost 的业务能力（APP-04 任务书 §2.2）：经 Router、ApiClient、Tracker、PermissionRequester 实现，不另造通道。
/// 没有接上的能力返回 90001，不臆造实现。
@MainActor
final class AppBridgeServices: BridgeServices {
    /// 10001 请先登录、10404 登录已过期：桥按未登录结束。
    private static let loginCodes: Set<Int> = [10001, 10404]
    private static let h5TokenFields: Set<String> = ["token", "expire_at", "scope"]

    private weak var web: AppWeb?
    /// 发起调用的网页容器（路由目的地 id）：clipboard.setAutoDetect 只对它生效（G06）。一致性页等没有路由目的地的为 nil。
    private let container: UUID?

    init(web: AppWeb, container: UUID? = nil) {
        self.web = web
        self.container = container
    }

    func env() -> [String: Any] {
        let identity = AppNetwork.identity
        return [
            "platform": ClientPlatform.ios.rawValue,
            "app_version": identity.appVersion,
            "build": identity.build,
            "os_version": UIDevice.current.systemVersion,
            "bridge_version": BridgeProtocol.contractVersion,
            // 容器内容区已经避开安全区（原生标题栏 + SwiftUI 安全区），页面区域里没有需要再让的部分。
            "safe_area": ["top": 0, "bottom": 0, "left": 0, "right": 0],
            "channel": identity.channel,
        ]
    }

    func config(keys: [String]) -> BridgeOutcome {
        .ok(["values": WebConfigReader.h5Values(configJson: web?.configJson ?? "{}", keys: keys)])
    }

    func user(validity: BridgeCallValidity) async -> BridgeOutcome {
        guard let client = web?.network.client else { return .fail(BridgeCode.nativeError) }
        let result = await client.send(ApiCall(operationId: "getMe"), isValid: { validity.isValid })
        guard case let .success(data, _, _) = result else { return Self.failure(result) }
        guard let me = data.flatMap({ (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }) else {
            return .fail(BridgeCode.nativeError)
        }
        return .ok(Self.userView(me))
    }

    /// 作用域由原生按强更状态决定（H5 不能选；三端共性第 6 条）；令牌不缓存、不落盘，只交给这次调用（03 §5.4）。
    func h5Token(readOnly: Bool, validity: BridgeCallValidity) async -> BridgeOutcome {
        guard let client = web?.network.client else { return .fail(BridgeCode.nativeError) }
        let body = #"{"scope":""# + (readOnly ? "read_only" : "standard") + #""}"#
        let result = await client.send(
            ApiCall(operationId: "issueH5Token", body: body), isValid: { validity.isValid }
        )
        guard case let .success(data, _, _) = result else { return Self.failure(result) }
        guard let token = data.flatMap({ (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }) else {
            return .fail(BridgeCode.nativeError)
        }
        return .ok(token.filter { Self.h5TokenFields.contains($0.key) })
    }

    func login() async -> BridgeOutcome {
        guard let web, let login = web.login else { return .fail(BridgeCode.nativeError) }
        let session = BridgeLoginSession.production(login: login) { [weak web] in
            web?.callerState(fromForceUpdatePage: false)
        }
        return await Self.login(router: web.routing.router, session: session)
    }

    /// auth.login（APP-04 共性 66，bridge.schema.json「Opens Login; resolves when the user finishes or leaves」）：经 Router
    /// 打开登录页，等这一页离开导航栈——登录成功（会话已保存，登录流程关闭登录页）→ logged_in=true；取消、返回、被清栈 →
    /// 按此刻有没有会话（通常 false）——再结算，不在打开登录页之前就返回。守卫没让打开（检查中、强更等）按 90500 结束。
    /// 是否打开了登录页看本次导航的实际结论与新推入的页面条目（按页面 id 绑定，共性 67），不比较路由状态有没有变化。
    /// 登录成功的结果绑定本次登录保存的会话归属键（共性 68）：BridgeHost 结算时允许这次登录造成的账号变化。
    /// 等待期间页面、隐私、环境的归属由 BridgeHost 负责：作废时取消执行它的 Task，这里随之结束等待（90500）。
    static func login(router: Router, session: BridgeLoginSession) async -> BridgeOutcome {
        let mark = session.mark()
        let decision = router.open(RouteRequest(route: RoutePolicy.login, from: .bridge))
        guard decision.kind == .open || decision.kind == .openReadonly,
              let page = router.path.last, page.route == RoutePolicy.login
        else {
            return .fail(BridgeCode.nativeError)
        }
        while router.path.contains(where: { $0.id == page.id }) {
            do {
                try await Task.sleep(nanoseconds: loginPollNanos)
            } catch {
                return .fail(BridgeCode.nativeError)
            }
        }
        guard !Task.isCancelled else { return .fail(BridgeCode.nativeError) }
        if let key = session.committedKey(mark) {
            return .ok(["logged_in": true], boundAccountKey: key)
        }
        return .ok(["logged_in": session.loggedIn()])
    }

    /// 等登录页离开导航栈的检查间隔。
    static let loginPollNanos: UInt64 = 100_000_000

    /// signed_paths 已在协议层核对；按 method + path 找 openapi 的签名接口，由 ApiClient 签名代发（03 §5.3 代发约定）。
    /// TODO(N-22)：openapi 9cd1e6f 没有 POST /v1/orders/claims，找不到时按「本端不支持」结束，不臆造请求（与 Android 相同）。
    func signedRequest(
        method: String,
        path: String,
        bodyJson: String?,
        validity: BridgeCallValidity
    ) async -> BridgeOutcome {
        guard let client = web?.network.client else { return .fail(BridgeCode.nativeError) }
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let bare = parts.first.map(String.init) ?? path
        guard let operation = ApiOperations.all.values.first(where: {
            $0.method == method && $0.pathTemplate == bare && $0.signed
        }) else {
            return .fail(BridgeCode.notSupported)
        }
        let query = parts.count > 1 ? String(parts[1]) : nil
        let result = await client.send(
            ApiCall(operationId: operation.operationId, query: query, body: bodyJson), isValid: { validity.isValid }
        )
        switch result {
        case let .success(data, traceId, _):
            return .ok(Self.envelope(code: 0, msg: "", data: data, traceId: traceId))
        case let .failure(code, msg, data, traceId, _, _):
            return .ok(Self.envelope(code: code, msg: msg, data: data, traceId: traceId))
        case .transportFailure:
            return .fail(BridgeCode.timeout)
        default:
            return .fail(BridgeCode.nativeError)
        }
    }

    /// nav.open：经 Router（来源 bridge，入口按 in_app 校验；强更未知时 Router 只开只读页面）。
    func navOpen(route: String, paramsJson: String, readOnlyPagesOnly: Bool) async -> BridgeOutcome {
        guard let web else { return .fail(BridgeCode.nativeError) }
        return Self.navOpen(
            router: web.routing.router, route: route, paramsJson: paramsJson, readOnlyPagesOnly: readOnlyPagesOnly
        )
    }

    /// nav.open 的路由部分（同步：Router 清栈与容器 teardown 都在这一段里发生，BridgeHost 据此先结算本次调用）。
    static func navOpen(router: Router, route: String, paramsJson: String, readOnlyPagesOnly: Bool) -> BridgeOutcome {
        let params = AppWeb.object(paramsJson) ?? [:]
        let decision = router.open(RouteRequest(
            route: route,
            params: params,
            source: RouteSource.bridge.rawValue
        ))
        // 守卫判为等待（检查中、环境未就绪等）：Router 不把桥请求放进启动队列，这次调用按取消结束（90500），之后也不补执行
        // （APP-04 共性 65）。
        if decision.kind == .deferred {
            return .fail(BridgeCode.nativeError)
        }
        let opened = decision.kind == .open || decision.kind == .openReadonly
        // 强更未知：只读页面以外的目标不打开，以 90500 结束（不新增码，03 §4.4）。
        if readOnlyPagesOnly, !opened {
            return .fail(BridgeCode.nativeError)
        }
        return .ok(["opened": opened])
    }

    /// 写剪贴板只经剪贴板模块的写入口（APP-07，brief §2.3）：先记 hash（之后不再识别它），记不上不写、返回失败（共性第 23 条）。
    func clipboardWrite(text: String) -> BridgeOutcome {
        guard let writer = web?.clipboard?.writer, writer.write(text) else { return .fail(BridgeCode.nativeError) }
        return .ok()
    }

    func clipboardRead() async -> BridgeOutcome {
        .ok(["text": UIPasteboard.general.string ?? ""])
    }

    /// 只对发起调用的这个网页容器实例生效的临时抑制（APP-07 G06）：容器在栈顶时回前台不识别，容器出栈即失效；不写本机存储、不改设置。
    /// 旧版写进 UserDefaults 的 couli.clipboard.autoDetect 不再读也不再写。
    func setClipboardAutoDetect(enabled: Bool) -> BridgeOutcome {
        web?.clipboard?.setWebAutoDetect(container: container, enabled: enabled)
        return .ok()
    }

    func pushStatus() async -> BridgeOutcome {
        await .ok(["enabled": PermissionSystem.status("push") == PermissionStatusRaw.granted])
    }

    /// perm.request 只走 PermissionRequester（03 §4.9）。
    func requestPermission(type: String, isStillValid: @escaping @MainActor () -> Bool) async -> BridgeOutcome {
        guard let permissions = web?.permissions else { return .fail(BridgeCode.nativeError) }
        let result = await permissions.request(type, isValid: { MainActor.assumeIsolated { isStillValid() } })
        // 调用在途中失效：不交回结果（宿主结算时同样按归属失效回 90500）。
        guard result.resultRaw != PermissionResultRaw.cancelled else { return .fail(BridgeCode.nativeError) }
        return .ok(["granted": result.granted])
    }

    /// 只接受 Tracker 生成函数里给 H5 的事件（字段待定的页面类事件，props 暂不带）；其余丢弃。TODO(N-22)：H5 可报事件清单。
    func track(name: String) -> BridgeOutcome {
        if let make = Self.h5Events[name] {
            web?.tracker.track(make(AppWeb.page))
        }
        return .ok()
    }

    func reportRejected(method: String, code: Int) {
        web?.tracker.track(TrackerEvents.bridgeCall(page: AppWeb.page, method: method, code: code))
    }

    private static let h5Events: [String: (String) -> TrackEvent] = [
        "page_view": { TrackerEvents.pageView(page: $0) },
        "exposure": { TrackerEvents.exposure(page: $0) },
        "click": { TrackerEvents.click(page: $0) },
        "search": { TrackerEvents.search(page: $0) },
        "convert": { TrackerEvents.convert(page: $0) },
        "h5_white_screen": { TrackerEvents.h5WhiteScreen(page: $0) },
    ]

    private static func failure(_ result: ApiResult) -> BridgeOutcome {
        switch result {
        case let .failure(code, _, _, _, _, _):
            .fail(loginCodes.contains(code) ? BridgeCode.notLoggedIn : BridgeCode.nativeError)
        case .transportFailure:
            .fail(BridgeCode.timeout)
        default:
            .fail(BridgeCode.nativeError)
        }
    }

    /// getMe → auth.getUser 的 result（不带任何令牌，BR-ID-32）。
    static func userView(_ me: [String: Any]) -> [String: Any] {
        var bindings: [String: String] = [:]
        for item in me["union_bindings"] as? [Any] ?? [] {
            if let row = item as? [String: Any], let platform = row["platform"] as? String,
               let status = row["status"] as? String {
                bindings[platform] = status
            }
        }
        return [
            "uid": me["user_id"] as? String ?? "",
            "nickname": me["nickname"] as? String ?? "",
            "avatar": me["avatar_url"] as? String ?? "",
            "phone_bound": (me["phone_bound"] as? Bool) ?? false,
            "realname_status": me["realname_status"] as? String ?? "none",
            "bindings": ["taobao": bindings["taobao"] ?? "unbound", "pdd": bindings["pdd"] ?? "unbound"],
        ]
    }

    /// TODO(N-22)：ApiClient 不暴露 HTTP 状态；拿到统一外壳时按 200 交回，业务码看 body.code（03 §5.3）。
    private static func envelope(code: Int, msg: String, data: Data?, traceId: String?) -> [String: Any] {
        var body: [String: Any] = ["code": code, "msg": msg]
        if let data, let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            body["data"] = value
        }
        if let traceId {
            body["trace_id"] = traceId
        }
        return ["status": 200, "body": body]
    }
}

/// 桥 auth.login 认定「本次登录」用的会话出口（APP-04 共性 68）。
@MainActor
struct BridgeLoginSession {
    /// 打开登录页前记下的登录提交序号（LoginService.commitMark）。
    let mark: @MainActor () -> UInt64
    /// `since` 之后有登录保存了会话，且此刻仍是那次保存的会话：返回它的归属键；否则 nil。
    let committedKey: @MainActor (_ since: UInt64) -> String?
    /// 此刻有没有会话（没有完成本次登录时的 logged_in）。
    let loggedIn: @MainActor () -> Bool

    /// 生产取值：LoginService 记下的登录提交（保存后的会话世代由 ApiClient 在保存那把锁里给出），与调用方状态的归属键对照。
    static func production(
        login: AppLogin,
        caller: @escaping @MainActor () -> BridgeCallerState?
    ) -> BridgeLoginSession {
        BridgeLoginSession(
            mark: { [weak login] in login?.service.commitMark ?? 0 },
            committedKey: { [weak login] since in
                guard let login, let commit = login.service.lastCommit, commit.serial > since,
                      let key = caller()?.accountKey,
                      key == AppWeb.accountKey(account: login.account, generation: commit.generation)
                else {
                    return nil
                }
                return key
            },
            loggedIn: { caller()?.accountKey != nil }
        )
    }
}
