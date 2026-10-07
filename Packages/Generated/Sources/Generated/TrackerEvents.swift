// 生成物，禁止手改；来源 contract.lock
// 快照：specs/events.yaml（03 §4.7；TECH-21：业务代码只能调用这里的生成函数）

/// 埋点字段的值（JSON 标量）。
public enum TrackValue: Swift.Sendable, Swift.Equatable {
    case string(Swift.String)
    case integer(Swift.Int)
    case boolean(Swift.Bool)
}

/// 一条埋点事件：只能由 `TrackerEvents` 的生成函数构造（初始化方法不公开）。公共字段里 page、spm、trace_id
/// 由调用方给出，其余（event_id、client_at、session_id、device_id、user_id、platform、app_version、channel）由 Tracker 填。
public struct TrackEvent: Swift.Sendable, Swift.Equatable {
    public let name: Swift.String
    public let page: Swift.String
    public let spm: Swift.String?
    public let traceId: Swift.String?
    /// 事件自身的字段（不含公共字段）；没给的可选字段不出现。
    public let fields: [Swift.String: TrackValue]
    /// 按 required_when 应该给却没给的字段名；非空时 Tracker 拒收。
    public let missingRequired: [Swift.String]

    init(
        name: Swift.String,
        page: Swift.String,
        spm: Swift.String?,
        traceId: Swift.String?,
        fields: [Swift.String: TrackValue],
        missingRequired: [Swift.String]
    ) {
        self.name = name
        self.page = page
        self.spm = spm
        self.traceId = traceId
        self.fields = fields
        self.missingRequired = missingRequired
    }
}

/// events.yaml 的事件构造函数。
public enum TrackerEvents {
    /// events.yaml 的 version。
    public static let version = "1"
    /// 公共字段名（契约顺序）。
    public static let commonFields: [Swift.String] = ["event_id", "name", "client_at", "session_id", "device_id", "user_id", "platform", "app_version", "channel", "page", "spm", "trace_id"]
    /// 必填的公共字段名。
    public static let requiredCommonFields: [Swift.String] = ["event_id", "name", "client_at", "session_id", "device_id", "platform", "app_version", "page"]
    /// platform 公共字段的取值。
    public static let platformValues: [Swift.String] = ["ios", "android", "harmony", "h5"]
    /// 全部事件名。
    public static let allNames: [Swift.String] = ["link_jump", "external_page_union_host", "external_page_nav_host", "external_page_blocked_nav", "route_entry_blocked", "route_params_dropped", "bridge_call", "sdui_card_error", "app_launch", "page_view", "exposure", "click", "search", "convert", "h5_white_screen"]

