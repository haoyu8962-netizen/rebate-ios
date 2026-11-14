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
    public static let version = "6"
    /// 公共字段名（契约顺序）。
    public static let commonFields: [Swift.String] = ["event_id", "name", "client_at", "session_id", "device_id", "user_id", "platform", "app_version", "channel", "page", "spm", "trace_id"]
    /// 必填的公共字段名。
    public static let requiredCommonFields: [Swift.String] = ["event_id", "name", "client_at", "session_id", "device_id", "platform", "app_version", "page"]
    /// platform 公共字段的取值。
    public static let platformValues: [Swift.String] = ["ios", "android", "harmony", "h5"]
    /// 全部事件名。
    public static let allNames: [Swift.String] = ["link_jump", "external_page_union_host", "external_page_nav_host", "external_page_blocked_nav", "route_entry_blocked", "route_params_dropped", "bridge_call", "sdui_card_error", "agent_stream_seq_gap", "agent_stream_frame_too_large", "agent_stream_limit", "agent_stream_unknown_event", "app_launch", "page_view", "exposure", "click", "search", "convert", "h5_white_screen"]

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
            case requested = "requested"
            case failed = "failed"
            case contractUnknown = "unknown"
        }
        public enum FailureReasonValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case sdkInitFailed = "sdk_init_failed"
            case stepFailed = "step_failed"
        }
        public enum SdkOpenByValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case url = "url"
            case code = "code"
        }
        public enum InstalledValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case `true` = "true"
            case `false` = "false"
            case contractUnknown = "unknown"
        }
    }

    /// link_jump：外跳的每一步结果（BR-ATTR-27 ③；BR-ATTR-21 细则「待跟单卡按实际外跳选」）；另记百川初始化失败（BR-ATTR-27 淘宝行，result=failed 且 failure_reason=sdk_init_failed）
    public static func linkJump(
        page: Swift.String,
        phase: LinkJump.PhaseValue,
        attemptId: Swift.String? = nil,
        linkId: Swift.String? = nil,
        unionPlatform: LinkJump.UnionPlatformValue,
        step: LinkJump.StepValue,
        result: LinkJump.ResultValue,
        failureReason: LinkJump.FailureReasonValue? = nil,
        sdkOpenBy: LinkJump.SdkOpenByValue? = nil,
        sdkErrorCode: Swift.String? = nil,
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
        if let failureReasonValue = failureReason {
            fields["failure_reason"] = .string(failureReasonValue.rawValue)
        }
        if let sdkOpenByValue = sdkOpenBy {
            fields["sdk_open_by"] = .string(sdkOpenByValue.rawValue)
        }
        if let sdkErrorCodeValue = sdkErrorCode {
            fields["sdk_error_code"] = .string(sdkErrorCodeValue)
        }
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
        if fields["result"] == .string("failed"), fields["failure_reason"] == nil {
            missing.append("failure_reason")
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
        schemaVersion: Swift.String,
        bridgeVersion: Swift.String,
        configVersion: Swift.String,
        h5Release: Swift.String,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        var fields: [Swift.String: TrackValue] = [:]
        fields["method"] = .string(method)
        fields["code"] = .integer(code)
        fields["schema_version"] = .string(schemaVersion)
        fields["bridge_version"] = .string(bridgeVersion)
        fields["config_version"] = .string(configVersion)
        fields["h5_release"] = .string(h5Release)
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
        pageVersion: Swift.Int? = nil,
        reason: Swift.String,
        schemaVersion: Swift.String,
        bridgeVersion: Swift.String,
        configVersion: Swift.String,
        h5Release: Swift.String,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        var fields: [Swift.String: TrackValue] = [:]
        fields["type"] = .string(type)
        if let versionValue = version {
            fields["version"] = .integer(versionValue)
        }
        if let pageVersionValue = pageVersion {
            fields["page_version"] = .integer(pageVersionValue)
        }
        fields["reason"] = .string(reason)
        fields["schema_version"] = .string(schemaVersion)
        fields["bridge_version"] = .string(bridgeVersion)
        fields["config_version"] = .string(configVersion)
        fields["h5_release"] = .string(h5Release)
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "sdui_card_error", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// agent_stream_seq_gap：原生 Agent 页流诊断：text.delta 缺号（收到的 seq 大于本地已应用值 +1），本地结束该条消息（03 §7.2）；不带用户消息原文、输入框原文、帧的 data 与 delta、卡片内容和 fallback_text
    public static func agentStreamSeqGap(
        page: Swift.String,
        runId: Swift.String? = nil,
        messageId: Swift.String? = nil,
        schemaVersion: Swift.String,
        bridgeVersion: Swift.String,
        configVersion: Swift.String,
        h5Release: Swift.String,
        expected: Swift.Int,
        received: Swift.Int,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        var fields: [Swift.String: TrackValue] = [:]
        if let runIdValue = runId {
            fields["run_id"] = .string(runIdValue)
        }
        if let messageIdValue = messageId {
            fields["message_id"] = .string(messageIdValue)
        }
        fields["schema_version"] = .string(schemaVersion)
        fields["bridge_version"] = .string(bridgeVersion)
        fields["config_version"] = .string(configVersion)
        fields["h5_release"] = .string(h5Release)
        fields["expected"] = .integer(expected)
        fields["received"] = .integer(received)
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "agent_stream_seq_gap", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// agent_stream_frame_too_large：原生 Agent 页流诊断：单帧 data 超过上限，按协议错误本地结束该条消息（03 §7.2）；只有共有字段，不带帧内容
    public static func agentStreamFrameTooLarge(
        page: Swift.String,
        runId: Swift.String? = nil,
        messageId: Swift.String? = nil,
        schemaVersion: Swift.String,
        bridgeVersion: Swift.String,
        configVersion: Swift.String,
        h5Release: Swift.String,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        var fields: [Swift.String: TrackValue] = [:]
        if let runIdValue = runId {
            fields["run_id"] = .string(runIdValue)
        }
        if let messageIdValue = messageId {
            fields["message_id"] = .string(messageIdValue)
        }
        fields["schema_version"] = .string(schemaVersion)
        fields["bridge_version"] = .string(bridgeVersion)
        fields["config_version"] = .string(configVersion)
        fields["h5_release"] = .string(h5Release)
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "agent_stream_frame_too_large", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// agent_stream_limit 的枚举字段取值。
    public enum AgentStreamLimit {
        public enum KindValue: Swift.String, Swift.Sendable, Swift.CaseIterable {
            case text = "text"
            case cards = "cards"
            case frames = "frames"
        }
    }

    /// agent_stream_limit：原生 Agent 页流诊断：同一 run 的累计文本、卡片数或内容帧数超过输出上限，本地结束该条消息（03 §7.2；上限见 02 §9.2）
    public static func agentStreamLimit(
        page: Swift.String,
        runId: Swift.String? = nil,
        messageId: Swift.String? = nil,
        schemaVersion: Swift.String,
        bridgeVersion: Swift.String,
        configVersion: Swift.String,
        h5Release: Swift.String,
        kind: AgentStreamLimit.KindValue,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        var fields: [Swift.String: TrackValue] = [:]
        if let runIdValue = runId {
            fields["run_id"] = .string(runIdValue)
        }
        if let messageIdValue = messageId {
            fields["message_id"] = .string(messageIdValue)
        }
        fields["schema_version"] = .string(schemaVersion)
        fields["bridge_version"] = .string(bridgeVersion)
        fields["config_version"] = .string(configVersion)
        fields["h5_release"] = .string(h5Release)
        fields["kind"] = .string(kind.rawValue)
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "agent_stream_limit", page: page, spm: spm, traceId: traceId, fields: fields,
            missingRequired: missing
        )
    }

    /// agent_stream_unknown_event：原生 Agent 页流诊断：收到不在 04 §8.2 表内的 event 类型，忽略该帧、不中断流（03 §7.2）
    public static func agentStreamUnknownEvent(
        page: Swift.String,
        runId: Swift.String? = nil,
        messageId: Swift.String? = nil,
        schemaVersion: Swift.String,
        bridgeVersion: Swift.String,
        configVersion: Swift.String,
        h5Release: Swift.String,
        type: Swift.String,
        spm: Swift.String? = nil,
        traceId: Swift.String? = nil
    ) -> TrackEvent {
        var fields: [Swift.String: TrackValue] = [:]
        if let runIdValue = runId {
            fields["run_id"] = .string(runIdValue)
        }
        if let messageIdValue = messageId {
            fields["message_id"] = .string(messageIdValue)
        }
        fields["schema_version"] = .string(schemaVersion)
        fields["bridge_version"] = .string(bridgeVersion)
        fields["config_version"] = .string(configVersion)
        fields["h5_release"] = .string(h5Release)
        fields["type"] = .string(type)
        let missing: [Swift.String] = []
        return TrackEvent(
            name: "agent_stream_unknown_event", page: page, spm: spm, traceId: traceId, fields: fields,
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
