import ClientCore
import Combine
import CouliNetwork
import Foundation
import WalletCore

/// 页面、表单、执行器的固定身份（APP-09 第 39、52、63、65 条，brief §0「表单绑定账号与登录世代」）：身份档 + 账号 + 网络归属（账号、会话世代、
/// 作废世代）+ App 的身份键（隐私结论、撤回清理次数等）。每个页面执行器、表单在**构造时一次性**取得（`MeEnv.identity()`），之后对当前会话
/// 只做比较（`MeEnv.isCurrent`），不再赋值或绑定；请求携带 `request` 到网络层（`ApiClient.send(…expected:)` 只比较、不一致零发送）。
public struct MeIdentity: Equatable, Sendable {
    public let level: String
    public let account: String?
    public let request: RequestOwnership?
    /// App 侧身份键（身份档 + 账号 + 会话世代 + 作废世代 + 撤回 / 切环境清理次数）。
    public let key: String

    public init(level: String, account: String?, request: RequestOwnership?, key: String) {
        self.level = level
        self.account = account
        self.request = request
        self.key = key
    }

    /// 已登录（已同意且有可读会话）。
    public var member: Bool {
        level == MeLevel.member && account != nil
    }

    /// 测试与占位：不属于任何会话（永远不是当前）。
    public static let none = MeIdentity(level: MeLevel.basic, account: nil, request: nil, key: "-")
}

/// 「我的」类页面要的网络能力（生产为 ApiClient）：调用带请求归属（`isValid`，页面离开 / 换代时同步作废）、发送前闸门（`sendAllowed`，共享
/// 42901 禁用期，每次实际写出前核对）与固定的网络归属（`expected`）。
public protocol MeApi: AnyObject, Sendable {
    func send(
        _ call: ApiCall, isValid: @escaping @Sendable () -> Bool, sendAllowed: @escaping @Sendable () -> Bool,
        expected: RequestOwnership?
    ) async -> ApiResult
}

extension ApiClient: MeApi {}

