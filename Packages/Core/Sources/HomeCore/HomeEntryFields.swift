import Foundation

/// 金刚区条目的徽标（契约 `$defs/badge`，BR-TEXT-29）：kind = text 才有 text；expire_at 起隐藏徽标、保留条目。
/// kind = dot 只解析不显示（红点样式另登 FU-IOS-HOME-BADGE-DOT，D10-2998 (b)）。
struct HomeBadge: Sendable, Equatable {
    enum Kind: String, Sendable { case none, dot, text }
    let kind: Kind
    let text: String?
    let expireMillis: Int64?

    /// 此刻可显示的徽标文字：kind = text 且未到期（now < expire_at）才有，其余 nil。
    func shownText(at now: Int64) -> String? {
        guard kind == .text, expireMillis.map({ now < $0 }) ?? true else { return nil }
        return text
    }

    /// 还要在将来某刻隐藏的文字徽标的到期时刻（并进 rebuild 的 transitions）；已到期或不显示的为 nil。
    func pendingExpiry(after now: Int64) -> Int64? {
        guard kind == .text, let expireMillis, expireMillis > now else { return nil }
        return expireMillis
    }
}

/// 金刚区条目的图片位与徽标的严格解析（契约 icon_grid_item / icon_asset / badge / instant；D10-2998、D10-3054、D10-3069、D10-3076）。
enum HomeEntryValue {
    /// 图片位：icon 缺或为 null 才取 image（只认 https，不认 builtin:，D10-3054）；icon 为对象按 icon_asset 取 url（.svg 丢这一条，
    /// FU-IOS-HOME-ICON-SVG）；icon 为字符串照旧（builtin 白名单或 https）。icon 给了但不合法 → nil，不回落 image（D10-3069）。
    static func picture(_ json: [String: Any]) -> String? {
        guard let icon = json["icon"], !(icon is NSNull) else { return HomeValue.https(json["image"]) }
        if let asset = icon as? [String: Any] {
            return iconAsset(asset)
        }
        return HomeValue.image(icon)
    }

    /// `$defs/icon_asset`：恰好 url、sha256 两键；url 合契约 pattern 且不超过 2048 个码点，sha256 为 64 位小写 hex。首页不做摘要校验。
    static func iconAsset(_ json: [String: Any]) -> String? {
        guard Set(json.keys) == ["url", "sha256"], let url = json["url"] as? String,
              let sha256 = json["sha256"] as? String, isDigest(Substring(sha256)),
              url.unicodeScalars.count <= 2048, matchesAssetURL(url), !url.hasSuffix(".svg") else { return nil }
        return url
    }

    /// 契约 pattern `^https://[^\s/?#]+/([^\s?#]*/)?[0-9a-f]{64}\.(png|svg)$` 的逐字实现（不经 NSRegularExpression：
    /// 它的 `$` 会放过末尾换行，`\s` 也与 JSON Schema 的 ECMA 口径不同）。
    static func matchesAssetURL(_ url: String) -> Bool {
        guard url.hasPrefix("https://"), !url.unicodeScalars.contains(where: isSpace) else { return false }
        let rest = url.dropFirst("https://".count)
        guard !rest.contains("?"), !rest.contains("#"), let slash = rest.firstIndex(of: "/"),
              slash != rest.startIndex else { return false }
        let path = rest[rest.index(after: slash)...]
        let suffixLength = 64 + ".png".count
        guard path.count >= suffixLength else { return false }
        let file = path.suffix(suffixLength)
        let head = path.dropLast(suffixLength)
        guard head.isEmpty || head.hasSuffix("/") else { return false }
        return isDigest(file.prefix(64)) && [".png", ".svg"].contains(String(file.suffix(4)))
    }

    /// ECMA-262 `\s`（WhiteSpace + LineTerminator）与 Unicode White_Space 的并集，宁严勿宽。
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar.value == 0xFEFF
    }

    private static func isDigest(_ text: Substring) -> Bool {
        text.unicodeScalars.count == 64 && text.unicodeScalars.allSatisfy {
            (0x30...0x39).contains($0.value) || (0x61...0x66).contains($0.value)
        }
    }

    /// `$defs/badge`：对象、键只在 kind / text / expire_at 内；kind ∈ none / dot / text；text 只在 kind = text 时出现且为 1–2 个码点的字符串；
    /// expire_at 出现（含 null）就须合 instant。不合法 → nil（只丢徽标、保留条目，D10-2998 (a)）。
    static func badge(_ value: Any?) -> HomeBadge? {
        guard let json = value as? [String: Any], Set(json.keys).isSubset(of: ["kind", "text", "expire_at"]),
              let raw = json["kind"] as? String, let kind = HomeBadge.Kind(rawValue: raw) else { return nil }
        var expire: Int64?
        if let rawExpire = json["expire_at"] {
            guard let millis = instant(rawExpire) else { return nil }
            expire = millis
        }
        guard kind == .text else {
            return json["text"] == nil ? HomeBadge(kind: kind, text: nil, expireMillis: expire) : nil
        }
        guard let text = json["text"] as? String, (1...2).contains(text.unicodeScalars.count) else { return nil }
        return HomeBadge(kind: .text, text: text, expireMillis: expire)
    }

    /// `$defs/instant` 严格解析（D10-3076 (2)）：`yyyy-MM-ddTHH:mm:ss(.f{1,6})?+08:00`，且是真实日历时刻（外推公历，0000 年按闰年）；
    /// 拆字段换算绝对毫秒，小数取前 3 位截断。不用 ISO8601DateFormatter、不用 HomeValue.millis。
    static func instant(_ value: Any?) -> Int64? {
        guard let string = value as? String else { return nil }
        let bytes = Array(string.utf8)
        let core = bytes.count - 6
        guard core == 19 || (21...26).contains(core), bytes[core...].elementsEqual("+08:00".utf8),
              core == 19 || bytes[19] == UInt8(ascii: ".") else { return nil }
        let separators: [Int: Character] = [4: "-", 7: "-", 10: "T", 13: ":", 16: ":"]
        for index in 0..<core where index != 19 {
            let byte = bytes[index]
            if let separator = separators[index] {
                guard byte == separator.asciiValue else { return nil }
            } else {
                guard (0x30...0x39).contains(byte) else { return nil }
            }
        }
        func number(_ range: Range<Int>) -> Int64 {
            bytes[range].reduce(0) { $0 * 10 + Int64($1 - 0x30) }
        }
        let (year, month, day) = (number(0..<4), number(5..<7), number(8..<10))
        let (hour, minute, second) = (number(11..<13), number(14..<16), number(17..<19))
        guard (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day), hour <= 23,
              minute <= 59, second <= 59 else { return nil }
        var fraction: Int64 = 0
        if core > 19 {
            let digits = bytes[20..<core].prefix(3).map { Int64($0 - 0x30) }
            fraction = (digits + Array(repeating: 0, count: 3 - digits.count)).reduce(0) { $0 * 10 + $1 }
        }
        let seconds = ((hour * 60 + minute) * 60 + second) - 8 * 3600
        return daysFromCivil(year: year, month: month, day: day) * 86_400_000 + seconds * 1000 + fraction
    }

    private static func daysIn(month: Int64, year: Int64) -> Int64 {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// 外推公历日期距 1970-01-01 的天数（H. Hinnant days_from_civil，整数算法）。
    private static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let shifted = month <= 2 ? year - 1 : year
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
