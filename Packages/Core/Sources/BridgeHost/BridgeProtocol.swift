import Foundation
import Generated

/// 桥错误码（contracts/bridge.schema.json errors；含义原文见 `BridgeProtocol.message`）。
public enum BridgeCode {
    public static let ok = 0
    public static let notSupported = 90001
    public static let invalidParams = 90002
    public static let timeout = 90003
    public static let cancelled = 90004
    public static let notLoggedIn = 90401
    public static let notAllowed = 90403
    public static let gestureMissing = 90404
    public static let nativeError = 90500
}

/// 隐私状态的 raw（与 Router 的 PrivacyState 同名取值）。
public enum BridgePrivacy {
    public static let consented = "consented"
    public static let basicMode = "basic_mode"
    public static let notDecided = "not_decided"
}

/// 一次信封解析（三端测试接线约定）：`valid` 为假时 `errorCode` 为 90002；未知方法名能通过结构校验（由 `decide` 返回 90001）；
/// 缺省 params 为 {}。`structureValid` 只看信封结构，宿主按 login → gesture → params 的顺序判定时用它。
public struct EnvelopeParse {
    public let valid: Bool
    public let errorCode: Int?
    public let method: String?
    public let id: String?
    public let params: [String: Any]?
    public let structureValid: Bool
}

/// 一次调用的判定输入（三端测试接线约定）。`privacy` 取 `BridgePrivacy`；origin、isMainFrame 来自传输层，userGesture 来自原生记录的点击。
public struct BridgeContext {
    public let method: String
    public let origin: String
    public let isMainFrame: Bool
    public let userGesture: Bool
    public let privacy: String
    public let loggedIn: Bool
    public let params: [String: Any]

    public init(
        method: String,
        origin: String,
        isMainFrame: Bool,
        userGesture: Bool,
        privacy: String,
        loggedIn: Bool,
        params: [String: Any]
    ) {
        self.method = method
        self.origin = origin
        self.isMainFrame = isMainFrame
        self.userGesture = userGesture
        self.privacy = privacy
        self.loggedIn = loggedIn
        self.params = params
    }
}

/// 判定结果：放行时 errorCode 为 nil。
public struct BridgeDecision: Sendable, Equatable {
    public let allow: Bool
    public let errorCode: Int?

    public static let allowed = BridgeDecision(allow: true, errorCode: nil)

    public static func deny(_ code: Int) -> BridgeDecision {
        BridgeDecision(allow: false, errorCode: code)
    }
}

/// JSBridge 协议的纯逻辑（03 §5.2、§5.3；contracts/bridge.schema.json）：信封校验、级别判定、白名单、事件白名单与标准响应体。
/// 没有 WebKit 依赖，配置全部由构造参数注入（不读生产域与全局状态）。
///
/// `decide` 的判定顺序（同一处判定，H5 不能绕开）：
/// 1. origin 与框架：只认白名单里的完整 origin（https、主机转小写逐字相等、不通配子域、443 规范化）且是主框架，否则 90403；
///    `extraOriginAllowed` 只给 Debug 构建的本机一致性测试源与测试夹具用（Release 传 nil，回环判定的代码不在包里）；
/// 2. 方法：契约里没有的（含 not_exposed 的类别标签、大小写不同的名字）90001；
/// 3. 隐私：未同意或基本模式时只放行 `privacyLimitedMethods`。TODO(N-22)：契约没有逐方法的基本模式白名单，也没有隐私拒绝
///    专用的桥码；这里保守地只放行不读写账号、不外跳、不发写请求的方法，拒绝暂用 90403；
/// 4. 级别：L1、L2 未登录 90401；
/// 5. 手势：L2 与 gesture_required 缺最近 1 秒内的用户点击 90404；
/// 6. 参数：不符合方法的 params schema 90002（cases.ts：login → gesture → params）；
/// 7. 方法自身的白名单（whitelist_90403）：net.signedRequest 的 signed_paths、ext.openApp 的 trade_only 目标、
///    ext.openBrowser 命中链接形态表、share.open 的链接范围，命中即 90403。
///
/// 只是协议准入：since、强更守卫、能力是否实现由宿主（`BridgeHost`）另判。
public struct BridgeProtocol: Sendable {
    private let trusted: Set<String>
    private let extraOriginAllowed: (@Sendable (String) -> Bool)?
    private let patterns: LinkPatterns
    private let shareHosts: Set<String>

