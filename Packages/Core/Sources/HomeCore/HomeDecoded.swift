import Foundation
import Router

// TODO(N-35): SDUI 正式 schema 尚未进契约；仅接受任务书列出的静态结构，不解释额外字段。
public struct HomePage: Sendable {
    let key: String
    public let version: Int
    let sections: [HomeSection]
    let dropped: [HomeDrop]
    let skipped: [HomeSkip]
}

struct HomeSkip: Sendable { let id: String
    let reason: String
}

struct HomeSection: Sendable {
    let id: String
    let type: String
    let source: String
    var title: String?
    var adLabel: String?
    var more: RouteTarget?
    var columns = 2
    var ratio = 0.4
    var autoplay: Int64 = 0
    var items: [HomeItem] = []
    var notices: [HomeNotice] = []
    var popup: HomePopup?
}

struct HomeItem: Sendable {
    var title: String?
    var subtitle: String?
    var image: String?
    var alt: String?
    var badge: String?
    var adLabel: String?
    var action: RouteTarget?
    var product: HomeProductUi?
}

struct HomeNotice: Sendable {
    let id: String
    let version: Int
    let text: String
    let target: RouteTarget?
    let closable: Bool
    let start: Int64
    let end: Int64?
    let adLabel: String?
    func visible(section: String, closed: Set<String>, now: Int64) -> Bool {
        start <= now && (end == nil || now < end!) && !closed.contains(NoticeFilter.closeKey(
            sectionId: section, itemId: id, contentVersion: version
        ))
    }
}

struct HomePopup: Sendable {
    let image: String
    let dailyMax: Int
    let startMinute: Int
    let endMinute: Int
    let action: RouteTarget?
    let adLabel: String?
    func inWindow(_ millis: Int64) -> Bool {
        let minute = Int(((millis / 1000 + 8 * 3600) % 86400) / 60)
        return startMinute <= minute && minute < endMinute
    }
}

enum HomeValue {
    static func integer(_ value: Any?) -> Int? {
        guard let value, let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              NSNumber(value: number.int64Value) == number,
              let result = Int(exactly: number.int64Value) else { return nil }
        return result
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    static func https(_ value: Any?) -> String? {
        guard let string = text(value), let url = URL(string: string), url.scheme == "https",
              url.host != nil else { return nil }
        return string
    }

    static func image(_ value: Any?) -> String? {
        let builtins: Set = ["platform.taobao", "platform.jd", "platform.pdd", "category.supermarket",
                             "category.fresh", "category.baby", "category.beauty", "category.household",
                             "category.electronics",
                             "guide"]
        if let string = value as? String, string.hasPrefix("builtin:"), builtins.contains(String(string.dropFirst(8))) {
            return string
        }
        return https(value)
    }

    static func millis(_ value: Any?) -> Int64? {
        guard let string = value as? String, string.hasSuffix("+08:00") else { return nil }
        return ISO8601DateFormatter().date(from: string).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    static func minute(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour),
              (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}
