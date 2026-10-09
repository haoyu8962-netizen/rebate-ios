import Foundation

/// 24 小时内提示过的一条记录（只有 hash 与时间，G08）。
public struct ClipboardPromptStamp: Sendable, Equatable {
    public let hash: String
    public let atMs: Int64

    public init(hash: String, atMs: Int64) {
        self.hash = hash
        self.atMs = atMs
    }
}

/// 分类时的本机状态（纯逻辑 DTO，不是服务端字段）：
/// - selfWritten：App 自己写入剪贴板的内容的 hash（最近 10 条，F-CLIP-02）；
/// - prompted：出过提示条的 hash 与时间（24 小时去重）；
/// - inviteEligible：用户可以绑定上级（游客一律可以；已登录看 getMe，拿不到不可以）；
/// - selfInviteCode：本人的邀请码（本人码不提示）；
/// - shareDomains：config.share_domains（邀请落地页 `/i/{code}` 的域名）；
/// - hash：原文 → hash（生产为 `ClipboardText.sha256`，向量测试注入假 hash）。
public struct ClipboardContext {
    public let selfWritten: [String]
    public let prompted: [ClipboardPromptStamp]
    public let inviteEligible: Bool
    public let selfInviteCode: String?
    public let shareDomains: [String]
    public let hash: (String) -> String

    public init(
        selfWritten: [String],
        prompted: [ClipboardPromptStamp],
        inviteEligible: Bool,
        selfInviteCode: String?,
        shareDomains: [String],
        hash: @escaping (String) -> String = ClipboardText.sha256
    ) {
        self.selfWritten = selfWritten
        self.prompted = prompted
        self.inviteEligible = inviteEligible
        self.selfInviteCode = selfInviteCode
        self.shareDomains = shareDomains
        self.hash = hash
    }
}

/// 分类结果：kindRaw product / invite / none；uploadText 只含本地抽出的片段（G04），原文不在结果里。
public struct ClipboardClassification: Sendable, Equatable {
    public let kindRaw: String
    public let reasonRaw: String?
    public let inviteCode: String?
    public let uploadText: String?
    /// 原文的 hash（出提示条时记入 PromptHistory）。
    public let hash: String?

    public init(
        kindRaw: String, reasonRaw: String? = nil, inviteCode: String? = nil, uploadText: String? = nil,
        hash: String? = nil
    ) {
        self.kindRaw = kindRaw
        self.reasonRaw = reasonRaw
        self.inviteCode = inviteCode
        self.uploadText = uploadText
        self.hash = hash
    }
}

/// 本地分类（brief §2.2；BR-ID-16、BR-INV-04、OPS-06；规则空白 G03、G04、G08、G14）。三端同名。顺序：
/// 1. App 自写的 hash → none（self_written）；
/// 2. 24 小时内（严格小于）提示过的同一 hash → none（prompted_recently）；
/// 3. 商品候选：通过长度、纯字母数字、排除词规则，并且含 http(s) 链接（G03；邀请落地页 `/i/{code}` 链接不算商品链接，A02）→ product；
/// 4. 否则邀请：抽到码、满足触发前提（落地页或「邀请码」字样）、不是本人码、用户可绑定 → invite（不套用商品的长度规则，G14）；
/// 5. 否则 none：抽到了码给邀请的拒绝原因（no_trigger / self_code / not_eligible），抽不到给商品的拒绝原因。
/// 商品优先：同一段文本命中商品就只出商品提示条（OPS-06）。
public enum ClipboardClassifier {
    public static let kindProduct = "product"
    public static let kindInvite = "invite"
    public static let kindNone = "none"

    public static let reasonSelfWritten = "self_written"
    public static let reasonPromptedRecently = "prompted_recently"
    public static let reasonTooShort = "too_short"
    public static let reasonTooLong = "too_long"
    public static let reasonPureAlnum = "pure_alnum"
    public static let reasonExcludedWord = "excluded_word"
    public static let reasonNoLink = "no_link"
    public static let reasonNoTrigger = "no_trigger"
    public static let reasonSelfCode = "self_code"
    public static let reasonNotEligible = "not_eligible"

    /// 同一 hash 的提示间隔（G08：严格小于 24 小时不再提示）。
    public static let promptWindowMs: Int64 = 24 * 60 * 60 * 1000

