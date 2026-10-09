import Foundation

/// 敏感清单（BR-ID-16 细则「敏感页面不识别」；规则空白 G12）：这些路由或浮层在前台时，回前台不读剪贴板，离开后也不补做。集中放这一处，
/// Router（当前路由）与浮层（当前浮层）都按它判断。三端同名。
public enum ClipboardSensitive {
    public static let routes: Set<String> = [
        "Login", "BindPhone", "RealName", "PayoutAccount", "Withdraw", "LaborAgreement", "DeleteAccount", "FindOrder",
        "ForceUpdate",
    ]

    public static let overlayNone = "none"
    public static let overlayStepUp = "step_up"
    public static let overlayAuthSheet = "auth_sheet"
    public static let overlayOAuth = "oauth_in_progress"
    public static let overlayAuthJump = "auth_jump"
    public static let overlayPrivacyFirstLaunch = "privacy_first_launch"
    public static let overlayForceUpdate = "force_update"

    /// 二次验证面板、AuthSheet、第三方登录或授权进行中（含 auth_jump 执行中）、首启隐私弹窗、强更（G12）。
    public static let overlays: Set<String> = [
        overlayStepUp, overlayAuthSheet, overlayOAuth, overlayAuthJump, overlayPrivacyFirstLaunch, overlayForceUpdate,
    ]

    public static func sensitive(route: String?, overlay: String?) -> Bool {
        route.map(routes.contains) == true || overlay.map(overlays.contains) == true
    }
}

/// 读取判定的输入（各端同名字段，向量 readPolicy.state）。
public struct ClipboardReadState: Sendable, Equatable {
    /// agreed / basic / outdated（基本模式 / 同意的不是当前版本隐私政策）。
    public var consent: String
    /// cold_start_foreground / foreground_after_background / refocus_without_background / in_app_navigation /
    /// window_focus。
    public var event: String
    public var route: String?
    public var overlay: String = ClipboardSensitive.overlayNone
    /// 配置开关 clipboard.enabled.<本端>（G05：只有明确 false 才关）。
    public var configEnabled = true
    /// 栈顶网页容器经 clipboard.setAutoDetect(false) 抑制（G06）。
    public var webSuppressed = false
    /// 本次前台已经判定过（共性第 1 条：一次前台最多一次）。
    public var readThisForeground = false
    /// Android 设备级开关「打开 App 自动识别剪贴板」。
    public var androidAutoSwitch = true
    /// Android 窗口已获得焦点。
    public var androidWindowFocused = true
    /// iOS changeCount 自上次判定以来变了（没变化就跳过，AC-S1-03 c）。
    public var iosChangeCountChanged = true
    /// iOS detectPatterns 的结果；nil = 还没探测。
    public var iosDetectHit: Bool?

    public init(consent: String, event: String, route: String?) {
        self.consent = consent
        self.event = event
        self.route = route
    }
}

/// 判定结果：actionRaw read / detect_patterns / show_prompt / paste_only / skip。
public struct ClipboardReadDecision: Sendable, Equatable {
    public let actionRaw: String
    public let reasonRaw: String?

    public init(actionRaw: String, reasonRaw: String? = nil) {
        self.actionRaw = actionRaw
        self.reasonRaw = reasonRaw
    }
}

/// 读取判定（brief §2.1、§3；BR-ID-16、CAP-X-02；规则空白 G05、G06、G12、G13）。三端同名、同一套向量。顺序：隐私（基本模式 / 版本过期）
/// → 敏感路由与浮层 → 鸿蒙只给 PasteButton → 触发事件（冷启动进入前台、经过后台再回前台；Android 另有等焦点的 window_focus）→ 本次前台
/// 已判定 → 配置开关 → 网页抑制 → Android 设备级开关与窗口焦点 → iOS changeCount 与 detectPatterns。
public enum ClipboardReadPolicy {
    public static let platformIOS = "ios"
    public static let platformAndroid = "android"
    public static let platformHarmony = "harmony"

    public static let consentAgreed = "agreed"
    public static let consentBasic = "basic"
    public static let consentOutdated = "outdated"