/// 「我的」类页面要的环境（App 给；都在主线程调用）。`page` 是发起页的导航实例编号（RouteDestination.id，APP-09 第 50 条）。
@MainActor
public protocol MeEnv: AnyObject {
    /// 此刻的身份（一次读取）。只在执行器构造时调用。
    func identity() -> MeIdentity
    /// 固定身份仍是当前身份（只比较）。
    func isCurrent(_ identity: MeIdentity) -> Bool
    func check(_ identity: MeIdentity) -> IdentityCheck
    func recheckIdentity()
    /// 经 Router 以 App 内来源打开（路由名都在 routes.json）。`page` 是发起页（只在它仍在栈顶时打开，nil = Tab 根或不核对）。
    func open(_ route: String, params: [String: String], from page: UUID?)
    /// 经 APP-07 统一写入口写剪贴板（先记自写 hash 并确认落盘，记不下就不写）；返回是否写入。
    func copy(_ text: String) -> Bool
    /// /v1/config 的一项（生效配置：当前 → LKG → 包内）。
    func configObject(_ key: String) -> Any?
    /// 本端路由表里有、since 满足的路由（宫格裁剪，G31）。
    func availableRoutes() -> Set<String>
    /// 收益看板开关（features.flags earnings.dashboard.visible；G31，没有为 nil）。
    func earningsFlag() -> Bool?
    /// 统一客服出口（brief §2.9）。
    func customerService(from route: String)
    /// 系统权限的只读状态（PermissionRequester 同一套映射，不触发申请）：granted / permanently_denied / not_asked / unavailable。
    func permissionStatus(_ type: String) async -> String
    /// 本机记下的权限最近被拒时刻（PermissionRequester 只读；G28）。
    func permissionDeniedAt(_ type: String) -> Int64?
    /// 跳系统里本 App 的通知设置（不经 PermissionRequester 申请，不出系统授权框）。
    func openNotificationSettings()
    /// 跳系统里本 App 的设置页（系统权限一节的条目点击，不申请、不改节流）。
    func openAppSettings()
    /// 隐私中心「系统权限」一节：锁定契约 system-permissions.json 的 permissions（G26，生成物）。
    func permissionEntries() -> [[String: Any]]
    /// 基本模式【开启完整功能】：重新展示首启弹窗。
    func requestFullFunction()
    /// 强更 below_min 的受限上下文（03 §4.1「强更页的次要入口」）。
    func forceUpdateContext() -> Bool
    /// `identity` 在本次运行里是否因 10006 进入过 RiskNotice（G10；绑定触发时固定的身份，只比较）。
    func enteredBy10006(_ identity: MeIdentity) -> Bool
    /// 设备已注册（有 device_id；撤回同意的服务端记录要它，G25）。
    func deviceRegistered() -> Bool
    /// 本机已同意的隐私政策版本（撤回记录的 version，H12）；没有为 nil。
    func consentedPrivacyVersion() -> Int?
    /// /v1/config.legal.privacy.version（个性化记录的 version）；取不到用本机已同意版本（H12）。
    func legalPrivacyVersion() -> Int?
    /// 「清除缓存」：只算图片与网页缓存（AC-S1-137），字节；读不出为 nil。
    func cacheBytes() async -> Int64?
    /// 清除图片与网页缓存；返回清理动作是否都完成且没有 I/O 错误（不按清后的占用判定；清后大小另行重算、照实显示）。
    func clearCache() async -> Bool
    /// 关于页：版本名与构建号。
    var appVersion: String { get }
    var appBuild: String { get }
    /// 复制诊断信息的字段（G23；只取白名单内的项，Diagnostics 再过滤一次）。
    func diagnosticsFields() -> [String: Any]
    /// 【退出登录】确认之后（设置页、RiskNotice、申诉页）：只调已有 logout()（APP-05a），落点由 App 按发起实例判断（R1-09）。
    func logout(_ identity: MeIdentity, from page: UUID?)
    /// 隐私中心【确认撤回】：交给应用级协调器（不随页面出栈销毁，F-HM-24），本地撤回一定执行（G24）。
    func withdrawConsent(_ identity: MeIdentity)
    /// 关闭发起页（只关这一个导航实例，且它仍在栈顶，APP-09 第 50 条）；返回是否关了。
    func close(page: UUID) -> Bool
    /// 「重新显示下单须知」成功：下单须知的已读缓存推进世代（鸿蒙 R1-10）。
    func tipsReset()
    /// 本机时钟。
    func nowMillis() -> Int64
    /// 设置页剪贴板开关「打开 App 自动识别剪贴板」的当前值（设备级本机开关，BR-ID-16 2026-10-30；从未选择 = 开启）。
    func clipboardAutoOn() -> Bool
    /// 用户在设置页切换剪贴板开关：直接生效（不出弹层、不发请求，FU-X-CLIP-DEFAULT-ON C2、C3、C8）。
    func setClipboardAuto(_ on: Bool)
    /// 服务端校准后的时钟（显示用，BR-TEXT-11）。
    func displayNowMillis() -> Int64
}

/// 修改昵称（G01）：契约缺 PATCH /v1/me，手写的待定 operation updateNickname 只由 Debug 假服务实现；Release 为 nil（昵称行不可点、不发
/// 请求）。`owner` 是表单固定的网络归属、`allowed` 是执行层的发送前闸门（42901 禁用期），实现方在「发送」前核对。TODO(N-33) 契约补上后改真实接口。
public protocol NicknameBackend: AnyObject, Sendable {
    func save(nickname: String, owner: RequestOwnership?, allowed: @escaping @Sendable () -> Bool) async -> ApiResult
}

/// 服务类推送开关（G02）：契约缺 GET/PUT /v1/me/notification-settings，手写的待定 operation 只由 Debug 假服务实现；Release 为 nil（不显示开关
/// 行）。data：{service: boolean}（字段名按 04 代拟）。TODO(N-33)。
public protocol NotifyBackend: AnyObject, Sendable {
    func get(owner: RequestOwnership?, allowed: @escaping @Sendable () -> Bool) async -> ApiResult
    func put(service: Bool, owner: RequestOwnership?, allowed: @escaping @Sendable () -> Bool) async -> ApiResult
}

