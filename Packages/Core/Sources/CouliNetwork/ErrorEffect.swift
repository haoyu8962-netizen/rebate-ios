import Foundation
import Generated

/// Effect 种类（与 specs/network-vectors.json 的 effectKinds 同名；navigate、pageAction 是向量之外的码用的）。
public enum ErrorEffectKind: String, Sendable, Equatable {
    case login
    case bindPhone = "bind_phone"
    case consent
    case stepUp = "step_up"
    case authorize
    case guideOnly = "guide_only"
    case refreshReplay = "refresh_replay"
    case registerDeviceReplay = "register_device_replay"
    case forceUpdate = "force_update"
    case refreshOnly = "refresh_only"
    case clearSessionLogin = "clear_session_login"
    case clearSessionStayForceUpdate = "clear_session_stay_force_update"
    case disableButton = "disable_button"
    case toast
    case genericError = "generic_error"
    case fallbackMessage = "fallback_message"
    case disableWithToast = "disable_with_toast"
    case disableWithoutToast = "disable_without_toast"
    /// 跳到 route，不重放（封禁说明、注销进度、搜索、找回记录、收款账号等）。
    case navigate
    /// 发起页按 `ErrorEffect.action` 做码规定的界面动作（卡片置灰、无返利购买按钮、并号确认、申诉入口等），文案取 textKey。
    case pageAction = "page_action"
    /// 30144：按卡片 product_key + item_ref 自动重新请求转链、替换卡片，仍须用户再次点击。App 内链接落地页（LinkLanding，
    /// `fromProductCard = false`）没有卡片数据，改输出 pageAction（空态，不自动重试）。管线自己不重放原请求。
    case refetchProduct = "refetch_product"
    /// 40901：保持加载态，稍后查询结果（作废请求得到本码时未决键保持待确认）。
    case keepLoading = "keep_loading"
    /// 20001：在 `ErrorEffect.fields` 列出的字段旁提示（文案 error.20001.<reason> 回落 error.20001），不重放。
    case fieldError = "field_error"
    /// 20001 且 fields 含 device_hash：不向用户提示，按 BR-ID-09 重新读取设备标识后再注册（设备注册在 APP-03b），不重放。
    case rereadDeviceHash = "reread_device_hash"
    /// 20004：第三方授权凭证失效，由用户重新发起授权（第三方登录 route=Login；二次验证 route=nil 回到验证面板），
    /// 不自动重放。
    case reauthorize
}

/// `ErrorEffectKind.pageAction` 的具体界面动作（error-codes.yaml 的 action 列；三端同名）。
public enum ErrorPageAction {
    public static let refreshDetail = "refresh_detail"
    public static let noRebateAndSupport = "no_rebate_and_support"
    public static let reauthorizeNewAttempt = "reauthorize_new_attempt"
    public static let noRebateBuy = "no_rebate_buy"
    public static let searchByName = "search_by_name"
    public static let greyOutCard = "grey_out_card"
    public static let negativeBalanceNotice = "negative_balance_notice"
    public static let minorWithdrawRules = "minor_withdraw_rules"
    public static let downloadGuide = "download_guide"
    public static let mergeConfirm = "merge_confirm"
    public static let hideInviteEntries = "hide_invite_entries"
    public static let deletionBlockedSupport = "deletion_blocked_support"
    public static let hideOrDisableEntry = "hide_or_disable_entry"
    public static let newConversation = "new_conversation"
    public static let refreshConversation = "refresh_conversation"
    public static let keepSendDisabled = "keep_send_disabled"
    public static let disableTaoLiJin = "disable_tao_li_jin"
    public static let emptyState = "empty_state"
    public static let showReminderLimit = "show_reminder_limit"
    public static let openExistingReminder = "open_existing_reminder"
    public static let appeal = "appeal"
    public static let captchaThenReplay = "captcha_then_replay"
    public static let retryOrNoRebate = "retry_or_no_rebate"
    public static let searchUnavailable = "search_unavailable"
    public static let keepOtherMethods = "keep_other_methods"
    public static let newKeyResubmit = "new_key_resubmit"
    /// 结果未知的键收到非终结的 2xxxx（20903 除外）：按原内容暂时确认不了，保留【确认】【放弃】入口，
    /// 文案 `pending_confirm.cannot_confirm`；不输出 new_key_resubmit（BR-ID-10、03 §4.2「未决键」）。
    public static let pendingConfirm = "pending_confirm"
}

