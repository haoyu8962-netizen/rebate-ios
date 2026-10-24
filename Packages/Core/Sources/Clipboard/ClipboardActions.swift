import CouliNetwork
import Foundation

/// parse 的一条结果（多卡弹层按搜索卡样式列出；行内 error_code 的那条按该码处理，共性第 5 条）。
public struct ParseRow: @unchecked Sendable {
    public let card: [String: Any]?
    public let errorCode: Int?
    public let hitRaw: String?

    public init(card: [String: Any]?, errorCode: Int?, hitRaw: String?) {
        self.card = card
        self.errorCode = errorCode
        self.hitRaw = hitRaw
    }
}

/// parse 结果到页面动作（brief §2.6；规则空白 G09、CLIP-19、CLIP-20）：
/// - open_detail：只有 1 张卡 → 以进程内的卡片种子打开 ProductDetail，沿用这张卡的 linkId（G09）；
/// - card_list：多条结果 → 当前页弹层按搜索卡样式列出（rows，行内 error_code 逐条按码处理）；
/// - notice：30131 / 30141 等只提示（textKey）；
/// - search_prefill：30132 → error.30132 加【用商品名搜索】（prefill 取「」内或首行，提取不到留空）；
/// - retry_after：42901 → 按 Retry-After 禁用粘贴入口与提示条按钮 disableMs（缺省、非法、0 都按 5 秒）；
/// - error：5xxxx 等 → error.<code>，有 trace_id 时带末 6 位（showTrace6）；
/// - force_update：行内 10405（外层成功）→ 执行层主动进强更（共性第 20、21 条）。
public struct ParseAction: @unchecked Sendable {
    public var actionRaw: String
    public var linkId: String?
    public var prefill: String?
    public var textKey: String?
    public var showTrace6: Bool?
    public var disableMs: Int64?
    public var card: [String: Any]?
    public var rows: [ParseRow] = []
    public var errorCode: Int?
    public var traceId: String?
    /// 来自结果行的 error_code（外层成功）：网络层没见到，行内 10405 要由执行层主动进强更（共性第 20 条）。
    public var inline = false
    /// 整体 10405 且网络层判定确需强更（ErrorEffect.kind=forceUpdate）：网络层不再替 parse 进强更，由执行层复核归属后进入（共性第 29 条）。
    public var networkForced = false
    /// 整体 10405 带来的最低支持版本（data.min_supported_version；没有为 nil，按服务端判定处理）。
    public var minSupportedVersion: String?
    /// 网络层传输失败的原因（ApiResult.transportFailure 的 kind，原样透传；不是传输失败为 nil）。
    public var transportKind: String?
    /// 可【重试】的传输失败：只有 kind 为 timeout / disconnect（含无网）/ no_envelope 时为 true（FU-IOS-0730 三端口径）。
    /// 空结果、业务错误码、cancelled、刷新暂时失败沿用的原因（如 session_unreadable）都不设，按既有对应状态显示。
    public var retryable = false

    public init(actionRaw: String) {
        self.actionRaw = actionRaw
    }
}

public enum ParseResultAction {
    public static let openDetail = "open_detail"
    public static let cardList = "card_list"
    public static let notice = "notice"
    public static let searchPrefill = "search_prefill"
    public static let retryAfter = "retry_after"
    public static let error = "error"
    public static let forceUpdate = "force_update"

    public static let unsupported = 30131
    public static let unrecognized = 30132
    public static let offShelf = 30141
    public static let rateLimited = 42901
    public static let forceUpdateCode = 10405
    public static let serverErrorMin = 50000
    public static let genericErrorKey = "error.50001"

