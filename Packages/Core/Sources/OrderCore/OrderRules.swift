import CouliNetwork
import Foundation
import Generated

// MARK: - 错误 → 动作

/// 错误 → 动作的名字（三端同名）。
public enum OrderErrorKind {
    /// 30701：详情显示空态（范围外、不属于本人、不存在都是它），不重试。
    public static let empty30701 = "empty_30701"
    /// 42901：按 Retry-After（缺省或非法 5 秒）禁用刷新、翻页、筛选与搜索提交、卡片关闭。
    public static let retryAfter = "retry_after"
    /// 5xxxx：错误态带 trace_id 末 6 位（未收录的回落 error.50001）；不伪装成空结果。
    public static let errorTrace6 = "error_trace6"
    /// 10405：强制进入强更。
    public static let forceUpdate = "force_update"
    /// 传输失败、没有可用缓存：网络错误态 +【重试】。
    public static let networkError = "network_error"
    /// 传输失败、有默认视图的缓存：显示缓存与「网络不可用，以下为 {time} 的数据」。
    public static let showStale = "show_stale"
    /// 翻页失败：保留已有结果，底部错误文案（带 trace6）+【重试】。
    public static let pageError = "page_error"
    /// 其余错误：错误态（文案按 error.<code>，没有则通用）。
    public static let error = "error"
}

/// 一次错误的动作。
public struct OrderErrorView: Equatable, Sendable {
    public var actionRaw: String
    public var textKey: String?
    public var disableMs: Int64?
    public var showTrace6 = false
    public var keepItems = false
    public var traceId: String?

    public init(
        actionRaw: String, textKey: String?, disableMs: Int64? = nil, showTrace6: Bool = false, keepItems: Bool = false,
        traceId: String? = nil
    ) {
        self.actionRaw = actionRaw
        self.textKey = textKey
        self.disableMs = disableMs
        self.showTrace6 = showTrace6
        self.keepItems = keepItems
        self.traceId = traceId
    }
}

/// 订单请求的错误 → 动作（03 §4.2、TECH-20 / G10；三端向量 errorAction 组）。target：list_first_page / list_next_page / detail。
/// - 只有传输层失败（断网、超时、自动重试之后仍失败）才用缓存，而且只用于默认视图的第一页与详情；带筛选或搜索词的查询失败显示错误态；
/// - 5xxxx、42901、10405 按各自的码处理，不用缓存冒充；翻页失败一律保留已有结果。
public enum OrderErrorAction {
    public static let listFirst = "list_first_page"
    public static let listNext = "list_next_page"
    public static let detail = "detail"
    public static let notFound = 30701
    public static let staleKey = "net.stale_data"
    public static let networkKey = "order_list.network_error"
    static let genericKey = "error.50001"
    static let rateLimited = 42901
    static let forceUpdate = 10405

    // swiftlint:disable:next function_parameter_count
    public static func view(
        target: String, code: Int?, transport: Bool, disableMs: Int64, traceId: String?, hasCache: Bool,
        filtered: Bool
    ) -> OrderErrorView {
        let next = target == listNext
        guard !transport, let code else {
            if next {
                return OrderErrorView(actionRaw: OrderErrorKind.pageError, textKey: networkKey, keepItems: true)
            }
            if hasCache, !(target == listFirst && filtered) {
                return OrderErrorView(actionRaw: OrderErrorKind.showStale, textKey: staleKey)
            }
            return OrderErrorView(actionRaw: OrderErrorKind.networkError, textKey: networkKey)
        }
        if code == notFound, target == detail {
            return OrderErrorView(actionRaw: OrderErrorKind.empty30701, textKey: "error.\(notFound)")
        }
        if code == rateLimited {
            return OrderErrorView(
                actionRaw: OrderErrorKind.retryAfter, textKey: "error.\(rateLimited)", disableMs: disableMs,
                keepItems: next
            )
        }
        if code == forceUpdate {
            return OrderErrorView(actionRaw: OrderErrorKind.forceUpdate, textKey: "error.\(forceUpdate)")
        }
        if (50000...59999).contains(code) {
            return OrderErrorView(
                actionRaw: next ? OrderErrorKind.pageError : OrderErrorKind.errorTrace6, textKey: serverKey(code),
                showTrace6: true, keepItems: next, traceId: traceId
            )
        }
        let key = DefaultTexts.text("error.\(code)") != nil ? "error.\(code)" : genericKey
        return OrderErrorView(
            actionRaw: next ? OrderErrorKind.pageError : OrderErrorKind.error, textKey: key, keepItems: next,
            traceId: traceId
        )
    }

    /// 未收录的 5xxxx（文案键缺失或为空）回落 error.50001（APP-07 第 9 条）。
    public static func serverKey(_ code: Int) -> String {
        let key = "error.\(code)"
        return (DefaultTexts.text(key) ?? "").isEmpty ? genericKey : key
    }

