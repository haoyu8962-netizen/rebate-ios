import CouliNetwork
import Foundation
import Generated
import Session

// 短信登录主链路的纯逻辑（APP-05a；BR-ID-04、BR-ID-05、BR-ID-10、BR-INV-02、BR-INV-06、BR-INV-18、BR-TEXT-14；03 §4.2）。
// 三端同名；向量 specs/login-vectors.json（LoginVectorTests）。没有界面、网络与计时器：执行器是 LoginService，页面是 LoginView。

// MARK: - 手机号

/// 手机号规范化结果。
public struct PhoneResult: Equatable, Sendable {
    public let valid: Bool
    /// 规范化后的 11 位号码；不合法为 nil。
    public let normalized: String?
    /// 不合法的原因（与服务端 20001 data.reason 同名：phone_invalid）；合法为 nil。
    public let reasonRaw: String?
}

/// 手机号规范化（BR-ID-05 细则「手机号规范化」，与服务端同一规格）：
/// ① NFKC；② 删除全部空白（含 U+3000、U+00A0）、零宽字符（U+200B–U+200D、U+FEFF）与连字符（「-」及 U+2010–U+2015）；
/// ③ 去国家码：「+86」开头，或「0086」「86」开头且其后恰为 11 位数字；④ 必须是 1[3-9] 开头的 11 位 ASCII 数字。
/// 服务端永远自己再规范化一遍，客户端结果只用于提示与提交。
public enum PhoneNumber {
    public static let reasonInvalid = "phone_invalid"

    public static func normalize(_ raw: String) -> PhoneResult {
        var text = stripped(raw.precomposedStringWithCompatibilityMapping)
        if text.hasPrefix("+86") {
            text = String(text.dropFirst(3))
        } else if text.hasPrefix("0086"), isAsciiDigits(String(text.dropFirst(4)), count: 11) {
            text = String(text.dropFirst(4))
        } else if text.hasPrefix("86"), isAsciiDigits(String(text.dropFirst(2)), count: 11) {
            text = String(text.dropFirst(2))
        }
        let scalars = Array(text.unicodeScalars)
        guard isAsciiDigits(text, count: 11), scalars[0] == "1", ("3"..."9").contains(scalars[1]) else {
            return PhoneResult(valid: false, normalized: nil, reasonRaw: reasonInvalid)
        }
        return PhoneResult(valid: true, normalized: text, reasonRaw: nil)
    }

    /// 页面显示用的脱敏号码：138****5678（设计稿 LoginCode「验证码已发送至」）。
    public static func masked(_ normalized: String) -> String {
        guard normalized.count == 11 else { return normalized }
        return String(normalized.prefix(3)) + "****" + String(normalized.suffix(4))
    }

    static func isAsciiDigits(_ text: String, count: Int) -> Bool {
        text.unicodeScalars.count == count && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    private static func stripped(_ text: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !removable(scalar) {
            view.append(scalar)
        }
        return String(view)
    }

    private static func removable(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || zeroWidth.contains(scalar.value) || scalar == "-"
            || (0x2010...0x2015).contains(scalar.value)
    }

    static let zeroWidth: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0xFEFF]
}

// MARK: - 协议勾选

/// 登录页的协议勾选（BR-ID-04：勾选框默认不勾；未勾选点登录 → 确认框；同意后记下点击时刻并继续）。
/// `consentAtMillis` 是本机记下的勾选 / 确认时刻（登录请求的 consent_at），不是服务端已写入 consent_records。
/// 取消勾选时清除记下的时刻：之后再登录必须重新确认（TODO(N-26) AGREEMENT-01：历史时刻的去留未规定，保守清除）。
public struct AgreementState {
    public private(set) var checked = false
    /// 确认框正在显示。
    public private(set) var showConfirm = false
    /// 最近一次点登录（或在确认框里同意）之后可以继续。
    public private(set) var proceed = false
    public private(set) var consentAtMillis: Int64?
    private let clock: () -> Int64

    public init(clock: @escaping () -> Int64) {
        self.clock = clock
    }

    /// 点【获取验证码】或【登录】：已勾选直接继续；未勾选弹确认框。
    public mutating func tapLogin() {
        if checked, consentAtMillis != nil {
            showConfirm = false
            proceed = true
        } else {
            showConfirm = true
            proceed = false
        }
    }

    public mutating func check() {
        checked = true
        consentAtMillis = clock()
        showConfirm = false
        proceed = false
    }

