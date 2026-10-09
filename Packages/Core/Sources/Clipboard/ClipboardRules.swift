import CryptoKit
import Foundation

/// 本地过滤规则（F-CLIP-02、BR-INV-04 细则；规则空白 G02、G03、G14）。包内默认取原文数值：长度 10～500、排除不超过 20 位的纯数字或
/// 纯字母数字、排除词表为空；邀请触发前提为文本含 `config.share_domains` 任一域名的 `/i/{code}` 落地页，或含「邀请码」字样。
/// 三端同名（iOS / Android / 鸿蒙 ClipboardRules）。
///
/// TODO(N-30) G02：`config.clipboard` 在契约里是 FreeForm，键名与类型没定，`fromConfig` 不按猜测的键名解析，一律用包内默认。
public struct ClipboardRules: Sendable, Equatable {
    public static let defaultMinLength = 10
    public static let defaultMaxLength = 500
    public static let defaultPureAlnumMax = 20
    public static let defaultMaxLinks = 3
    public static let inviteKeywordDefault = "邀请码"

    public var minLength: Int
    public var maxLength: Int
    /// 不超过这个长度的纯数字 / 纯字母数字文本排除（F-CLIP-02）。
    public var pureAlnumMaxLength: Int
    public var excludedWords: [String]
    /// 邀请触发字样（BR-INV-04 细则「含『邀请码』字样」）。
    public var inviteKeyword: String
    /// 上传的链接最多几个（G04：按出现顺序）。
    public var maxUploadLinks: Int

    public init(
        minLength: Int = defaultMinLength,
        maxLength: Int = defaultMaxLength,
        pureAlnumMaxLength: Int = defaultPureAlnumMax,
        excludedWords: [String] = [],
        inviteKeyword: String = inviteKeywordDefault,
        maxUploadLinks: Int = defaultMaxLinks
    ) {
        self.minLength = minLength
        self.maxLength = maxLength
        self.pureAlnumMaxLength = pureAlnumMaxLength
        self.excludedWords = excludedWords
        self.inviteKeyword = inviteKeyword
        self.maxUploadLinks = maxUploadLinks
    }

    public static let defaults = ClipboardRules()

    /// 下发的 config.clipboard（FreeForm）→ 规则。TODO(N-30) G02：结构未定，任何下发值都认不出，整体忽略、用包内默认（不按猜测的键名
    /// 解析）。契约定下键名后在这里解析，认不出的结构仍整体回落。
    public static func fromConfig(_: Any?) -> ClipboardRules {
        defaults
    }
}

/// 文本片段的抽取（G04、BR-TEXT-14 的 30132 预填规则）：只在内存里做，原文不落盘、不进日志。
public enum ClipboardText {
    /// http(s) 链接：只取 ASCII URL 字符，遇到空白、全角与中文标点即止（G03、G04）。
    private static let linkPattern = "(?i)https?://[A-Za-z0-9\\-._~:/?#\\[\\]@!$&'()*+,;=%]+"
    private static let titlePattern = "「([^「」]+)」"

    public static func links(_ text: String) -> [String] {
        matches(linkPattern, in: text).map(\.0)
    }

    /// 「」内的第一段文字（去掉首尾空白）；没有为 nil。
    public static func quotedTitle(_ text: String) -> String? {
        guard let group = matches(titlePattern, in: text).first?.1 else { return nil }
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 30132【用商品名搜索】的预填（BR-TEXT-14：「」内或首行商品名，提取不到留空）。
    public static func searchPrefill(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let title = quotedTitle(text) {
            return title
        }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// 上传内容（G04）：链接（最多 maxLinks 个，按出现顺序）加「」内的标题，换行连接；原文其余部分不上传。
    public static func uploadText(links: [String], text: String, maxLinks: Int) -> String {
        (Array(links.prefix(maxLinks)) + [quotedTitle(text)].compactMap(\.self)).joined(separator: "\n")
    }

    /// NFKC 规范化（全角 → 半角等，BR-INV-04 细则）。
    public static func nfkc(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    /// 本机记录用的 hash（G08：原文 UTF-8 字节的 SHA-256，十六进制）。
    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 按 Unicode 标量计的长度（与 Android 的 codePointCount 一致）。
    public static func length(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    /// (整段匹配, 第一个分组)。
    static func matches(_ pattern: String, in text: String) -> [(String, String?)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let whole = Range(match.range, in: text) else { return nil }
            var group: String?
            if match.numberOfRanges > 1, let first = Range(match.range(at: 1), in: text) {
                group = String(text[first])
            }
            return (String(text[whole]), group)
        }
    }
}

/// 邀请码抽取（BR-INV-04 细则）：NFKC 后转大写，按 `(?<![0-9A-Z])[2-9A-HJ-NP-Z]{6}(?![0-9A-Z])` 取第一个匹配；不判断触发前提。
public enum InviteCodeExtractor {
    private static let pattern = "(?<![0-9A-Z])[2-9A-HJ-NP-Z]{6}(?![0-9A-Z])"

    public static func extract(_ text: String) -> String? {
        ClipboardText.matches(pattern, in: ClipboardText.nfkc(text).uppercased()).first?.0
    }
}