    // 三端向量的 JSON 出口（headers 里的 Retry-After 按网络层同一个解析：非负整数秒，缺省或非法 5 秒）。
    // swiftlint:disable:next function_parameter_count
    public static func map(
        _ target: String, _ code: Int?, _ transport: Bool, _ headers: [String: String], _ traceId: String?,
        _ hasCache: Bool, _ filtered: Bool
    ) -> [String: Any] {
        let view = view(
            target: target, code: code, transport: transport,
            disableMs: ErrorActionMapper.retryAfterMillis(headers), traceId: traceId, hasCache: hasCache,
            filtered: filtered
        )
        var out: [String: Any] = [
            "actionRaw": view.actionRaw, "textKey": JSONPick.value(view.textKey), "showTrace6": view.showTrace6,
            "keepItems": view.keepItems,
        ]
        if let disable = view.disableMs {
            out["disableMs"] = disable
        }
        return out
    }

    /// 服务端错误结果 → 动作（页面与待跟单卡共用；42901 的时长取网络层 Effect，缺省 5 秒）。
    public static func view(target: String, result: ApiResult, hasCache: Bool, filtered: Bool) -> OrderErrorView {
        switch result {
        case let .failure(code, _, _, traceId, effect, _):
            // 非强更的 10405 按统一错误（F-X-09，FU-IOS-0712）；强更照旧
            view(
                target: target, code: NonForcedUpdate.pageCode(code: code, effect: effect), transport: false,
                disableMs: disableMillis(result), traceId: traceId,
                hasCache: hasCache, filtered: filtered
            )
        default:
            view(
                target: target, code: nil, transport: true, disableMs: 0, traceId: nil, hasCache: hasCache,
                filtered: filtered
            )
        }
    }

    /// 42901 的禁用时长：取网络层 ErrorEffect.disableMillis（缺省 5 秒）；其余为 0。
    public static func disableMillis(_ result: ApiResult) -> Int64 {
        guard case let .failure(code, _, _, _, effect, _) = result, code == rateLimited else { return 0 }
        return effect.disableMillis ?? ErrorActionMapper.defaultRetryAfterMillis
    }

    /// 错误正文 + 追踪编号统一生成（APP-08 共性第 8、16 条）：正文按 format 去掉填不上的占位符（{platform_name} 等），有 trace_id 时
    /// 末 6 位由这里独立追加（文案里有 {trace6} 占位就填进去，没有的如 50301、50303 补「（xxxxxx）」，不依赖占位符）；没有 trace_id 时
    /// 用无编号的 fallback。
    public static func message(_ texts: OrderTexts, _ view: OrderErrorView) -> String {
        let key = view.textKey ?? genericKey
        let trace = String((view.traceId ?? "").suffix(6))
        var body = texts.format(key, trace.isEmpty ? [:] : ["trace6": trace])
        if body.isEmpty {
            body = texts.format(genericKey, trace.isEmpty ? [:] : ["trace6": trace])
        }
        guard !trace.isEmpty, !body.contains(trace) else { return body }
        return body + texts.format(OrderDraftTexts.traceSuffixKey, ["trace6": trace])
    }
}

// MARK: - 待跟单卡

/// 一张待跟单卡（界面）。`linkId` / `attemptId` 取自渲染时的卡片项：关闭请求只带这张卡的 attempt_id（BR-ATTR-21「完成与关闭按尝试」）。
public struct PendingTrackCardView: Equatable, Sendable, Identifiable {
    public let platform: String
    public let attemptId: String
    public let linkId: String
    public let claimEntry: Bool
    public let notificationRow: Bool

    /// 一次尝试的标识（link_id + attempt_id）：忙碌状态与「已关闭」记录都按它（APP-08 共性第 14、15 条）。
    public var key: String {
        PendingTrackCards.key(linkId, attemptId)
    }

    public var id: String {
        key
    }
}

/// 会话与通知权限的取值（三端向量名）。
public enum PendingTrackRaw {
    public static let member = "member"
    public static let guest = "guest"
    public static let notDetermined = "not_determined"
    public static let granted = "granted"
    public static let denied = "denied"
    /// 系统默认允许：不出通知行（G22）。
    public static let systemDefault = "system_default"
}

/// 待跟单卡的显示规则（BR-ATTR-21 ①②③、BR-ID-13 细则「通知权限的申请时机」、G22）：只显示 dismissed=false 的项；同平台多项只显示响应里的
/// 第一项并记日志；找回入口只看 show_claim_entry（客户端不用本机时钟算 30 分钟、72 小时）；通知行只在已登录、系统当前未开启（未决定或被关）
/// 且本机没有申请记录时出现。
public enum PendingTrackCards {
    public static func key(_ linkId: String, _ attemptId: String) -> String {
        linkId + "\u{0}" + attemptId
    }

