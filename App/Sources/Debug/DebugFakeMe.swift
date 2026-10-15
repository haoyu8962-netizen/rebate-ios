#if DEBUG
import CouliNetwork
import Foundation
import MeCore

/// 「我的」本机假服务（APP-12 截图、冒烟与设计稿比对用；只在 Debug / Staging 编译，APP-04 共性 2）。由 `DebugFakeLoginServer`（启动参数
/// `-CouliFakeLoginServer`）接管时回答；Release 制品扫描查 `marker` 与类型名。全部在本机回答，不连任何地址，不做真实账号操作。
/// 数据照设计稿 sample-data（凑狸用户、K7M3QX、可提现 ¥12.34、预估 ¥56.78、冻结至 2026-10-15 00:00）；客服链接与 AI 公示是明显的测试值。
///
/// 开关（启动参数 `-CouliFakeMe me=frozen,appeals=upheld,…`）：me=normal|frozen|frozen_appealing|banned|appealing|minor|unbound；
/// appeals=none|processing|upheld|revoked；reason=<类别>|none；until=none；wechat=no|yes；cs_open=fail；kf=none；filing=none；
/// guide=1（强制显示通知引导条，只给 MeHidden 截图）。banned / appealing 场景下白名单外接口回 10006（BR-ID-31）。
/// 改昵称、通知设置的待定 operation（G01、G02）只在进程内实现（`FakeNickname`、`FakeNotify`）：第 4 次改昵称回 30415，含 mingan 回
/// 20001 nickname_sensitive。
final class DebugFakeMe: @unchecked Sendable {
    static let marker = "COULI_FAKE_ME_SERVER_APP12_IOS_2b9e47"
    static let launchArgument = "CouliFakeMe"
    static let kfUrl = "https://kf.example.invalid/kfid/debug-test"
    static let filing = "测试模型名称\n测试登记编号：TEST-0000"
    static let shared = DebugFakeMe()

    let lock = NSLock()
    var nickname = "凑狸用户"
    var renames = 0
    var appeals: [[String: Any]]?
    var service = true
    var serial = 0