/// 会话级共享的几份 42901 禁用期（brief §0「Retry-After」：Me 读取一个、申诉提交一个、昵称一个、通知开关一个；另：撤回同意的服务端记录、
/// 个性化记录、重新显示下单须知各一个）。会话换代时整体 `reset`。`read` 是 getMe 的**全局唯一**截止时间（共性第 32、33 条）：App 把它同时
/// 交给钱包实名查询与桥 auth.getUser，三条路径共用、双向生效。
@MainActor
public final class MeGates {
    public let read: RetryAfterGate
    public let appeal: RetryAfterGate
    public let nickname: RetryAfterGate
    public let notify: RetryAfterGate
    public let consent: RetryAfterGate
    public let resetTip: RetryAfterGate

    public init(clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                read: RetryAfterGate? = nil) {
        self.read = read ?? RetryAfterGate(clock: clock)
        appeal = RetryAfterGate(clock: clock)
        nickname = RetryAfterGate(clock: clock)
        notify = RetryAfterGate(clock: clock)
        consent = RetryAfterGate(clock: clock)
        resetTip = RetryAfterGate(clock: clock)
    }

    public func reset() {
        for gate in [read, appeal, nickname, notify, consent, resetTip] {
            gate.reset()
        }
    }
}

/// 撤回同意进行中（应用级协调器发布，F-HM-24）：页面按它禁用其余操作；控制器重建后继承忙状态、完成前拒绝重复启动。
@MainActor
public final class MeWithdrawState: ObservableObject {
    @Published public var busy = false
    /// 本地撤回落盘失败（编号；nil = 没有）：在当前可见界面提示「撤回没有生效」并可重试（鸿蒙 R2-04）。
    @Published public var failed: Int?

    public init() {}
}

/// App 建一份、各页共用的依赖。
@MainActor
public final class MeDeps {
    public let api: MeApi
    /// App 的环境（弱引用：App 释放后——只在测试里会发生——一律按「不是当前身份」处理，在途任务的结算全部作废，不访问已释放的对象）。
    private weak var weakEnv: MeEnv?
    public var env: MeEnv {
        weakEnv ?? DetachedMeEnv.shared
    }

    public let gates: MeGates
    public let texts: MeTexts
    public let local: MeLocalStore?
    public let mask: AmountMaskStore?
    public let nickname: NicknameBackend?
    public let notify: NotifyBackend?
    public let withdraw: MeWithdrawState
    public var newKey: () -> String = { UUID().uuidString.lowercased() }
    /// 「我的」与设置共用的 Me 快照（会话级）。
    public private(set) lazy var repo = MeRepository(deps: self)

    public init(
        api: MeApi, env: MeEnv, gates: MeGates, texts: MeTexts = MeDraftTexts(), local: MeLocalStore?,
        mask: AmountMaskStore?, nickname: NicknameBackend?, notify: NotifyBackend?,
        withdraw: MeWithdrawState = MeWithdrawState()
    ) {
        self.api = api
        weakEnv = env
        self.gates = gates
        self.texts = texts
        self.local = local
        self.mask = mask
        self.nickname = nickname
        self.notify = notify
        self.withdraw = withdraw
    }
}

/// 一次性的确认框 / 半屏编号（Android R1-02，共性第 20 条）：每次打开生成新编号；确认、取消只认「当前正显示的这一个」（类型与编号都相同），
/// 用过或被取消即作废，旧闭包重放一律不生效。
public struct MeDialog: Equatable, Sendable {
    public let kind: String
    public let id: Int

    public init(kind: String, id: Int) {
        self.kind = kind
        self.id = id
    }
}

/// 页面上的一条提示：文案键 + 编号（只播报一次）；5xxxx 带 trace6。
public struct MeNotice: Equatable, Sendable {
    public let key: String
    public let id: Int
    public let traceId: String?
    public let showTrace6: Bool
    public let assertive: Bool
    /// 服务端 msg（表外码兜底，G13）。
    public let serverMsg: String?

