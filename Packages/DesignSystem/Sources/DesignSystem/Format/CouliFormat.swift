import Foundation

/// 金额与时间格式化（BR-TEXT-10、BR-TEXT-11）。纯函数，三端同名；测试向量见 specs/format-vectors.json。
public enum CouliFormat {
    // MARK: 金额（BR-TEXT-10 App 写法）

    /// 「可选负号 + ¥ + 元」，最多两位小数，去末尾 0 与多余小数点，无千分位。只用整数运算。
    public static func money(fen: Int64) -> String {
        let sign = fen < 0 ? "-" : ""
        return sign + PriceTerms.yuanSign + yuanDigits(fen.magnitude)
    }

    /// 流水写法：正数加「+」，负数「-」，零按 `money`。
    public static func moneySigned(fen: Int64) -> String {
        fen > 0 ? "+" + money(fen: fen) : money(fen: fen)
    }

    /// 返利区间：min < max「¥a–¥b」；min = max > 0 单值；min = max = 0 返回 nil（「暂无返利」由 RebateTagModel 给）。
    /// 规则空白按 rule-gaps.md「编排者统一裁定」：min > max 不排序、任一端为负、上限为 0 都按异常返回 nil
    /// （不展示可能误导的金额；RebateTagModel 对应显示「暂无返利」）。
    public static func rebateRange(minFen: Int64, maxFen: Int64) -> String? {
        guard let (low, high) = normalizedRange(minFen, maxFen) else {
            return nil
        }
        if low == high {
            return money(fen: low)
        }
        return money(fen: low) + PriceTerms.rangeDash + money(fen: high)
    }

    /// 金额的读屏文本：「19.9 元」「负 1.5 元」。
    public static func moneySpoken(fen: Int64) -> String {
        let sign = fen < 0 ? PriceTerms.spokenMinus + " " : ""
        return sign + yuanDigits(fen.magnitude) + " " + PriceTerms.spokenYuan
    }

    /// 区间的读屏文本：「1.23 元到 2.34 元」；单值同 `moneySpoken`；不显示时 nil。
    public static func rebateRangeSpoken(minFen: Int64, maxFen: Int64) -> String? {
        guard let (low, high) = normalizedRange(minFen, maxFen) else {
            return nil
        }
        if low == high {
            return moneySpoken(fen: low)
        }
        return moneySpoken(fen: low) + PriceTerms.spokenRangeTo + " " + moneySpoken(fen: high)
    }

    /// 校验原始端点顺序（不排序）：min ≤ max、min ≥ 0、max > 0 才有效，否则 nil（异常数据）。
    static func normalizedRange(_ minFen: Int64, _ maxFen: Int64) -> (Int64, Int64)? {
        guard minFen >= 0, maxFen > 0, minFen <= maxFen else {
            return nil
        }
        return (minFen, maxFen)
    }

    /// yuan = abs div 100，cent = abs mod 100；cent = 0 → yuan；cent mod 10 = 0 → yuan.c；否则 yuan.cc。
    static func yuanDigits(_ magnitude: UInt64) -> String {
        let yuan = magnitude / 100
        let cent = magnitude % 100
        if cent == 0 {
            return String(yuan)
        }
        if cent % 10 == 0 {
            return "\(yuan).\(cent / 10)"
        }
        return cent < 10 ? "\(yuan).0\(cent)" : "\(yuan).\(cent)"
    }

    // MARK: 时间（BR-TEXT-11，固定 Asia/Shanghai，不随设备时区）

    /// 列表里的过去时间：今天 HH:mm / 昨天 HH:mm / MM-DD（同年）/ YYYY-MM-DD。
    /// 「今天」「昨天」按上海日历日期判断，不按距现在 24 小时。
    /// 规则空白：传入未来时间未定义，保守按同一套日期比较处理（同日仍显示「今天」）。
    public static func timeListPast(epochMillis: Int64, nowEpochMillis: Int64) -> String {
        let time = fields(epochMillis)
        let now = fields(nowEpochMillis)
        let hm = "\(pad2(time.hour)):\(pad2(time.minute))"
        if time.dayNumber == now.dayNumber {
            return PriceTerms.today + " " + hm
        }
        if time.dayNumber == now.dayNumber - 1 {
            return PriceTerms.yesterday + " " + hm
        }
        if time.year == now.year {
            return "\(pad2(time.month))-\(pad2(time.day))"
        }
        return "\(time.year)-\(pad2(time.month))-\(pad2(time.day))"
    }

    /// 列表里的未来时间：MM-DD HH:mm（同年）/ YYYY-MM-DD HH:mm；不用「明天」等相对词。
    public static func timeListFuture(epochMillis: Int64, nowEpochMillis: Int64) -> String {
        let time = fields(epochMillis)
        let now = fields(nowEpochMillis)
        let hm = "\(pad2(time.hour)):\(pad2(time.minute))"
        if time.year == now.year {
            return "\(pad2(time.month))-\(pad2(time.day)) \(hm)"
        }
        return "\(time.year)-\(pad2(time.month))-\(pad2(time.day)) \(hm)"
    }

    /// 纯日期「YYYY-MM-DD」：与上海今天同年显示 MM-DD，否则 YYYY-MM-DD；不用相对词。
    /// 规则空白：非法日期未定义，保守原样返回输入（不猜测）。
    public static func dateOnly(isoDate: String, nowEpochMillis: Int64) -> String {
        guard let date = parseISODate(isoDate) else {
            return isoDate
        }
        if date.year == fields(nowEpochMillis).year {
            return "\(pad2(date.month))-\(pad2(date.day))"
        }
        return isoDate
    }

    /// 时间线写法「YYYY-MM-DD HH:mm」。
    public static func timeMinute(epochMillis: Int64) -> String {
        let time = fields(epochMillis)
        return "\(time.year)-\(pad2(time.month))-\(pad2(time.day)) \(pad2(time.hour)):\(pad2(time.minute))"
    }

    struct Fields: Equatable {
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        /// 上海日历日期的连续编号（用于「昨天」判断，跨月跨年都成立）。
        let dayNumber: Int
    }

    /// 只用显式时区与公历，不读设备时区与语言。
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar
    }()

    static func fields(_ epochMillis: Int64) -> Fields {
        // 向下取整到秒：分钟只截断，不进位。
        let seconds = epochMillis >= 0 ? epochMillis / 1000 : -((-epochMillis + 999) / 1000)
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return Fields(
            year: year,
            month: month,
            day: day,
            hour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            dayNumber: civilDayNumber(year: year, month: month, day: day)
        )
    }

    /// 公历日期 → 自 1970-01-01 起的天数（Howard Hinnant days_from_civil，整数运算）。
    static func civilDayNumber(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yoe = shiftedYear - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    struct CivilDate: Equatable {
        let year: Int
        let month: Int
        let day: Int
    }

    static func parseISODate(_ text: String) -> CivilDate? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month)
        else {
            return nil
        }
        return CivilDate(year: year, month: month, day: day)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    private static func pad2(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }
}