    var options: [String: String] {
        var out: [String: String] = [:]
        for part in (UserDefaults.standard.string(forKey: Self.launchArgument) ?? "").split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            out[pair[0]] = pair.count == 2 ? pair[1] : "1"
        }
        return out
    }

    /// BR-ID-31 细则：封禁期间只能调的接口（白名单）；其余回 10006。
    static let allowedPaths: [String] = [
        "/v1/me", "/v1/me/appeals", "/v1/withdrawals", "/v1/auth/logout", "/v1/config", "/v1/devices",
        "/v1/auth/refresh", "/v1/consents", "/v1/devices/push-token",
    ]

    /// 回答「我的」类路径（与封禁时的白名单外拦截）；不是本服务的为 nil。
    func answer(method: String, path: String, body: [String: Any]) -> (code: Int, data: String)? {
        let state = options
        let banned = state["me"] == "banned" || state["me"] == "appealing"
        if banned, !Self.allowedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return (10006, "null")
        }
        switch (method, path) {
        case ("GET", "/v1/me"):
            if DebugFakeWallet.shared.options["me"] == "5xxxx" {
                return (50001, "null")
            }
            return (0, Self.json(lock.withLock { me(state) }))
        case ("GET", "/v1/me/appeals"):
            return (0, Self.json(["items": lock.withLock { appealList(state) }, "next_cursor": NSNull()]))
        case ("POST", "/v1/me/appeals"):
            return (0, Self.json(lock.withLock { submit(body) }))
        case ("POST", "/v1/consents"), ("POST", "/v1/devices/push-token"), ("DELETE", "/v1/me/tips/jump_tip"):
            return (0, "{}")
        case ("GET", "/v1/config"):
            return (0, config(state))
        default:
            return nil
        }
    }

    private func me(_ state: [String: String]) -> [String: Any] {
        let scenario = state["me"] ?? "normal"
        let riskState = switch scenario {
        case "frozen": "frozen"
        case "banned": "banned"
        case "appealing", "frozen_appealing": "appealing"
        default: "normal"
        }
        let reason: Any = riskState == "normal" || state["reason"] == "none" ? NSNull()
            : (state["reason"] ?? (scenario.hasPrefix("frozen") ? "abnormal_trade" : "malicious_rights"))
        let until: Any = riskState == "frozen" && state["until"] != "none" ? "2026-10-15T00:00:00+08:00" : NSNull()
        let realname = DebugFakeWallet.shared.realname(DebugFakeWallet.shared.options)
        return [
            "user_id": "debug-user", "nickname": nickname, "avatar_url": "https://example.invalid/default.png",
            "invite_code": scenario == "minor" ? NSNull() : "K7M3QX", "inviter_bound": scenario != "unbound",
            "invite_backfill": ["eligible": false, "deadline_at": NSNull()], "identity_level": "phone",
            "phone_bound": DebugFakeOAuth.shared.phoneBound,
            "balance": ["available_fen": 1234, "withdrawable_fen": 1234, "estimated_total_fen": 5678],
            "union_bindings": [], "realname_status": realname ? "verified" : "none", "need_reconsent": false,
            "risk": ["state": riskState, "reason_category": reason, "frozen_until": until],
        ]
    }

    private func appealList(_ state: [String: String]) -> [[String: Any]] {
        if let appeals {
            return appeals
        }
        switch state["appeals"] {
        case "processing": return [appeal("processing", closed: false)]
        case "upheld": return [appeal("upheld", closed: true)]
        case "revoked": return [appeal("revoked", closed: true)]
        default: return []
        }
    }

    private func appeal(_ status: String, closed: Bool, content: String = "测试申诉，请核查。") -> [String: Any] {
        [
            "appeal_id": "debug-AP1", "target_type": "account", "target_id": NSNull(), "status": status,
            "content": content, "created_at": "2026-10-10T10:00:00+08:00",
            "closed_at": closed ? "2026-10-11T15:00:00+08:00" : NSNull(),
        ]
    }

    /// 处理中再次提交返回原单（BR-ID-36）。
    private func submit(_ body: [String: Any]) -> [String: Any] {
        if let processing = appealList(options).first(where: { $0["status"] as? String == "processing" }) {
            return processing
        }
        serial += 1
        let created = appeal("processing", closed: false, content: body["content"] as? String ?? "")
        appeals = [created]
        return created
    }

    private func config(_ state: [String: String]) -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(DebugFakeSearch.config().utf8)))
            as? [String: Any]
        else { return DebugFakeSearch.config() }
        if state["kf"] != "none" {
            object["kf"] = ["url": Self.kfUrl]
        }
        var agent = object["agent"] as? [String: Any] ?? [:]
        agent["filing_text"] = state["filing"] == "none" ? "" : Self.filing
        object["agent"] = agent
        return Self.json(object)
    }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "null" }
        return String(bytes: data, encoding: .utf8) ?? "null"
    }

    /// 截图用：强制显示通知引导条（Release 只按真实条件）。
    var forceGuideBar: Bool {
        options["guide"] == "1"
    }

    /// 微信已装（截图用：wechat=no 显示 CsWechatMissing；不设为 unknown）。
    var wechat: String? {
        options["wechat"]
    }

    var openFails: Bool {
        options["cs_open"] == "fail"
    }

    /// 把假服务接到 App（只在假登录服务打开时）：改昵称、通知设置的待定 operation 后端、微信与拉起结果的截图开关。
    @MainActor
    static func backends(arguments: [String] = ProcessInfo.processInfo.arguments)
        -> (nickname: NicknameBackend?, notify: NotifyBackend?) {
        guard arguments.contains(DebugFakeLoginServer.launchArgument) else { return (nil, nil) }
        return (FakeNickname(fake: shared), FakeNotify(fake: shared))
    }
}

/// 改昵称的假后端（G01 待定 operation updateNickname，只在进程内）。
final class FakeNickname: NicknameBackend, @unchecked Sendable {
    let fake: DebugFakeMe

