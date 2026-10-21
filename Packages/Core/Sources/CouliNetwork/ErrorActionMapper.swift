import Foundation
import Generated
import Session

/// 错误码 → Effect（03 §4.2「ErrorActionMapper 实现要点」；动作以 error-codes.yaml、BR-TEXT-14 为准）。
///
/// - 1xxxx 前置（登录、同意、绑手机）完成后沿用原键并登记 pending_action；3xxxx 前置（平台授权）用新键；
///   四个 step-up 操作（x-step-up）被 10001、10004（任何 consent_type）、10005 或 3xxxx 前置码拦下时只引导，
///   不重放、不登记；10003 沿用原键；10002、10402 自动沿用原键重放 1 次（再失败走通用错误态）。
/// - 30304 / 30305 / 30307 / 30308 对所有操作都只引导补办、不重放（三端一致）。
/// - 有明确界面动作的码不降成 Toast：30144 refetch_product（LinkLanding 为空态 pageAction），40901 keep_loading，
///   30206 / 30306 置灰按钮，其余见 `pageActions`（三端同名，见 lessons「三端对齐的名字」）。
/// - 10405 进强更不重放；本机版本不低于 data.min_supported_version（或它为空）而会话是 deletion_only 时只刷新；
///   reason=no_account 提示先更新。42901 按 Retry-After（非负整数秒；缺省或非法一律 5 秒）禁用按钮。
/// - 带 data.reason 的取 error.<code>.<reason>，字典没有回落 error.<code>；表外码与废弃码：5xxxx 通用错误态附 trace6，
///   其余用服务端 msg（fallbackMessage）；表内无专门分支、字典也没有文案键的码（10008 / 10009 / 30154 / 30417 / 44004）同样回落 msg
///   （CT-LOCK-01、CT-LOCK-02）。
public enum ErrorActionMapper {
    private static let loginRoute = "Login"
    /// 20004 后回到登录页的第三方登录接口（其余，如二次验证，回到验证面板）。
    private static let thirdPartyLoginOperations: Set<String> = ["loginByWechat", "loginByApple", "loginByHuawei"]
    private static let bindPhoneRoute = "BindPhone"
    private static let authSheetRoute = "AuthSheet"
    private static let forceUpdateRoute = "ForceUpdate"
    private static let realNameRoute = "RealName"
    private static let payoutAccountRoute = "PayoutAccount"
    private static let searchRoute = "Search"
    public static let defaultRetryAfterMillis: Int64 = 5000

    private static let authorizeCodes: Set<Int> = [30101, 30102, 30111]
    private static let guideCodes: [Int: String] = [
        30304: realNameRoute, 30305: payoutAccountRoute, 30307: payoutAccountRoute, 30308: payoutAccountRoute,
    ]
    private static let navigateCodes: [Int: String] = [
        10006: "RiskNotice", 10007: "DeleteAccount", 30143: searchRoute, 30205: "FindOrder",
        30502: searchRoute, 50302: searchRoute,
    ]
    /// 码 → 界面动作（error-codes.yaml action 列；对照见 `ErrorPageAction`）。
    /// 30411 无 reason 仅提示、44001 文案另取 risk_msg，见 map 里的特例。
    static let pageActions: [Int: String] = [
        20901: ErrorPageAction.newKeyResubmit,
        20902: ErrorPageAction.refreshDetail,
        30103: ErrorPageAction.noRebateAndSupport,
        30104: ErrorPageAction.reauthorizeNewAttempt,
        30121: ErrorPageAction.noRebateBuy,
        30132: ErrorPageAction.searchByName,
        30141: ErrorPageAction.greyOutCard,
        30151: ErrorPageAction.noRebateAndSupport,
        30153: ErrorPageAction.noRebateAndSupport,
        30302: ErrorPageAction.negativeBalanceNotice,
        30309: ErrorPageAction.minorWithdrawRules,
        30408: ErrorPageAction.downloadGuide,
        30411: ErrorPageAction.mergeConfirm,
        30413: ErrorPageAction.hideInviteEntries,
        30416: ErrorPageAction.deletionBlockedSupport,
        30501: ErrorPageAction.hideOrDisableEntry,
        30504: ErrorPageAction.newConversation,
        30505: ErrorPageAction.refreshConversation,
        30506: ErrorPageAction.keepSendDisabled,
        30602: ErrorPageAction.disableTaoLiJin,
        30701: ErrorPageAction.emptyState,
        30802: ErrorPageAction.showReminderLimit,
        30803: ErrorPageAction.openExistingReminder,
        30804: ErrorPageAction.openExistingReminder,
        44001: ErrorPageAction.appeal,
        44003: ErrorPageAction.captchaThenReplay,
        50303: ErrorPageAction.retryOrNoRebate,
        50304: ErrorPageAction.searchUnavailable,
        50305: ErrorPageAction.keepOtherMethods,
    ]
    /// 44003 通过人机验证后带验证凭证重放（沿用原键）；20901、30104 由用户用新键重新提交。
    private static let pageActionReplay: [Int: ReplayMode] = [44003: .sameKey, 20901: .newKey, 30104: .newKey]
    private static let disableCodes: Set<Int> = [30206, 30306]
    /// 30144 在这些操作上一律输出 page_action（三端裁定，与 fromProductCard 无关）。
    private static let pageActionOnly30144: Set<String> = ["getLink", "getSharePage"]
    /// LinkLanding 上 30144 的文案键。
    static let linkLandingInvalidKey = "link_landing.invalid"

