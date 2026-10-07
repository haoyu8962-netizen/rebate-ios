import Foundation

/// 请求头名（03 §4.2、04 §5）。
public enum HeaderNames {
    public static let authorization = "Authorization"
    public static let appId = "X-App-Id"
    public static let platform = "X-Platform"
    public static let appVersion = "X-App-Version"
    public static let build = "X-Build"
    public static let deviceId = "X-Device-Id"
    public static let channel = "X-Channel"
    public static let traceId = "X-Trace-Id"
    public static let idempotencyKey = "Idempotency-Key"
    public static let timestamp = "X-Timestamp"
    public static let nonce = "X-Nonce"
    public static let sign = "X-Sign"
    public static let stepUpToken = "X-Step-Up-Token"
    public static let retryAfter = "Retry-After"
    public static let date = "Date"
    /// 条件请求（03 §4.3：回前台带 ETag 拉取 /v1/config）。
    public static let ifNoneMatch = "If-None-Match"
    public static let etag = "ETag"

    /// 不含凭据与设备标识的公共头：基本模式、撤回清理未完成时也带。
    public static let anonymous = [appId, platform, appVersion, build, channel, traceId]
    /// 签名头（BR-ID-09）。
    public static let signature = [timestamp, nonce, sign]
}

/// 隐私状态（与向量的 raw 同名）。
public enum PrivacyRaw {
    /// 已同意隐私政策：完整功能。
    public static let full = "full"
    /// 基本模式（BR-ID-11）：匿名只读白名单。
    public static let basic = "basic"
    /// 尚未决定（首启弹窗之前或之中）：只允许配置与协议文本（BR-ID-11）。
    public static let undecided = "undecided"
}

/// 强更检查结论（ErrorActionState.update 的 raw）。Router 的 checking 按 unknown 传。
public enum UpdateRaw {
    public static let supported = "supported"
    public static let below = "below"
    public static let unknown = "unknown"
}

/// 本地拒绝原因（三端测试接线名称）。
public enum LocalRejectReason {
    public static let environmentUnsettled = "environment_unsettled"
    public static let basicModeDenied = "basic_mode_denied"
    public static let sessionScopeDenied = "session_scope_denied"
    public static let deviceNotReady = "device_not_ready"
    /// 四个 step-up 操作的键结果未知或在途时，新的提交被挡（BR-ID-10「敏感操作的幂等键」）。
    public static let pendingKeyUnresolved = "pending_key_unresolved"
    /// 四个 step-up 操作取不到可信会话里的账号（BR-ID-10：未决记录按账号隔离），不发出。
    public static let accountUnknown = "account_unknown"
    /// 未决记录没能持久化（安全存储写入失败）：记录落盘是发送的前置条件，不发出。
    public static let pendingStoreFailed = "pending_store_failed"
    /// 未决记录（确认、放弃）属于别的账号：发出前当前会话账号已与记录账号不一致，不发出（lessons 15）。
    public static let accountMismatch = "account_mismatch"
    /// 重试或重放（10002 刷新后、10401 校时后、10402 重新注册后、读接口重试）发出前会话已换代（退出、切换账号、
    /// 重新登录），不替新会话发旧请求（lessons 14）。
    public static let sessionChanged = "session_changed"
    /// 等待中的单飞刷新失败（或受限会话屏障刷新失败），会话已清，原请求不再发出（`ApiResult.sessionCleared`）。
    public static let sessionCleared = "session_cleared"
    /// 会话读取失败（安全存储暂时读不了，可能有会话）：需要会话的接口不带凭据也不发出，隔离与删除重试保持（R2-01）。
    public static let sessionUnreadable = "session_unreadable"
    /// 调用开始后隐私或环境世代变了（撤回同意、切换环境，`ApiClient.invalidateSessions`）：在途请求及其重试、重放作废。
    public static let callCancelled = "call_cancelled"
    /// 未知 operationId 或路径参数没填全（调用方的编程错误，不发出）。
    public static let invalidCall = "invalid_call"
    /// 登录成功但令牌没能写进安全存储（`ApiResult.sessionNotSaved`）：不算登录成功。
    public static let sessionSaveFailed = "session_save_failed"
    /// 登录响应 code=0 但 data.tokens 缺项（`ApiResult.sessionNotSaved`）。
    public static let invalidSessionTokens = "invalid_session_tokens"
}

/// 本 App 固定的公共头取值（03 §4.2）。
public struct ClientIdentity: Sendable, Equatable {
    /// X-App-Id 的占位值（三端统一）。TODO(N-19): 正式 app_id 由平台分配后替换。
    public static let placeholderAppId = "couli"