    init(fake: DebugFakeMe) {
        self.fake = fake
    }

    func save(nickname: String, owner _: RequestOwnership?,
              allowed: @escaping @Sendable () -> Bool) async -> ApiResult {
        guard allowed() else { return .localReject(reason: LocalRejectReason.sendBlocked) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return fake.lock.withLock {
            if nickname.contains("mingan") || nickname.contains("敏感") {
                return .failure(
                    code: 20001,
                    msg: "",
                    data: Data(#"{"reason":"nickname_sensitive","fields":["nickname"]}"#.utf8),
                    traceId: nil,
                    effect: ErrorEffect(code: 20001, kind: .fieldError),
                    idempotencyKey: nil
                )
            }
            guard fake.renames < 3 else {
                return .failure(
                    code: 30415,
                    msg: "",
                    data: nil,
                    traceId: nil,
                    effect: ErrorEffect(code: 30415, kind: .toast),
                    idempotencyKey: nil
                )
            }
            fake.renames += 1
            fake.nickname = nickname
            return .success(data: Data("{}".utf8), traceId: nil, idempotencyKey: nil)
        }
    }
}

/// 服务类推送开关的假后端（G02 待定 operation，只在进程内）。
final class FakeNotify: NotifyBackend, @unchecked Sendable {
    let fake: DebugFakeMe

    init(fake: DebugFakeMe) {
        self.fake = fake
    }

    func get(owner _: RequestOwnership?, allowed: @escaping @Sendable () -> Bool) async -> ApiResult {
        guard allowed() else { return .localReject(reason: LocalRejectReason.sendBlocked) }
        let on = fake.lock.withLock { fake.service }
        return .success(data: Data(#"{"service":\#(on)}"#.utf8), traceId: nil, idempotencyKey: nil)
    }

    func put(service: Bool, owner _: RequestOwnership?, allowed: @escaping @Sendable () -> Bool) async -> ApiResult {
        guard allowed() else { return .localReject(reason: LocalRejectReason.sendBlocked) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        fake.lock.withLock { fake.service = service }
        return .success(data: Data("{}".utf8), traceId: nil, idempotencyKey: nil)
    }
}
#endif

#if DEBUG
/// 截图与冒烟用的系统能力替身（只在假登录服务打开时套在 IOSMeSystem 外面）：微信已装 / 未装、拉起失败、强制引导条（Debug 状态，Release 没有）。
@MainActor
final class DebugMeSystem: MeSystemPorts {
    let base: MeSystemPorts
    let fake = DebugFakeMe.shared

    init(base: MeSystemPorts) {
        self.base = base
    }

    static func wrap(_ base: MeSystemPorts, arguments: [String] = ProcessInfo.processInfo.arguments) -> MeSystemPorts {
        arguments.contains(DebugFakeLoginServer.launchArgument) ? DebugMeSystem(base: base) : base
    }

    func permissionStatus(_ type: String) async -> String {
        if type == "push", fake.forceGuideBar {
            return "permanently_denied"
        }
        return await base.permissionStatus(type)
    }

    func permissionDeniedAt(_ type: String) -> Int64? {
        if type == "push", fake.forceGuideBar {
            return Int64(Date().timeIntervalSince1970 * 1000) - 72 * 3_600_000
        }
        return base.permissionDeniedAt(type)
    }

    func openNotificationSettings() {
        base.openNotificationSettings()
    }

    func openAppSettings() {
        base.openAppSettings()
    }

    func openExternal(_ url: String) async -> Bool {
        if fake.openFails {
            return false
        }
        return await base.openExternal(url)
    }

    func wechatInstalled() -> String {
        fake.wechat ?? base.wechatInstalled()
    }

    func cacheBytes() async -> Int64? {
        await base.cacheBytes()
    }

    func clearCache() async -> Bool {
        await base.clearCache()
    }

    func osVersion() -> String? {
        base.osVersion()
    }

    func model() -> String? {
        base.model()
    }
}
#endif