    public init(_ key: String, id: Int, traceId: String? = nil, showTrace6: Bool = false, assertive: Bool = true,
                serverMsg: String? = nil) {
        self.key = key
        self.id = id
        self.traceId = traceId
        self.showTrace6 = showTrace6
        self.assertive = assertive
        self.serverMsg = serverMsg
    }

    /// BR-TEXT-14 正文的兜底句（代拟键）。
    public static let unfinishedKey = "me.unfinished"

    /// 统一错误消息函数（brief §0「trace6」）：文案键 → 服务端 msg →「操作未完成，请稍后再试」；5xxxx 的 trace6 由 `ErrorTrace` 独立追加。
    public func message(_ texts: MeTexts) -> String {
        ErrorTrace
            .message(key: key, traceId: traceId, append: showTrace6, fallbackKey: Self.unfinishedKey) { key, vars in
                let text = texts.format(key, vars)
                if text.isEmpty, key == self.key, let serverMsg,
                   !serverMsg.trimmingCharacters(in: .whitespaces).isEmpty {
                    return serverMsg
                }
                return text
            }
    }
}

/// 读请求失败的分类（复用 APP-09 WalletErrors，网络错误换成本任务的键）。
public enum MeErrors {
    public static func of(_ result: ApiResult, probe: SendProbe? = nil) -> WalletError {
        let error = WalletErrors.of(result, probe: probe)
        guard error.textKey == WalletErrors.networkKey else { return error }
        return WalletError(error.kind, MeCodes.networkKey, traceId: error.traceId, trace6: error.showTrace6,
                           disable: error.disableMillis)
    }

    public static func notice(_ error: WalletError, id: Int) -> MeNotice {
        MeNotice(error.textKey, id: id, traceId: error.traceId, showTrace6: error.showTrace6)
    }

    /// 读请求失败的统一处理（Android R1-04 / 05 / 07，共性第 22、23 条）：先处理这一个响应自己的限流（42901 → 共用读取闸门按 Retry-After 启动
    /// 禁用期，缺省或非法 5 秒；10405 由网络层进已有强更分流），再给页面要显示的提示（统一错误文案 + trace6）。返回 nil = 静默（被作废）。
    @MainActor
    public static func readFailure(_ result: ApiResult, probe: SendProbe, gate: RetryAfterGate, id: () -> Int)
        -> MeNotice? {
        let error = of(result, probe: probe)
        switch error.kind {
        case .cancelled, .forceUpdate:
            return nil
        case .gated:
            return MeNotice(MeCodes.rateKey, id: id())
        case .retryAfter:
            gate.start(error.disableMillis)
            return MeNotice(MeCodes.rateKey, id: id())
        default:
            return notice(error, id: id())
        }
    }
}

/// 写操作结果 → 向量形状的输入（kind ok / transport / error，code、data、headers.Retry-After、traceId、msg），交给 NicknameOutcome /
/// AppealOutcome。
public enum MeResultInput {
    public static func of(_ result: ApiResult) -> [String: Any] {
        switch result {
        case let .success(data, _, _):
            return ["kind": "ok", "data": MeJson.object(data) ?? NSNull()]
        case let .failure(code, msg, data, traceId, effect, _):
            var out: [String: Any] = [
                "kind": "error",
                // 非强更的 10405 按 5xxxx 交写结果表（统一错误 + trace6，F-X-09）
                "code": NonForcedUpdate.pageCode(code: code, effect: effect),
                "data": MeJson.object(data) ?? NSNull(),
                "msg": msg,
            ]
            if let traceId {
                out["traceId"] = traceId
            }
            if code == 42901 {
                let millis = effect.disableMillis ?? MeCodes.defaultRetryMillis
                out["headers"] = ["Retry-After": String(max(1, millis / 1000))]
            }
            return out
        default:
            return ["kind": "transport"]
        }
    }
}

public extension MeEnv {
    /// 缺省：没有接剪贴板的环境按默认开启显示、切换不做事（DetachedMeEnv 等）。
    func clipboardAutoOn() -> Bool {
        true
    }

    func setClipboardAuto(_: Bool) {}

    func check(_ identity: MeIdentity) -> IdentityCheck {
        isCurrent(identity) ? .current : .stale
    }

    func recheckIdentity() {}
}