    public static func classify(
        text: String,
        context: ClipboardContext,
        rules: ClipboardRules,
        nowMs: Int64
    ) -> ClipboardClassification {
        let hash = context.hash(text)
        if context.selfWritten.contains(hash) {
            return none(reasonSelfWritten, hash)
        }
        if context.prompted.contains(where: { $0.hash == hash && withinWindow(nowMs - $0.atMs) }) {
            return none(reasonPromptedRecently, hash)
        }
        let links = productLinks(text, shareDomains: context.shareDomains)
        let productReason = productRejection(text, links: links, rules: rules)
        if productReason == nil {
            return ClipboardClassification(
                kindRaw: kindProduct,
                uploadText: ClipboardText.uploadText(links: links, text: text, maxLinks: rules.maxUploadLinks),
                hash: hash
            )
        }
        guard let code = InviteCodeExtractor.extract(text) else {
            return none(productReason ?? reasonNoLink, hash)
        }
        let inviteReason: String? = if !inviteTriggered(text, shareDomains: context.shareDomains, rules: rules) {
            reasonNoTrigger
        } else if context.selfInviteCode.flatMap(InviteCodeExtractor.extract) == code {
            reasonSelfCode
        } else if !context.inviteEligible {
            reasonNotEligible
        } else {
            nil
        }
        guard let inviteReason else {
            return ClipboardClassification(kindRaw: kindInvite, inviteCode: code, hash: hash)
        }
        return none(inviteReason, hash)
    }

    /// 距上次提示的间隔在 [0, 24 小时) 内（时钟回拨的负值不算）。
    public static func withinWindow(_ elapsed: Int64) -> Bool {
        elapsed >= 0 && elapsed < promptWindowMs
    }

    /// 文本里的商品链接（去掉邀请落地页，A02、A-R3-01）。
    public static func productLinks(_ text: String, shareDomains: [String]) -> [String] {
        ClipboardText.links(text).filter { !inviteLanding($0, shareDomains: shareDomains) }
    }

    /// 商品候选的拒绝原因；nil = 是商品候选（自动识别与手动粘贴同一套，共性第 13、22 条）。
    public static func productRejection(_ text: String, links: [String], rules: ClipboardRules) -> String? {
        let length = ClipboardText.length(text)
        if length < rules.minLength {
            return reasonTooShort
        }
        if length > rules.maxLength {
            return reasonTooLong
        }
        if length <= rules.pureAlnumMaxLength, text.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil {
            return reasonPureAlnum
        }
        if rules.excludedWords.contains(where: { !$0.isEmpty && text.contains($0) }) {
            return reasonExcludedWord
        }
        return links.isEmpty ? reasonNoLink : nil
    }

    /// 邀请触发前提（BR-INV-04 细则）：含 share_domains 任一域名的 `/i/{code}` 落地页链接，或含「邀请码」字样。
    public static func inviteTriggered(
        _ text: String, shareDomains: [String], rules: ClipboardRules = .defaults
    ) -> Bool {
        ClipboardText.nfkc(text).contains(rules.inviteKeyword)
            || ClipboardText.links(text).contains { inviteLanding($0, shareDomains: shareDomains) }
    }

    /// 是不是邀请落地页链接：主机名与 share_domains 之一完全相同（不区分大小写；不认子域、端口与 userinfo，CLIP-18 未定时从严），
    /// 路径为 `/i/{code}`。
    public static func inviteLanding(_ link: String, shareDomains: [String]) -> Bool {
        guard !shareDomains.isEmpty, let schemeEnd = link.range(of: "://") else { return false }
        let rest = link[schemeEnd.upperBound...]
        let hostEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        let host = String(rest[..<hostEnd])
        let path = rest[hostEnd...]
        guard path.hasPrefix(landingPrefix) else { return false }
        let tail = path.dropFirst(landingPrefix.count)
        let segment = String(tail.prefix { !"/?#".contains($0) })
        return shareDomains.contains { $0.caseInsensitiveCompare(host) == .orderedSame }
            && InviteCodeExtractor.extract(segment) != nil
    }

    private static let landingPrefix = "/i/"

    private static func none(_ reason: String, _ hash: String) -> ClipboardClassification {
        ClipboardClassification(kindRaw: kindNone, reasonRaw: reason, hash: hash)
    }
}