    /// link_jump 的枚举字段取值。
    public enum LinkJump {
        public enum PhaseValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case purchase = "purchase"
            case startup = "startup"
        }
        public enum UnionPlatformValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case taobao = "taobao"
            case jd = "jd"
            case pdd = "pdd"
            case meituan = "meituan"
            case vip = "vip"
            case douyin = "douyin"
            case eleme = "eleme"
            case kuaishou = "kuaishou"
            case suning = "suning"
        }
        public enum StepValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case sdk = "sdk"
            case scheme = "scheme"
            case universalLink = "universal_link"
            case h5 = "h5"
            case copyTpwd = "copy_tpwd"
        }
        public enum ResultValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case launched = "launched"
            case failed = "failed"
            case sdkInitFailed = "sdk_init_failed"
            case copied = "copied"
        }
        public enum InstalledValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case `true` = "true"
            case `false` = "false"
            case contractUnknown = "unknown"
        }
    }

    /// link_jump：外跳的每一步结果（BR-ATTR-27 ③；BR-ATTR-21 细则「待跟单卡按实际外跳选」）；另记百川初始化失败（BR-ATTR-27 淘宝行）
    public static func linkJump(
        page: Swift.String,
        phase: LinkJump.PhaseValue,
        attemptId: Swift.String? = nil,
        linkId: Swift.String? = nil,
        unionPlatform: LinkJump.UnionPlatformValue,
        step: LinkJump.StepValue,
        result: LinkJump.ResultValue,
        durationMs: Swift.Int? = nil,
        installed: LinkJump.InstalledValue? = nil,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        var fields: [Swift.String: TrackValue] = [:]
        fields["phase"] = .string(phase.rawValue)
        if let attemptIdValue = attemptId {
            fields["attempt_id"] = .string(attemptIdValue)
        }
        if let linkIdValue = linkId {
            fields["link_id"] = .string(linkIdValue)
        }
        fields["union_platform"] = .string(unionPlatform.rawValue)
        fields["step"] = .string(step.rawValue)
        fields["result"] = .string(result.rawValue)
        if let durationMsValue = durationMs {
            fields["duration_ms"] = .integer(durationMsValue)
        }
        if let installedValue = installed {
            fields["installed"] = .string(installedValue.rawValue)
        }
        var missing: [Swift.String] = []
        if fields["phase"] == .string("purchase"), fields["attempt_id"] == nil {
            missing.append("attempt_id")
        }
        if fields["phase"] == .string("purchase"), fields["link_id"] == nil {
            missing.append("link_id")
        }
        if fields["phase"] == .string("purchase"), fields["duration_ms"] == nil {
            missing.append("duration_ms")
        }
        if fields["phase"] == .string("purchase"), fields["installed"] == nil {
            missing.append("installed")
        }
        return TrackEvent(
            name: "link_jump", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// external_page_union_host 的枚举字段取值。
    public enum ExternalPageUnionHost {
        public enum UnionPlatformValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case taobao = "taobao"
            case jd = "jd"
            case pdd = "pdd"
            case meituan = "meituan"
            case vip = "vip"
            case douyin = "douyin"
            case eleme = "eleme"
            case kuaishou = "kuaishou"
            case suning = "suning"
        }
        public enum CategoryValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case product = "product"
            case promo = "promo"
            case unionHost = "union_host"
        }
        public enum FrameValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case initial = "initial"
            case main = "main"
            case subframe = "subframe"
            case newWindow = "new_window"
        }
        public enum OutcomeValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case parseOk = "parse_ok"
            case parseFailed = "parse_failed"
            case block = "block"
        }
    }

    /// external_page_union_host：第三方页容器里命中联盟平台网页域名的导航（BR-ATTR-29 ②，每次命中一条）
    public static func externalPageUnionHost(
        page: Swift.String,
        unionPlatform: ExternalPageUnionHost.UnionPlatformValue,
        category: ExternalPageUnionHost.CategoryValue,
        frame: ExternalPageUnionHost.FrameValue,
        outcome: ExternalPageUnionHost.OutcomeValue,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        var fields: [Swift.String: TrackValue] = [:]
        fields["union_platform"] = .string(unionPlatform.rawValue)
        fields["category"] = .string(category.rawValue)
        fields["frame"] = .string(frame.rawValue)
        fields["outcome"] = .string(outcome.rawValue)
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "external_page_union_host", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// external_page_nav_host 的枚举字段取值。
    public enum ExternalPageNavHost {
        public enum FrameValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case initial = "initial"
            case main = "main"
            case subframe = "subframe"
            case newWindow = "new_window"
        }
    }

    /// external_page_nav_host：容器内文档级导航的抽样埋点（采样率 /v1/config external_page.nav_host_sample_bp；BR-ATTR-29 细则「覆盖限制与待定事项」）
    public static func externalPageNavHost(
        page: Swift.String,
        registeredDomain: Swift.String,
        frame: ExternalPageNavHost.FrameValue,
        hit: Swift.Bool,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        var fields: [Swift.String: TrackValue] = [:]
        fields["registered_domain"] = .string(registeredDomain)
        fields["frame"] = .string(frame.rawValue)
        fields["hit"] = .boolean(hit)
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "external_page_nav_host", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// external_page_blocked_nav 的枚举字段取值。
    public enum ExternalPageBlockedNav {
        public enum KindValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case http = "http"
            case appScheme = "app_scheme"
            case intent = "intent"
            case market = "market"
            case tel = "tel"
            case sms = "sms"
            case mailto = "mailto"
            case otherScheme = "other_scheme"
            case download = "download"
        }
        public enum FrameValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case initial = "initial"
            case main = "main"
            case subframe = "subframe"
            case newWindow = "new_window"
        }
    }

    /// external_page_blocked_nav：第三方页容器取消的非 https 跳转与下载（只记类别）
    public static func externalPageBlockedNav(
        page: Swift.String,
        kind: ExternalPageBlockedNav.KindValue,
        frame: ExternalPageBlockedNav.FrameValue,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        var fields: [Swift.String: TrackValue] = [:]
        fields["kind"] = .string(kind.rawValue)
        fields["frame"] = .string(frame.rawValue)
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "external_page_blocked_nav", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// route_entry_blocked 的枚举字段取值。
    public enum RouteEntryBlocked {
        public enum EntryValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case inApp = "in_app"
            case push = "push"
            case deeplink = "deeplink"
        }
    }

    /// route_entry_blocked：深链或推送命中不允许的入口（BR-ID-10 细则「路由入口矩阵」）
    public static func routeEntryBlocked(
        page: Swift.String,
        route: Swift.String,
        entry: RouteEntryBlocked.EntryValue,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        var fields: [Swift.String: TrackValue] = [:]
        fields["route"] = .string(route)
        fields["entry"] = .string(entry.rawValue)
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "route_entry_blocked", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// route_params_dropped 的枚举字段取值。
    public enum RouteParamsDropped {
        public enum RouteValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case withdraw = "Withdraw"
            case payoutAccount = "PayoutAccount"
            case laborAgreement = "LaborAgreement"
            case realName = "RealName"
        }
    }

    /// route_params_dropped：打开不接受参数的资金与实名页面时丢弃了参数（功能对照 G-69）
    public static func routeParamsDropped(
        page: Swift.String,
        route: RouteParamsDropped.RouteValue,
        droppedCount: Swift.Int,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        var fields: [Swift.String: TrackValue] = [:]
        fields["route"] = .string(route.rawValue)
        fields["dropped_count"] = .integer(droppedCount)
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "route_params_dropped", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// bridge_call：JSBridge 调用被拒（规划/03 §5.3；BR-ATTR-29 细则「桥方法不留没有归因的打开入口」）；当前只记拒绝，强更状态未知时以 90500 拒绝的调用要不要记待定
    public static func bridgeCall(
        page: Swift.String,
        method: Swift.String,
        code: Swift.Int,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        var fields: [Swift.String: TrackValue] = [:]
        fields["method"] = .string(method)
        fields["code"] = .integer(code)
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "bridge_call", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// sdui_card_error：SDUI 卡片解码失败，只丢弃这一项（规划/03 §6 解码隔离）
    public static func sduiCardError(
        page: Swift.String,
        type: Swift.String,
        version: Swift.Int? = nil,
        pageVersion: Swift.Int,
        reason: Swift.String,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        var fields: [Swift.String: TrackValue] = [:]
        fields["type"] = .string(type)
        if let versionValue = version {
            fields["version"] = .integer(versionValue)
        }
        fields["page_version"] = .integer(pageVersion)
        fields["reason"] = .string(reason)
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "sdui_card_error", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// app_launch：App 启动（字段待定）
    public static func appLaunch(
        page: Swift.String,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        let fields: [Swift.String: TrackValue] = [:]
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "app_launch", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// page_view：页面浏览（字段待定）
    public static func pageView(
        page: Swift.String,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        let fields: [Swift.String: TrackValue] = [:]
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "page_view", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// exposure：卡片曝光（字段待定）
    public static func exposure(
        page: Swift.String,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        let fields: [Swift.String: TrackValue] = [:]
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "exposure", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// click：点击（字段待定）
    public static func click(
        page: Swift.String,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        let fields: [Swift.String: TrackValue] = [:]
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "click", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// search：搜索（字段待定）
    public static func search(
        page: Swift.String,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        let fields: [Swift.String: TrackValue] = [:]
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "search", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// convert：转链（字段待定）
    public static func convert(
        page: Swift.String,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        let fields: [Swift.String: TrackValue] = [:]
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "convert", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// h5_white_screen：H5 白屏（字段待定）
    public static func h5WhiteScreen(
        page: Swift.String,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        let fields: [Swift.String: TrackValue] = [:]
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "h5_white_screen", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }
}