    /// 1xxxx 的「补办前置」码：四个 step-up 操作与作废请求遇到时只引导。
    static let prerequisiteCodes: Set<Int> = [10001, 10004, 10005]

    public static func map(
        _ input: ErrorActionInput,
        hasText: (String) -> Bool = { DefaultTexts.text($0) != nil }
    ) -> ErrorEffect {
        withoutActuallyEscaping(hasText) { lookup in
            let context = MappingContext(input: input, hasText: lookup)
            guard let info = ErrorCodes.info(input.code), !info.isDeprecated else {
                // 表外码（未分配）与废弃码：5xxxx 通用错误态，其余用服务端 msg（BR-TEXT-14）。
                return context.isServerError
                    ? context.withTrace(context.effect(.genericError, key: .some(nil)))
                    : context.effect(.fallbackMessage, key: .some(nil))
            }
            return sessionEffect(context) ?? specialEffect(context) ?? tableEffect(context)
        }
    }

    /// 1xxxx 会话、前置与版本类。
    private static func sessionEffect(_ context: MappingContext) -> ErrorEffect? {
        switch context.code {
        case 10001:
            return context.prerequisite(.login, loginRoute)
        case 10004:
            var result = context.prerequisite(.consent, nil)
            result.consentType = JSONFields.string(context.input.data, "consent_type")
            return result
        case 10005:
            return context.prerequisite(.bindPhone, bindPhoneRoute)
        case 10002:
            return context.automaticReplay(.refreshReplay)
        case 10402:
            return context.automaticReplay(.registerDeviceReplay)
        case 10003:
            return context.effect(.stepUp, replay: .sameKey)
        case 10007:
            return JSONFields.string(context.input.data, "stage") == "processing"
                ? context.effect(.toast) : context.effect(.navigate, route: "DeleteAccount")
        case 10404:
            return context.effect(.clearSessionLogin, route: loginRoute)
        case 10405:
            return forceUpdateEffect(context)
        default:
            return nil
        }
    }

    /// 10405：升级前留下的受限令牌（本机不低于 min 或 min 为空，且会话是 deletion_only）只刷新（BR-ID-01 细则）。
    private static func forceUpdateEffect(_ context: MappingContext) -> ErrorEffect {
        let input = context.input
        let minimum = JSONFields.string(input.data, "min_supported_version")
        let restricted = input.state.sessionScope == SessionScope.deletionOnly
        let supported = minimum.map { (SemVer.compare(input.state.appVersion, $0) ?? -1) >= 0 } ?? true
        if context.reason != "no_account", restricted, supported {
            return context.effect(.refreshOnly, key: .some(nil))
        }
        return context.effect(.forceUpdate, route: forceUpdateRoute)
    }

    /// 需要看 data / 响应头 / 发起页的码。
    private static func specialEffect(_ context: MappingContext) -> ErrorEffect? {
        switch context.code {
        case 42901:
            var result = context.effect(.disableButton)
            result.disableMillis = retryAfterMillis(context.input.headers)
            return result
        case 44001:
            let risk = JSONFields.string(context.input.data, "risk_msg_code").map { "risk_msg.\($0)" }
                .flatMap { context.hasText($0) ? $0 : nil }
            return context.pageAction(ErrorPageAction.appeal, key: .some(risk ?? context.textKey))
        case 30144:
            return linkEffect(context)
        case 40901:
            return context.effect(.keepLoading)
        default:
            return otherSpecialEffect(context)
        }
    }