    public init(
        trustedOrigins: [String],
        linkPatterns: [String: Any],
        shareDomains: [String],
        extraOriginAllowed: (@Sendable (String) -> Bool)? = nil
    ) {
        trusted = Set(trustedOrigins.compactMap(Self.normalizeOrigin))
        patterns = LinkPatterns.parse(linkPatterns) ?? .empty
        shareHosts = Set(shareDomains.map(Self.normalizeHost))
        self.extraOriginAllowed = extraOriginAllowed
    }

    /// origin（传输层给出的 `scheme://host[:port]`）是否可信：白名单，或调试注入的额外判定。
    public func isTrustedOrigin(_ origin: String) -> Bool {
        if let normalized = Self.normalizeOrigin(origin), trusted.contains(normalized) {
            return true
        }
        return extraOriginAllowed?(origin) ?? false
    }

    public func decide(ctx: BridgeContext) -> BridgeDecision {
        guard ctx.isMainFrame, isTrustedOrigin(ctx.origin) else {
            return .deny(BridgeCode.notAllowed)
        }
        guard let method = BridgeContract.shared.methods[ctx.method] else {
            return .deny(BridgeCode.notSupported)
        }
        if ctx.privacy != BridgePrivacy.consented, !Self.privacyLimitedMethods.contains(method.name) {
            return .deny(BridgeCode.notAllowed)
        }
        if method.needsLogin, !ctx.loggedIn {
            return .deny(BridgeCode.notLoggedIn)
        }
        if method.needsGesture, !ctx.userGesture {
            return .deny(BridgeCode.gestureMissing)
        }
        if !Self.paramsValid(method, ctx.params) {
            return .deny(BridgeCode.invalidParams)
        }
        if !methodAllowListAllows(method.name, ctx.params) {
            return .deny(BridgeCode.notAllowed)
        }
        return .allowed
    }

    /// ext.openBrowser、share.open 共用的地址判定：规范化后命中链接形态表任一类别即拒绝（BR-ATTR-29）。
    public func linkAllowedForBrowser(_ url: String) -> Bool {
        guard let normalized = NormalizedURL.parse(url) else { return false }
        return patterns.matches(normalized).isEmpty
    }

    private func methodAllowListAllows(_ method: String, _ params: [String: Any]) -> Bool {
        switch method {
        case "net.signedRequest":
            Self.signedPathAllowed(
                method: JSONKind.string(params, "method") ?? "", path: JSONKind.string(params, "path") ?? ""
            )
        case "ext.openApp":
            !BridgeAppTargets.tradeOnly.contains(JSONKind.string(params, "target") ?? "")
        case "ext.openBrowser":
            linkAllowedForBrowser(JSONKind.string(params, "url") ?? "")
        case "share.open":
            shareAllowed(params["content"] as? [String: Any])
        default:
            true
        }
    }

    /// share.open（BR-ATTR-29 细则，判定顺序固定、每步即终）：只判 content.type=link；规范化失败、非 https、带用户信息 → 拒绝；
    /// ① 命中链接形态表任一类别 → 拒绝；② 主机在 share_domains（整主机相等）→ 只放行分享页路径，非默认端口或其他路径拒绝
    /// （share_page_paths 目前全为 null，TODO(N-22)：分享域上一律拒绝）；③ 其他 https 放行。
    private func shareAllowed(_ content: [String: Any]?) -> Bool {
        guard let content, JSONKind.string(content, "type") == "link" else { return true }
        guard let url = NormalizedURL.parse(JSONKind.string(content, "url") ?? "") else { return false }
        if !patterns.matches(url).isEmpty {
            return false
        }
        if shareHosts.contains(url.host) {
            return url.port == nil && BridgeContract.shared.sharePagePatterns.contains { regex in
                regex.firstMatch(in: url.path, range: NSRange(url.path.startIndex..., in: url.path)) != nil
            }
        }
        return true
    }

    // MARK: - 静态入口（三端测试接线约定）

    /// 未同意或基本模式下放行的方法（TODO(N-22)，保守）：环境与公开配置、容器自身的界面、打开 / 关闭页面（目标页由 Router 按
    /// 基本模式守卫，03 §4.4）、预览图片、只读的推送权限状态。不放行登录、令牌、代发、剪贴板、埋点、外跳、分享与权限申请。
    public static let privacyLimitedMethods: Set<String> = [
        "app.getEnv", "app.getConfig", "ui.toast", "ui.showLoading", "ui.hideLoading", "ui.setNavBar",
        "nav.open", "nav.close", "media.previewImage", "perm.getPushStatus",
    ]

    /// 桥契约版本（`__REBATE_BRIDGE__.version`、app.getEnv 的 bridge_version）。
    public static var contractVersion: Int {
        BridgeContract.shared.version
    }