    public mutating func uncheck() {
        checked = false
        consentAtMillis = nil
        proceed = false
    }

    /// 确认框【同意并继续】：勾上并记下点击时刻（实参，毫秒）。
    public mutating func confirm(nowMillis: Int64) {
        checked = true
        consentAtMillis = nowMillis
        showConfirm = false
        proceed = true
    }

    /// 确认框【取消】、点了确认框里的协议链接：不勾选、不继续。
    public mutating func cancel() {
        showConfirm = false
        proceed = false
    }

    /// 页面取走「继续」一次（同一次同意不触发两次请求）。
    public mutating func consumeProceed() -> Bool {
        defer { proceed = false }
        return proceed
    }
}

// MARK: - 发码倒计时

/// 发码之后的倒计时与页面状态。
public struct SmsCountdownResult: Equatable, Sendable {
    public let countdownSec: Int
    public let canResend: Bool
    /// code_sent / rate_limited / 其余同 LoginErrorMapper 的 stateRaw。
    public let stateRaw: String
    public let textKey: String?
}

/// 发码倒计时（BR-ID-05：60 秒 1 条；03 §4.2、BR-TEXT-14：42901 按 Retry-After 禁用触发的按钮，缺省 5 秒——编排者
/// 2026-10-07 更正，不取较大者）。Retry-After 的解析与 ErrorActionMapper 同一个函数（不另造）。
public enum SmsCountdown {
    public static let resendSeconds = 60
    public static let stateSent = "code_sent"
    public static let stateRateLimited = "rate_limited"

    /// `code`：统一外壳的业务码（成功 0）。
    public static func after(code: Int, retryAfterHeader: String?, nowMillis _: Int64) -> SmsCountdownResult {
        var headers: [String: String] = [:]
        if let retryAfterHeader {
            headers[HeaderNames.retryAfter] = retryAfterHeader
        }
        return fromMillis(code: code, disableMillis: ErrorActionMapper.retryAfterMillis(headers), data: [:])
    }

    /// 执行器用（ApiResult 不带响应头，ErrorEffect.disableMillis 已是同一函数算出的禁用毫秒数）。成功时取 60 秒；
    /// data.resend_after_sec 更大时按它（契约：至少 60，取各项限制最晚的解除时刻）。
    /// TODO(N-26) SMS-01：小于 60、缺头、HTTP-date 由 ErrorActionMapper 统一兜底（缺省 5 秒）。
    public static func fromMillis(code: Int, disableMillis: Int64, data: [String: Any]) -> SmsCountdownResult {
        if code == 0 {
            var seconds = resendSeconds
            if let resend = (data["resend_after_sec"] as? NSNumber)?.intValue, resend > seconds, resend <= 86400 {
                seconds = resend
            }
            return SmsCountdownResult(countdownSec: seconds, canResend: false, stateRaw: stateSent, textKey: nil)
        }
        let mapped = LoginErrorMapper.map(op: LoginErrorMapper.sendSmsCode, code: code, data: data)
        if code == 42901 {
            let seconds = max(1, Int((disableMillis + 999) / 1000))
            return SmsCountdownResult(
                countdownSec: seconds, canResend: false, stateRaw: stateRateLimited, textKey: mapped.textKey
            )
        }
        return SmsCountdownResult(countdownSec: 0, canResend: true, stateRaw: mapped.stateRaw, textKey: mapped.textKey)
    }
}

// MARK: - 验证码

/// 验证码输入的形状（只报告原字符串，不规定 UI 清洗，rule-gaps CODE-01）。
public struct CodeShape: Equatable, Sendable {
    public let complete: Bool
    public let digitsOnly: Bool
}

/// 6 位短信验证码（BR-ID-05；openapi LoginBySmsRequest.code ^[0-9]{6}$）。
public enum CodeInput {
    public static let length = 6
    /// 验证码有效期（秒，BR-ID-05；openapi SendSmsCodeData.expires_in_sec 的取值）。用来判断「还能不能继续输入已收到的码」。
    public static let validSeconds = 300

    public static func accept(_ raw: String) -> CodeShape {
        let digits = raw.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
        return CodeShape(complete: digits && raw.unicodeScalars.count == length, digitsOnly: digits)
    }

    /// 输入框的清洗：只留 ASCII 数字，最多 6 位（TODO(N-26) CODE-01：全角与粘贴策略未规定，保守只收 ASCII）。
    public static func sanitize(_ raw: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where ("0"..."9").contains(scalar) && view.count < length {
            view.append(scalar)
        }
        return String(view)
    }
}