/// 前置动作完成后怎样重新发起原请求（BR-ID-10 细则）。
public enum ReplayMode: String, Sendable, Equatable {
    case sameKey = "same_key"
    case newKey = "new_key"
    case none
}

/// 当前强更 / 会话状态。update：supported / below / unknown；appVersion：本机 SemVer。
public struct ErrorActionState: Sendable, Equatable {
    public let update: String
    public let sessionScope: String
    public let appVersion: String

    public init(update: String, sessionScope: String, appVersion: String) {
        self.update = update
        self.sessionScope = sessionScope
        self.appVersion = appVersion
    }
}

/// ErrorActionMapper 的输入（03 §4.2）。headers 为响应头；isReplay = 本次已是重放（原请求至多重放 1 次）。
public struct ErrorActionInput {
    public let code: Int
    public let data: [String: Any]
    public let operation: ApiOperation
    public let headers: [String: String]
    public let isReplay: Bool
    public let state: ErrorActionState
    /// 发起页有可重新转链的商品卡（30144）；LinkLanding 等没有卡片数据的入口为 false。
    public let fromProductCard: Bool

    public init(
        code: Int,
        data: [String: Any],
        operation: ApiOperation,
        headers: [String: String],
        isReplay: Bool,
        state: ErrorActionState,
        fromProductCard: Bool = true
    ) {
        self.code = code
        self.data = data
        self.operation = operation
        self.headers = headers
        self.isReplay = isReplay
        self.state = state
        self.fromProductCard = fromProductCard
    }
}

/// 页面消费的 Effect：页面只看它，不自行判断码值（03 §4.2「统一入口」）。
/// - route：跳转或弹出的路由名；不跳为 nil。
/// - textKey：文案键（BR-TEXT-14：error.<code>.<reason> 回落 error.<code>）；nil = 不提示或用服务端 msg / 通用兜底。
/// - disableMillis：按钮禁用时长；nil = 不限时（页面按状态恢复）。
/// - includeTrace6：通用错误态附 trace_id 后 6 位。
/// - pendingKeyUnknown：四个 step-up 操作的键已结果未知：发起页进入待确认，不换新键（BR-ID-10）。
public struct ErrorEffect: Sendable, Equatable {
    public var code: Int
    public var kind: ErrorEffectKind
    public var replay: ReplayMode
    public var registerPending: Bool
    public var route: String?
    public var textKey: String?
    public var disableMillis: Int64?
    public var includeTrace6: Bool
    public var consentType: String?
    public var pendingKeyUnknown: Bool
    /// pageAction 的具体动作（`ErrorPageAction`）；其他 kind 为 nil。
    public var action: String?
    /// 20001 字段提示的字段名（data.fields）。
    public var fields: [String]?

    public init(
        code: Int,
        kind: ErrorEffectKind,
        replay: ReplayMode = .none,
        registerPending: Bool = false,
        route: String? = nil,
        textKey: String? = nil,
        disableMillis: Int64? = nil,
        includeTrace6: Bool = false,
        consentType: String? = nil,
        pendingKeyUnknown: Bool = false,
        action: String? = nil
    ) {
        self.code = code
        self.kind = kind
        self.replay = replay
        self.registerPending = registerPending
        self.route = route
        self.textKey = textKey
        self.disableMillis = disableMillis
        self.includeTrace6 = includeTrace6
        self.consentType = consentType
        self.pendingKeyUnknown = pendingKeyUnknown
        self.action = action
    }

    public var effectKindRaw: String {
        kind.rawValue
    }

    public var replayRaw: String {
        replay.rawValue
    }
}

/// 语义化版本比较（逐段整数，x.y.z）。非法版本返回 nil。
public enum SemVer {
    public static func compare(_ lhs: String, _ rhs: String) -> Int? {
        guard let left = parts(lhs), let right = parts(rhs) else {
            return nil
        }
        for (one, two) in zip(left, right) where one != two {
            return one < two ? -1 : 1
        }
        return 0
    }

    private static func parts(_ text: String) -> [UInt64]? {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else {
            return nil
        }
        var result: [UInt64] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let value = UInt64(piece) else {
                return nil
            }
            result.append(value)
        }
        return result
    }
}