    public let appId: String
    /// client_platform：ios。
    public let platform: String
    /// SemVer（不带构建后缀）。
    public let appVersion: String
    public let build: String
    /// install_channel。
    public let channel: String

    public init(
        appId: String = ClientIdentity.placeholderAppId,
        platform: String,
        appVersion: String,
        build: String,
        channel: String
    ) {
        self.appId = appId
        self.platform = platform
        self.appVersion = appVersion
        self.build = build
        self.channel = channel
    }
}

/// 设备凭据（BR-ID-09）：服务端签发的 device_id 与 install_secret（APP-03b：ClientCore 的 DeviceRegistry）。
/// 只在凭据可读时读取。两项一次读出（`credentials`），不拼两次读取的混合结果。
public protocol DeviceCredentials: Sendable {
    var deviceId: String? { get }
    var installSecret: String? { get }
    /// 一次读出的 device_id 与 install_secret（任一项缺失为 nil）。默认由上面两项拼出；生产实现覆盖为一次读取。
    var credentials: (deviceId: String, installSecret: String)? { get }
}

public extension DeviceCredentials {
    var credentials: (deviceId: String, installSecret: String)? {
        guard let id = deviceId, !id.isEmpty, let secret = installSecret, !secret.isEmpty else {
            return nil
        }
        return (id, secret)
    }
}

/// 设备还没注册（测试与未接线时）：需要签名的接口一律本地返回 device_not_ready。生产实现是 ClientCore 的 DeviceRegistry。
public struct UnregisteredDevice: DeviceCredentials {
    public init() {}

    public var deviceId: String? {
        nil
    }

    public var installSecret: String? {
        nil
    }
}

/// 每次发请求前取的状态（App 从环境闸门、隐私闸门、强更检查读出来）。
public struct NetworkContext: Sendable, Equatable {
    /// `PrivacyRaw`。
    public let privacy: String
    /// EnvironmentGate 已通过；未通过时不发任何请求。
    public let environmentSettled: Bool
    /// 撤回同意的本地清理已完成；false 时不读、不带任何凭据。
    public let credentialsReadable: Bool
    /// `UpdateRaw`。
    public let update: String
    /// 当前环境的 API 基址；环境未就绪时为 nil。
    public let apiBaseURL: URL?

    public init(
        privacy: String,
        environmentSettled: Bool,
        credentialsReadable: Bool,
        update: String,
        apiBaseURL: URL?
    ) {
        self.privacy = privacy
        self.environmentSettled = environmentSettled
        self.credentialsReadable = credentialsReadable
        self.update = update
        self.apiBaseURL = apiBaseURL
    }
}

/// 网络层对外的回调。
public struct NetworkHooks: Sendable {
    /// 进强更（Update.on10405）：确需强更的 10405，或强更检查未知期间登录 / 刷新拿到 deletion_only（min 为 nil）。
    public var onForceUpdate: @Sendable (String?) async -> Void
    /// 每个错误 Effect（页面也能从 `ApiResult.failure` 拿到）。
    public var onEffect: @Sendable (ErrorEffect) async -> Void
    /// 10402：重新注册设备（APP-03b，ClientCore 的 DeviceRegistry.reRegister）；参数是被拒请求带的 X-Device-Id
    /// （单飞：同一个被拒的 device_id 只重新注册 1 次；已被换掉时直接返回 true）。返回 true 后沿用原键重放 1 次。
    public var reRegisterDevice: @Sendable (_ rejectedDeviceId: String?) async -> Bool
    /// 10402 且重新注册 / 重放预算已用完（重放、刷新重放再次收到 10402）：隔离这次请求所用的凭据，并把后续恢复交给
    /// 唯一一条注册退避链（APP-03b 共性 25）。原调用随即结束。只在调用仍属有效世代时调用。
    public var deviceRejected: @Sendable (_ rejectedDeviceId: String?) -> Void

    public init(
        onForceUpdate: @escaping @Sendable (String?) async -> Void = { _ in },
        onEffect: @escaping @Sendable (ErrorEffect) async -> Void = { _ in },
        reRegisterDevice: @escaping @Sendable (_ rejectedDeviceId: String?) async -> Bool = { _ in false },
        deviceRejected: @escaping @Sendable (_ rejectedDeviceId: String?) -> Void = { _ in }
    ) {
        self.onForceUpdate = onForceUpdate
        self.onEffect = onEffect
        self.reRegisterDevice = reRegisterDevice
        self.deviceRejected = deviceRejected
    }
}