    /// 30144：商品卡重新转链并替换（refetch_product，文案 error.30144）。LinkLanding（fromProductCard = false）没有卡片
    /// 数据，getLink / getSharePage 不是卡片转链：两者同一分支，一律 page_action 空态、不自动重试，文案
    /// link_landing.invalid（三端裁定；与 fromProductCard 无关，R1-12）。
    private static func linkEffect(_ context: MappingContext) -> ErrorEffect {
        if !context.input.fromProductCard || pageActionOnly30144.contains(context.input.operation.operationId) {
            return context.pageAction(ErrorPageAction.emptyState, key: .some(linkLandingInvalidKey))
        }
        return context.effect(.refetchProduct)
    }

    private static func otherSpecialEffect(_ context: MappingContext) -> ErrorEffect? {
        switch context.code {
        case 30411 where context.reason != "mergeable":
            return context.effect(.toast)
        case 20001:
            return fieldErrorEffect(context)
        case 20004:
            // 第三方登录回到登录页，二次验证回到验证面板（route=nil），由用户重新发起授权；不自动重放（lessons 29、
            // 名字裁定 reauthorize）。
            let fromLogin = thirdPartyLoginOperations.contains(context.input.operation.operationId)
            return context.effect(.reauthorize, route: fromLogin ? loginRoute : nil)
        case 50301:
            return maintenanceEffect(context)
        default:
            return authorizeEffect(context)
        }
    }

    /// 20001：字段提示（带 data.fields）。fields 含 device_hash 时不向用户提示，按 BR-ID-09 重新读取设备标识后再注册
    /// （设备注册在 APP-03b）。
    private static func fieldErrorEffect(_ context: MappingContext) -> ErrorEffect {
        let fields = (context.input.data["fields"] as? [Any])?.compactMap { $0 as? String } ?? []
        let deviceHash = fields.contains("device_hash")
        var result = deviceHash
            ? context.effect(.rereadDeviceHash, key: .some(nil))
            : context.effect(.fieldError)
        result.fields = fields
        return result
    }

    /// 50301：maintenance（无 reason 同）禁用并 Toast；not_launched 禁用不 Toast。
    private static func maintenanceEffect(_ context: MappingContext) -> ErrorEffect {
        if context.reason == "not_launched" {
            return context.effect(.disableWithoutToast)
        }
        let key = resolveTextKey(code: context.code, reason: context.reason ?? "maintenance", hasText: context.hasText)
        return context.effect(.disableWithToast, key: .some(key))
    }

    /// 30101 / 30102 / 30111：平台授权（新键）；step-up 操作只引导；auth_unavailable 只提示。
    /// 生成表按 data.reason 给的重试类别不是 after_action（如 sharer_auth_invalid=never，CT-LOCK-01）→ 只提示，
    /// 不弹授权、不登记待办、不重放（契约数据驱动，与鸿蒙 / Android 同口径；link_landing.invalid 专门展示归 APP-13b）。
    private static func authorizeEffect(_ context: MappingContext) -> ErrorEffect? {
        guard authorizeCodes.contains(context.code) else {
            return nil
        }
        if context.reason == "auth_unavailable" || promptOnlyReason(code: context.code, reason: context.reason) {
            return context.effect(.toast)
        }
        return context.stepUpOperation
            ? context.effect(.guideOnly, route: authSheetRoute)
            : context.effect(.authorize, replay: .newKey, pending: true, route: authSheetRoute)
    }

    /// 按表：只引导、跳转、界面动作、置灰；其余 5xxxx 通用错误态，其余 Toast。
    private static func tableEffect(_ context: MappingContext) -> ErrorEffect {
        let code = context.code
        if let route = guideCodes[code] {
            return context.effect(.guideOnly, route: route)
        }
        if let route = navigateCodes[code] {
            return context.effect(.navigate, route: route)
        }
        if let action = pageActions[code] {
            var result = context.pageAction(action)
            result.replay = pageActionReplay[code] ?? .none
            return result
        }
        if disableCodes.contains(code) {
            return context.effect(.disableButton)
        }
        if context.isServerError {
            return context.withTrace(context.effect(.genericError))
        }
        if context.textKey == nil {
            // CT-LOCK-01 / CT-LOCK-02：表内但用户侧字典没有文案键的码（页面自处理码、置灰码、5xxxx 已在上面分走；目前只有只出现在
            // /admin/v1 的 10008 / 10009 / 30154 / 30417 / 44004）与表外码同一回落：用服务端 msg，不写专门分流（三端同口径）
            return context.effect(.fallbackMessage, key: .some(nil))
        }
        return context.effect(.toast)
    }