// MARK: - 错误映射

/// 登录相关错误码在页面上的状态与文案（经 ErrorActionMapper，不另造码表）。
public struct LoginErrorResult: Equatable, Sendable {
    /// field_error / code_error / code_expired / rate_limited / risk_blocked / registration_blocked（LoginCodeBlocked）/
    /// force_update / deletion_processing（LoginDeletionProcessing）/ session_expired（LoginSessionExpired）/
    /// provider_unavailable / service_error / network_error / toast / message / page_action。
    public let stateRaw: String
    public let textKey: String?
    /// 要在旁边提示的字段（phone / code / invite_code…）。
    public let field: String?
    /// 网络层或页面要去的路由（ForceUpdate、Login…）。
    public let route: String?
    /// 禁用触发按钮的毫秒数（42901）；其余 0。
    public let disableMillis: Int64

    init(_ stateRaw: String, _ textKey: String?, field: String? = nil, route: String? = nil, disableMillis: Int64 = 0) {
        self.stateRaw = stateRaw
        self.textKey = textKey
        self.field = field
        self.route = route
        self.disableMillis = disableMillis
    }
}

public enum LoginErrorMapper {
    public static let sendSmsCode = "sendSmsCode"
    public static let loginBySms = "loginBySms"

    /// op 是 operationId；code 是业务码；data 是外壳 data。
    public static func map(op: String, code: Int, data: [String: Any], headers: [String: String] = [:])
        -> LoginErrorResult {
        guard let operation = ApiOperations.byId(op) else {
            return LoginErrorResult("message", nil)
        }
        // 登录页没有会话：按「受支持、正常作用域」映射（rule-gaps ERROR-01：10405 受限令牌、强更中 10404 由网络层按
        // 真实状态处理）。
        let effect = ErrorActionMapper.map(ErrorActionInput(
            code: code, data: data, operation: operation, headers: headers, isReplay: false,
            state: ErrorActionState(
                update: UpdateRaw.supported,
                sessionScope: Session.SessionScope.full,
                appVersion: ""
            )
        ))
        return ofEffect(op: op, code: code, effect: effect)
    }

    /// 网络层已给出的 Effect（ApiResult.failure 的 effect）→ 页面状态。
    public static func ofEffect(op: String, code: Int, effect: ErrorEffect) -> LoginErrorResult {
        codeSpecific(op: op, code: code, effect: effect) ?? byKind(code: code, effect: effect)
    }

    /// 登录页按码区分的几个状态（验证码错误 / 失效、注册被拦、注销中）。
    private static func codeSpecific(op: String, code: Int, effect: ErrorEffect) -> LoginErrorResult? {
        let key = effect.textKey
        let route = effect.route
        switch code {
        case 20002:
            return LoginErrorResult("code_error", key, field: "code", route: route)
        case 20003:
            return LoginErrorResult("code_expired", key, field: "code", route: route)
        case 44001:
            // 发码被拦只提示；登录（注册）被拦是 LoginCodeBlocked 弹窗（不建号，验证码要重新获取）。
            return LoginErrorResult(op == loginBySms ? "registration_blocked" : "risk_blocked", key, route: route)
        case 10007 where route == nil:
            return LoginErrorResult("deletion_processing", key)
        default:
            return nil
        }
    }

    /// 其余按公共 Effect 种类。
    private static func byKind(code: Int, effect: ErrorEffect) -> LoginErrorResult {
        let key = effect.textKey
        let route = effect.route
        switch effect.kind {
        case .fieldError:
            return LoginErrorResult("field_error", key, field: effect.fields?.first, route: route)
        case .disableButton:
            return LoginErrorResult(
                SmsCountdown.stateRateLimited, key, route: route,
                disableMillis: effect.disableMillis ?? ErrorActionMapper.defaultRetryAfterMillis
            )
        case .clearSessionLogin, .clearSessionStayForceUpdate:
            return LoginErrorResult("session_expired", key, route: route)
        case .pageAction:
            return LoginErrorResult(code == 50305 ? "provider_unavailable" : "page_action", key, route: route)
        default:
            return LoginErrorResult(kindStates[effect.kind] ?? "toast", key, route: route)
        }
    }

    private static let kindStates: [ErrorEffectKind: String] = [
        .forceUpdate: "force_update", .genericError: "service_error", .fallbackMessage: "message",
    ]
}