/// 一次调用。
public struct ApiCall: Sendable, Equatable {
    /// openapi 的 operationId（ApiOperations）。
    public var operationId: String
    /// 路径参数（按路径段编码）。
    public var pathParams: [String: String]
    /// 原样的查询串（不含 "?"；签名按发出的字节计算）。
    public var query: String?
    /// 请求体原始文本（UTF-8；签名与重放都用这份字节，不重新序列化）。
    public var body: String?
    /// 沿用的 Idempotency-Key；写操作缺省时生成新键。
    public var idempotencyKey: String?
    /// step-up 操作的 X-Step-Up-Token。
    public var stepUpToken: String?
    /// 未决记录的展示摘要。
    public var summary: String
    /// 发起页有可重新转链的商品卡（30144 输出 refetch_product）；App 内链接落地页 LinkLanding 传 false。
    public var fromProductCard: Bool
    /// 读接口的 If-None-Match（原样发送，不拆引号或 W/ 前缀；03 §4.3 回前台带 ETag 拉取配置）。写接口忽略。
    public var ifNoneMatch: String?

    public init(
        operationId: String,
        pathParams: [String: String] = [:],
        query: String? = nil,
        body: String? = nil,
        idempotencyKey: String? = nil,
        stepUpToken: String? = nil,
        summary: String = "",
        fromProductCard: Bool = true,
        ifNoneMatch: String? = nil
    ) {
        self.operationId = operationId
        self.pathParams = pathParams
        self.query = query
        self.body = body
        self.idempotencyKey = idempotencyKey
        self.stepUpToken = stepUpToken
        self.summary = summary
        self.fromProductCard = fromProductCard
        self.ifNoneMatch = ifNoneMatch
    }
}

/// 调用结果。`data` 是外壳里 data 字段的 JSON 字节（没有或为 null 时为 nil），由调用方按模型解码。
public enum ApiResult: Sendable, Equatable {
    /// code = 0。
    case success(data: Data?, traceId: String?, idempotencyKey: String?)
    /// 业务错误码；effect 为 ErrorActionMapper 的输出（已按管线处理过刷新、重放、未决键）。
    case failure(
        code: Int,
        msg: String,
        data: Data?,
        traceId: String?,
        effect: ErrorEffect,
        idempotencyKey: String?
    )
    /// 本地拒绝，没有发出（`LocalRejectReason`）。
    case localReject(reason: String)
    /// 等待中的刷新失败：会话已清、原请求（重放或屏障后的首发）不再发出。原因固定为 session_cleared（三端同名）；
    /// effect 为 clear_session_login，强更状态下 clear_session_stay_force_update。
    case sessionCleared(effect: ErrorEffect)
    /// 作废接口返回 abandoned：这次提交已放弃，未决记录已结束（发起页恢复提交入口，用户重新提交用新键）。
    case abandoned(idempotencyKey: String)
    /// 登录响应 code=0，但会话没有保存：令牌写不进安全存储（session_save_failed）、data.tokens 缺项
    /// （invalid_session_tokens），或响应到达时已作废 / 已换代（call_cancelled / session_changed）。
    /// 不是登录成功：调用方停在登录页提示失败，当前会话保持原样。
    case sessionNotSaved(reason: String, traceId: String?)
    /// 没有带统一外壳的响应：timeout / disconnect / no_envelope（网关错误页等）。
    /// pendingKeyUnknown = 四个 step-up 操作的键因此进入结果未知（发起页进入待确认）。
    case transportFailure(kind: String, httpStatus: Int?, idempotencyKey: String?, pendingKeyUnknown: Bool)
}

public extension ApiResult {
    /// 没有发出时的原因：localReject 的 reason，sessionCleared 为 session_cleared；其余 nil。
    var notSentReason: String? {
        switch self {
        case let .localReject(reason):
            reason
        case .sessionCleared:
            LocalRejectReason.sessionCleared
        default:
            nil
        }
    }
}

/// JSON 对象里取值的小工具（JSONSerialization 的结果）。
enum JSONFields {
    static func object(_ text: String?) -> [String: Any]? {
        guard let data = text?.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ object: [String: Any], _ key: String) -> String? {
        object[key] as? String
    }

    /// 真正的 JSON 布尔（不把 0 / 1 当布尔）。
    static func bool(_ object: [String: Any], _ key: String) -> Bool? {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    /// 真正的 JSON 整数（不把布尔、小数当整数）。
    static func int(_ object: [String: Any], _ key: String) -> Int? {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let value = number.intValue
        return NSNumber(value: value) == number ? value : nil
    }

    static func encode(_ value: Any?) -> Data? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if JSONSerialization.isValidJSONObject(value) {
            return try? JSONSerialization.data(withJSONObject: value)
        }
        return try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
    }
}