    /// 生成错误码表按 `reason` 规定的重试类别（retry_kind_by_reason）存在且不是 after_action：这个 reason 不能靠补办前置动作后
    /// 重试，授权类码只提示（30102 / 30111 的 sharer_auth_invalid=never；30101 / 30102 的 auth_unavailable=later 原本就只提示）。
    /// 没有 reason 或表里没有这个 reason 时为 false（走码本身的动作）。
    public static func promptOnlyReason(code: Int, reason: String?) -> Bool {
        guard let reason, let kind = ErrorCodes.info(code)?.retryKindByReason[reason] else {
            return false
        }
        return kind != .afterAction
    }

    /// 文案键：error.<code>.<reason> → error.<code> → nil（BR-TEXT-14）。
    public static func resolveTextKey(code: Int, reason: String?, hasText: (String) -> Bool) -> String? {
        let base = "error.\(code)"
        if let reason, hasText("\(base).\(reason)") {
            return "\(base).\(reason)"
        }
        return hasText(base) ? base : nil
    }

    /// 3xxxx 业务码：未决键的业务结果（BR-ID-10）。
    public static func isBusinessCode(_ code: Int) -> Bool {
        (30000...39999).contains(code)
    }

    /// 42901：Retry-After 的非负整数秒（最多 9 位）；缺省或非法（HTTP-date、负数、小数、超长）一律 5 秒。
    /// TODO(N-19): HTTP-date、小数、超大值的解析与封顶未规定（rule-gaps），三端统一按缺省 5 秒。
    public static func retryAfterMillis(_ headers: [String: String]) -> Int64 {
        let raw = headers.first { $0.key.caseInsensitiveCompare(HeaderNames.retryAfter) == .orderedSame }?
            .value.trimmingCharacters(in: .whitespaces)
        guard let raw, !raw.isEmpty, raw.count <= 9, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let seconds = Int64(raw)
        else {
            return defaultRetryAfterMillis
        }
        return seconds * 1000
    }
}

/// 一次映射的公共输入与构造工具。
struct MappingContext {
    let input: ErrorActionInput
    let hasText: (String) -> Bool
    let reason: String?
    let textKey: String?

    init(input: ErrorActionInput, hasText: @escaping (String) -> Bool) {
        self.input = input
        self.hasText = hasText
        reason = JSONFields.string(input.data, "reason")
        textKey = ErrorActionMapper.resolveTextKey(code: input.code, reason: reason, hasText: hasText)
    }

    var code: Int {
        input.code
    }

    var stepUpOperation: Bool {
        input.operation.stepUp != nil
    }

    var isServerError: Bool {
        (50000...59999).contains(code)
    }

    func effect(
        _ kind: ErrorEffectKind,
        replay: ReplayMode = .none,
        pending: Bool = false,
        route: String? = nil,
        key: String?? = .none
    ) -> ErrorEffect {
        ErrorEffect(
            code: code, kind: kind, replay: replay, registerPending: pending, route: route, textKey: key ?? textKey
        )
    }

    func pageAction(_ action: String, key: String?? = .none) -> ErrorEffect {
        var result = effect(.pageAction, key: key)
        result.action = action
        return result
    }

    func withTrace(_ effect: ErrorEffect) -> ErrorEffect {
        var result = effect
        result.includeTrace6 = true
        return result
    }

    /// 1xxxx 前置：完成后沿用原键并登记 pending_action；四个 step-up 操作只引导。
    func prerequisite(_ kind: ErrorEffectKind, _ route: String?) -> ErrorEffect {
        stepUpOperation
            ? effect(.guideOnly, route: route)
            : effect(kind, replay: .sameKey, pending: true, route: route)
    }

    /// 10002、10402：自动沿用原键重放 1 次；已是重放再失败走通用错误态。
    func automaticReplay(_ kind: ErrorEffectKind) -> ErrorEffect {
        input.isReplay ? withTrace(effect(.genericError)) : effect(kind, replay: .sameKey, key: .some(nil))
    }
}
