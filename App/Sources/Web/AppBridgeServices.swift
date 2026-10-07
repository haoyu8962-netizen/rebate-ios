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
    private static let clipboardAutoDetectKey = "couli.clipboard.autoDetect"
    /// 10001 请先登录、10404 登录已过期：桥按未登录结束。
    private static let loginCodes: Set<Int> = [10001, 10404]
    private static let h5TokenFields: Set<String> = ["token", "expire_at", "scope"]

    private weak var web: AppWeb?

    init(web: AppWeb) {
        self.web = web
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

    /// TODO(APP-05)：登录页完成或离开时再结算；现在只打开登录占位路由，按当时的会话返回。
    func login() async -> BridgeOutcome {
        guard let web else { return .fail(BridgeCode.nativeError) }
        web.routing.router.open(RouteRequest(route: RoutePolicy.login, from: .bridge))
        return .ok(["logged_in": web.callerState(fromForceUpdatePage: false).accountKey != nil])
    }

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
        let opened = decision.kind == .open || decision.kind == .openReadonly
        // 强更未知：只读页面以外的目标不打开，以 90500 结束（不新增码，03 §4.4）。
        if readOnlyPagesOnly, !opened {
            return .fail(BridgeCode.nativeError)
        }
        return .ok(["opened": opened])
    }

    /// TODO(APP-09)：剪贴板识别模块接入后记下文本哈希、之后不再识别它（03 §4.6）。
    func clipboardWrite(text: String) -> BridgeOutcome {
        UIPasteboard.general.string = text
        return .ok()
    }

    func clipboardRead() async -> BridgeOutcome {
        .ok(["text": UIPasteboard.general.string ?? ""])
    }

    /// TODO(APP-09)：剪贴板自动识别的开关由识别模块读取；这里先只记下用户的选择（本机）。
    func setClipboardAutoDetect(enabled: Bool) -> BridgeOutcome {
        UserDefaults.standard.set(enabled, forKey: Self.clipboardAutoDetectKey)
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