    /// response 原样是 ParseInputResponse 外壳（code、data.results、trace_id）；errorCode 为整体失败的业务码。
    public static func map(
        response: [String: Any]?,
        errorCode: Int?,
        retryAfter: String?,
        traceId: String?
    ) -> ParseAction {
        let trace = traceId ?? (response?["trace_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let errorCode, errorCode != 0 {
            return failure(errorCode, retryAfter: retryAfter, traceId: trace, hitRaw: nil)
        }
        let data = response?["data"] as? [String: Any]
        let rows = (data?["results"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.map { row in
            ParseRow(
                card: row["card"] as? [String: Any],
                errorCode: integer(row["error_code"]),
                hitRaw: (row["hit"] as? [String: Any])?["raw"] as? String
            )
        }.filter { $0.card != nil || $0.errorCode != nil }
        if rows.isEmpty {
            var action = ParseAction(actionRaw: error)
            action.textKey = genericErrorKey
            action.showTrace6 = trace != nil
            action.traceId = trace
            return action
        }
        if rows.count > 1 {
            var action = ParseAction(actionRaw: cardList)
            action.rows = rows
            action.traceId = trace
            // 行内 10405：整体仍按多卡列出，执行层另外主动进强更（共性第 20 条）
            if rows.contains(where: { $0.card == nil && $0.errorCode == forceUpdateCode }) {
                action.errorCode = forceUpdateCode
                action.inline = true
            }
            return action
        }
        if let card = rows[0].card {
            var action = ParseAction(actionRaw: openDetail)
            action.linkId = card["link_id"] as? String
            action.card = card
            action.traceId = trace
            return action
        }
        var action = failure(rows[0].errorCode ?? serverErrorMin + 1, retryAfter: retryAfter, traceId: trace,
                             hitRaw: rows[0].hitRaw)
        action.inline = true
        return action
    }

    static func failure(_ code: Int, retryAfter: String?, traceId: String?, hitRaw: String?) -> ParseAction {
        var action: ParseAction
        switch code {
        case unrecognized:
            action = ParseAction(actionRaw: searchPrefill)
            action.prefill = ClipboardText.searchPrefill(hitRaw)
            action.textKey = key(code)
        case rateLimited:
            action = ParseAction(actionRaw: Self.retryAfter)
            action.textKey = key(code)
            action.disableMs = retryAfterMillis(retryAfter)
        case forceUpdateCode:
            action = ParseAction(actionRaw: forceUpdate)
        case serverErrorMin...:
            action = ParseAction(actionRaw: error)
            action.textKey = key(code)
            action.showTrace6 = traceId != nil
        default:
            // 30131、30141 与其余业务码：只提示（30141 在多卡弹层里另按置灰处理）
            action = ParseAction(actionRaw: notice)
            action.textKey = key(code)
        }
        action.errorCode = code
        action.traceId = traceId
        return action
    }

    /// Retry-After 的非负整数秒（与网络层同一个解析）；缺省、非法、0 都按 5 秒（A11）。
    public static func retryAfterMillis(_ raw: String?) -> Int64 {
        guard let raw else { return ErrorActionMapper.defaultRetryAfterMillis }
        let parsed = ErrorActionMapper.retryAfterMillis([HeaderNames.retryAfter: raw])
        return parsed > 0 ? parsed : ErrorActionMapper.defaultRetryAfterMillis
    }

    public static func key(_ code: Int) -> String {
        "error.\(code)"
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }
}

/// 手动粘贴的动作（brief §2.5；G10）：parse / open_search_typing / search_prefill / invite / none / fill_invite /
/// invite_not_found。
public struct ManualPasteDecision: Sendable, Equatable {
    public let actionRaw: String
    public var uploadText: String?
    public var prefill: String?
    public var code: String?
    public var textKey: String?

    public init(
        actionRaw: String, uploadText: String? = nil, prefill: String? = nil, code: String? = nil,
        textKey: String? = nil
    ) {
        self.actionRaw = actionRaw
        self.uploadText = uploadText
        self.prefill = prefill
        self.code = code
        self.textKey = textKey
    }
}

/// 用户主动粘贴（首页「去粘贴」、首页提示条里的系统粘贴控件、SearchTyping「粘贴查返利」、登录页邀请码【粘贴】）：
/// - 商品入口（home、search_typing）：剪贴板为空 → 进 SearchTyping（flow-map 23.2.25）；与自动识别同一套过滤（共性第 13、17、22 条）：
///   App 自写的内容不上传；通过长度 / 形态规则且有商品链接 → 只上传商品链接与「」标题（G04），邀请落地页不算商品链接；只有邀请内容
///   （落地页或「邀请码」字样且抽到码）→ invite，只在本地抽码，不发 parse（自写内容的纯邀请静默 none，H02 细化）；其余非空内容 → 不上传，
///   本地显示 30132 的同一种提示（G10）；
/// - 登录页邀请码（login_invite）：只抽码填入输入框；抽不到 → 轻提示「未识别到邀请码」，不清空已有输入（BR-INV-04）。
public enum ManualPasteAction {
    public static let entryHome = "home"
    public static let entrySearchTyping = "search_typing"
    public static let entryLoginInvite = "login_invite"

    public static let parse = "parse"
    public static let openSearchTyping = "open_search_typing"
    public static let searchPrefill = "search_prefill"
    public static let invite = "invite"
    public static let none = "none"
    public static let fillInvite = "fill_invite"
    public static let inviteNotFound = "invite_not_found"

    public static func decide(
        entry: String,
        text: String?,
        rules: ClipboardRules,
        shareDomains: [String] = [],
        selfWritten: Bool = false
    ) -> ManualPasteDecision {
        if entry == entryLoginInvite {
            guard let code = text.flatMap(InviteCodeExtractor.extract) else {
                return ManualPasteDecision(actionRaw: inviteNotFound)
            }
            return ManualPasteDecision(actionRaw: fillInvite, code: code)
        }
        guard let text, !text.isEmpty else { return ManualPasteDecision(actionRaw: openSearchTyping) }
        let links = ClipboardClassifier.productLinks(text, shareDomains: shareDomains)
        if !selfWritten, ClipboardClassifier.productRejection(text, links: links, rules: rules) == nil {
            return ManualPasteDecision(
                actionRaw: parse,
                uploadText: ClipboardText.uploadText(links: links, text: text, maxLinks: rules.maxUploadLinks)
            )
        }
        if let code = InviteCodeExtractor.extract(text),
           ClipboardClassifier.inviteTriggered(text, shareDomains: shareDomains, rules: rules) {
            return selfWritten ? ManualPasteDecision(actionRaw: none) : ManualPasteDecision(
                actionRaw: invite,
                code: code
            )
        }
        return ManualPasteDecision(
            actionRaw: searchPrefill,
            prefill: ClipboardText.searchPrefill(text),
            textKey: ParseResultAction.key(ParseResultAction.unrecognized)
        )
    }
}

/// 邀请确认的去向（brief §2.7）：prefill_login / bind_phone_first / backfill_pending_contract / none。
public struct InviteConfirmDecision: Sendable, Equatable {
    public let actionRaw: String
}

/// 邀请提示条点确认之后（BR-INV-04 细则；规则空白 G01、G16）：
/// - 游客：码放进进程内的预填容器，经 Router 打开 Login，随登录提交（不发请求、不持久化）；
/// - 已登录、可补填：未绑手机 → 先绑手机（bind_phone_first）；已绑手机 → 契约没有 `POST /v1/me/inviter` 与 InviteBackfill 路由（G01），
///   只给判定值 backfill_pending_contract，界面不出已登录用户的邀请提示条；
/// - getMe 拿不到、不可补填、已有上级 → none。
public enum InviteConfirmAction {
    public static let sessionGuest = "guest"
    public static let sessionMember = "member"
    public static let sessionPhone = "phone"

    public static let prefillLogin = "prefill_login"
    public static let bindPhoneFirst = "bind_phone_first"
    public static let backfillPendingContract = "backfill_pending_contract"
    public static let none = "none"

    public static func decide(session: String, me: [String: Any]?) -> InviteConfirmDecision {
        if session == sessionGuest {
            return InviteConfirmDecision(actionRaw: prefillLogin)
        }
        guard InviteEligibility.loggedInEligible(me) else { return InviteConfirmDecision(actionRaw: none) }
        switch session {
        case sessionMember:
            return InviteConfirmDecision(actionRaw: bindPhoneFirst)
        case sessionPhone:
            // TODO(N-30) G01：契约补 POST /v1/me/inviter 与 InviteBackfill 路由前不发任何绑定请求
            return InviteConfirmDecision(actionRaw: backfillPendingContract)
        default:
            return InviteConfirmDecision(actionRaw: none)
        }
    }
}

/// 可绑定判定（brief §2.7）：游客一律可以；已登录只看 getMe 的 invite_backfill.eligible 与 inviter_bound，拿不到或未知时不可以。
public enum InviteEligibility {
    public static func of(guest: Bool, me: [String: Any]?) -> Bool {
        guest || loggedInEligible(me)
    }

    public static func loggedInEligible(_ me: [String: Any]?) -> Bool {
        let bound = ClipboardReadPolicy.flag(me?["inviter_bound"])
        let eligible = ClipboardReadPolicy.flag((me?["invite_backfill"] as? [String: Any])?["eligible"])
        return bound == false && eligible == true
    }
}