    /// 契约里 since.ios 不为 null 的方法（`__REBATE_BRIDGE__.methods` 的口径，编排者三端裁定）。
    public static var declaredMethods: [String] {
        BridgeContract.shared.methods.values.filter { $0.sinceIOS != nil }.map(\.name).sorted()
    }

    /// 解析并校验信封（结构 + 已登记方法的参数）。非法输入不抛异常。
    public static func parseEnvelope(raw: String) -> EnvelopeParse {
        let structure = parseStructure(raw: raw)
        guard structure.structureValid, let name = structure.method else { return structure }
        if let method = BridgeContract.shared.methods[name], !paramsValid(method, structure.params ?? [:]) {
            return EnvelopeParse(
                valid: false, errorCode: BridgeCode.invalidParams, method: structure.method, id: structure.id,
                params: structure.params, structureValid: true
            )
        }
        return structure
    }

    /// 只校验信封结构（宿主先用它取 id 与 method，参数留到级别、手势之后再判）。
    public static func parseStructure(raw: String) -> EnvelopeParse {
        func invalid(id: String?) -> EnvelopeParse {
            EnvelopeParse(
                valid: false, errorCode: BridgeCode.invalidParams, method: nil, id: id, params: nil,
                structureValid: false
            )
        }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]))
            as? [String: Any]
        else { return invalid(id: nil) }
        let idText = root["id"] as? String
        let idOK = idText.map { !$0.isEmpty && $0.unicodeScalars.count <= 64 } ?? false
        let id = idOK ? idText : nil
        let version = JSONKind.number(root["v"])
        let versionOK = version.map { JSONKind.isInteger($0) && $0.doubleValue == 1 } ?? false
        let method = root["method"] as? String
        let params = root["params"]
        let keysOK = root.keys.allSatisfy(["v", "id", "method", "params"].contains)
        guard keysOK, versionOK, idOK, let method, !method.isEmpty, params == nil || params is [String: Any] else {
            return invalid(id: id)
        }
        return EnvelopeParse(
            valid: true, errorCode: nil, method: method, id: id, params: params as? [String: Any] ?? [:],
            structureValid: true
        )
    }

    /// method + path（去掉查询串后的路径）逐字等于 signed_paths 的一项。
    public static func signedPathAllowed(method: String, path: String) -> Bool {
        let bare = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            ?? ""
        return BridgeContract.shared.signedPaths.contains { $0.method == method && $0.path == bare }
    }

    /// 事件名在契约 events 里（逐字匹配）。
    public static func eventAllowed(name: String) -> Bool {
        BridgeContract.shared.events.contains(name)
    }

    /// 方法名在契约里（大小写敏感）。
    public static func isContractMethod(_ name: String) -> Bool {
        BridgeContract.shared.methods[name] != nil
    }

    /// 错误码的含义原文（契约 errors）；成功为空串。
    public static func message(_ code: Int) -> String {
        code == BridgeCode.ok ? "" : BridgeContract.shared.errors[code] ?? ""
    }

    /// 标准响应体：`{id, code, msg, data?}`（JSON 文本）。
    public static func response(id: String, code: Int, data: [String: Any]? = nil) -> String {
        var body: [String: Any] = ["id": id, "code": code, "msg": message(code)]
        if let data {
            body["data"] = data
        }
        return JSONKind.encode(body) ?? #"{"id":"","code":90500,"msg":""}"#
    }

    /// 标准事件体 `{event, data}`；不在 events 白名单里的为 nil（不下发）。
    public static func event(name: String, data: [String: Any] = [:]) -> String? {
        guard eventAllowed(name: name) else { return nil }
        return JSONKind.encode(["event": name, "data": data])
    }

    static func paramsValid(_ method: BridgeMethodContract, _ params: Any) -> Bool {
        JSONSchemaLite(defs: BridgeContract.shared.defs).valid(params, schema: method.params)
    }

    /// 完整 https origin 的规范化：`https://host[:port]`，主机转小写、去末尾点，默认端口去掉；带路径（除单个 /）、查询、片段、
    /// 用户信息的不是 origin。只认 https（03 §5.2）。
    public static func normalizeOrigin(_ origin: String) -> String? {
        guard let components = URLComponents(string: origin.trimmingCharacters(in: .whitespaces)),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let rawHost = components.host
        else { return nil }
        let host = normalizeHost(rawHost)
        guard !host.isEmpty else { return nil }
        let port = components.port.flatMap { $0 == 443 ? nil : $0 }
        return port.map { "https://\(host):\($0)" } ?? "https://\(host)"
    }

    static func normalizeHost(_ host: String) -> String {
        var value = host.lowercased()
        while value.hasSuffix(".") {
            value.removeLast()
        }
        return value
    }
}