    public static let eventColdStart = "cold_start_foreground"
    public static let eventForeground = "foreground_after_background"
    public static let eventRefocus = "refocus_without_background"
    public static let eventNavigation = "in_app_navigation"
    public static let eventWindowFocus = "window_focus"

    public static let actionRead = "read"
    public static let actionDetect = "detect_patterns"
    public static let actionShowPrompt = "show_prompt"
    public static let actionPasteOnly = "paste_only"
    public static let actionSkip = "skip"

    public static let reasonBasicMode = "basic_mode"
    public static let reasonPrivacyOutdated = "privacy_outdated"
    public static let reasonSensitive = "sensitive"
    public static let reasonHarmonyPasteOnly = "harmony_paste_only"
    public static let reasonNotForeground = "not_foreground"
    public static let reasonAlreadyRead = "already_read"
    public static let reasonConfigOff = "config_off"
    public static let reasonWebSuppressed = "web_suppressed"
    public static let reasonSwitchOff = "switch_off"
    public static let reasonNoFocus = "no_focus"
    public static let reasonUnchanged = "unchanged"
    public static let reasonNoDetectHit = "no_detect_hit"

    private static let foregroundTriggers: Set<String> = [eventColdStart, eventForeground]

    // swiftlint:disable:next cyclomatic_complexity
    public static func decide(platform: String, state: ClipboardReadState) -> ClipboardReadDecision {
        switch state.consent {
        case consentAgreed: break
        case consentBasic: return skip(reasonBasicMode)
        default: return skip(reasonPrivacyOutdated)
        }
        if ClipboardSensitive.sensitive(route: state.route, overlay: state.overlay) {
            return skip(reasonSensitive)
        }
        if platform == platformHarmony {
            return ClipboardReadDecision(actionRaw: actionPasteOnly, reasonRaw: reasonHarmonyPasteOnly)
        }
        let triggers = platform == platformAndroid ? foregroundTriggers.union([eventWindowFocus]) : foregroundTriggers
        guard triggers.contains(state.event) else { return skip(reasonNotForeground) }
        if state.readThisForeground {
            return skip(reasonAlreadyRead)
        }
        if !state.configEnabled {
            return skip(reasonConfigOff)
        }
        if state.webSuppressed {
            return skip(reasonWebSuppressed)
        }
        switch platform {
        case platformAndroid:
            if !state.androidAutoSwitch {
                return skip(reasonSwitchOff)
            }
            return state.androidWindowFocused ? ClipboardReadDecision(actionRaw: actionRead) : skip(reasonNoFocus)
        case platformIOS:
            guard state.iosChangeCountChanged else { return skip(reasonUnchanged) }
            guard let hit = state.iosDetectHit else { return ClipboardReadDecision(actionRaw: actionDetect) }
            return hit ? ClipboardReadDecision(actionRaw: actionShowPrompt) : skip(reasonNoDetectHit)
        default:
            return skip(reasonNotForeground)
        }
    }

    /// 向量与 JSON 形态（readPolicy.state）。缺的可选字段按 `ClipboardReadState` 的缺省值；类型不对的按缺失。
    public static func decide(platform: String, state: [String: Any]) -> ClipboardReadDecision {
        var parsed = ClipboardReadState(
            consent: state["consent"] as? String ?? consentOutdated,
            event: state["event"] as? String ?? "",
            route: state["route"] as? String
        )
        parsed.overlay = state["overlay"] as? String ?? ClipboardSensitive.overlayNone
        parsed.configEnabled = flag(state["configEnabled"]) ?? true
        parsed.webSuppressed = flag(state["webSuppressed"]) ?? false
        parsed.readThisForeground = flag(state["readThisForeground"]) ?? false
        parsed.androidAutoSwitch = flag(state["androidAutoSwitch"]) ?? true
        parsed.androidWindowFocused = flag(state["androidWindowFocused"]) ?? true
        parsed.iosChangeCountChanged = flag(state["iosChangeCountChanged"]) ?? true
        parsed.iosDetectHit = flag(state["iosDetectHit"])
        return decide(platform: platform, state: parsed)
    }

    /// 真正的 JSON 布尔（不把 0 / 1 当布尔）。
    static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func skip(_ reason: String) -> ClipboardReadDecision {
        ClipboardReadDecision(actionRaw: actionSkip, reasonRaw: reason)
    }
}