    public static func cards(
        _ items: [PendingTrack], session: String, notification: String, requestedBefore: Bool
    ) -> [PendingTrackCardView] {
        let row = session == PendingTrackRaw.member
            && (notification == PendingTrackRaw.notDetermined || notification == PendingTrackRaw.denied)
            && !requestedBefore
        var seen = Set<String>()
        return items.filter { !$0.dismissed }.compactMap { item in
            guard seen.insert(item.platform).inserted else {
                OrderLog.warn("pending-tracks: duplicate platform card ignored")
                return nil
            }
            return PendingTrackCardView(
                platform: item.platform, attemptId: item.attemptId, linkId: item.linkId,
                claimEntry: item.showClaimEntry, notificationRow: row
            )
        }
    }

    /// 三端向量的 JSON 出口（cards 精确比较：只有这五个字段）。
    public static func of(
        _ items: [[String: Any]], _ session: String, _ notification: String, _ requestedBefore: Bool
    ) -> [[String: Any]] {
        cards(
            items.compactMap(OrderJSON.pendingTrack), session: session, notification: notification,
            requestedBefore: requestedBefore
        ).map {
            [
                "platform": $0.platform, "attemptId": $0.attemptId, "linkId": $0.linkId, "claimEntry": $0.claimEntry,
                "notificationRow": $0.notificationRow,
            ]
        }
    }
}

/// 关闭的结果 → 动作（三端同名）。
public enum PendingDismissAction {
    public static let hide = "hide"
    public static let refetch = "refetch"
    public static let keepAndToast = "keep_and_toast"
    public static let disable = "disable"
    public static let forceUpdate = "force_update"
    /// 5xxxx 等服务端错误：卡片保留，轻提示对应错误文案 + trace6（未收录的 5xxxx 回落 error.50001；共性第 9 条）。
    public static let errorToast = "error_toast"
}

/// 待跟单卡的关闭（04 §6.4 `POST /v1/orders/pending-tracks/{link_id}/dismiss`，body 只带这张卡的 attempt_id）：
/// 成功 → 隐藏；20001 → 重拉；传输失败 → 保留并轻提示网络错误；42901 → 按 Retry-After 禁用；10405 → 强更；其余服务端错误 → 错误文案 + trace6。
public enum PendingTrackDismiss {
    public static let operation = "dismissPendingTrack"

    public static func path(_ linkId: String) -> String {
        "/v1/orders/pending-tracks/\(linkId)/dismiss"
    }

    public static func body(_ attemptId: String) -> String {
        JSONPick.text(["attempt_id": attemptId])
    }

    public static func request(_ card: [String: Any]) -> [String: Any] {
        let link = card["link_id"] as? String ?? ""
        let attempt = card["attempt_id"] as? String ?? ""
        return ["method": "POST", "path": path(link), "body": ["attempt_id": attempt]]
    }

    public static func action(kind: String, code: Int?, disableMs: Int64) -> (String, Int64?) {
        switch (kind, code) {
        case ("ok", _): (PendingDismissAction.hide, nil)
        case ("transport", _), (_, nil): (PendingDismissAction.keepAndToast, nil)
        case (_, 42901?): (PendingDismissAction.disable, disableMs)
        case (_, 20001?): (PendingDismissAction.refetch, nil)
        case (_, 10405?): (PendingDismissAction.forceUpdate, nil)
        default: (PendingDismissAction.errorToast, nil)
        }
    }

    /// 三端向量的 JSON 出口：outcome = {kind: ok | error | transport, code?, headers?}。
    public static func onOutcome(_ outcome: [String: Any]) -> [String: Any] {
        let headers = (outcome["headers"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        let (action, disable) = action(
            kind: outcome["kind"] as? String ?? "", code: JSONPick.int64(outcome["code"]).map(Int.init),
            disableMs: ErrorActionMapper.retryAfterMillis(headers)
        )
        var out: [String: Any] = ["actionRaw": action]
        if let disable {
            out["disableMs"] = disable
        }
        return out
    }
}

// MARK: - 断网缓存策略

/// 断网显示上次数据（TECH-20，G10）的策略（三端向量 cachePolicy / cacheClear 组）：只缓存默认视图的第一页（全部分组、没有平台、月份、
/// 搜索词，没有 cursor）与最近打开的订单详情；登出、换账号、会话失效、撤回同意、切换环境时删除；进后台、刷新成功不删。落盘见 `OrderCacheStore`。
public enum OrderStaleCache {
    public static let kindList = "list"
    public static let kindDetail = "detail"
    public static let detailLimit = 30
    public static let clearEvents: Set<String> = [
        "logout", "account_switch", "session_invalid", "consent_revoked", "env_switch",
    ]

    public static func isCacheable(_ kind: String, _ query: [String: Any]?) -> Bool {
        switch kind {
        case kindDetail:
            return true
        case kindList:
            let params = query ?? [:]
            return params.allSatisfy { key, value in
                key == "scope" || (key == "status_group" && (value as? String) == OrderQuery.all)
            }
        default:
            return false
        }
    }

    public static func clearsOn(_ event: String) -> Bool {
        clearEvents.contains(event)
    }
}
