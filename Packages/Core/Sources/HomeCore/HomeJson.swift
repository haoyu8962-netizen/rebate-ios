import Foundation
import Router

public enum HomeBundled {
    public static func data() -> Data? {
        Bundle.module.url(forResource: "default_home", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
    }
}

public enum HomeJson {
    private static let types: Set<String> = ["banner", "icon_grid", "product_scroll", "product_grid",
                                             "activity_entry", "notice_bar", "feed_infinite", "popup"]
    public static func parse(_ data: Data, platform: String, appVersion: String) -> HomePage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return page(json, platform: platform, appVersion: appVersion)
    }

    public static func decode(pageJson: [String: Any], platform: String, appVersion: String) -> [String: Any] {
        guard let page = page(pageJson, platform: platform, appVersion: appVersion) else {
            return ["pageValid": false, "kept": [], "dropped": [], "skipped": [], "popupId": NSNull()]
        }
        return ["pageValid": true, "kept": page.sections.map {
            ["id": $0.id, "type": $0.type,
             "itemCount": $0.type == "notice_bar" ? $0.notices.count : $0.items.count] as [String: Any]
        }, "dropped": page.dropped.map {
            ["id": $0.id, "type": $0.type, "version": $0.version.map { $0 as Any } ?? NSNull(), "reasonRaw": $0.reason]
        }, "skipped": page.skipped.map { ["id": $0.id, "reasonRaw": $0.reason] },
        "popupId": page.sections.first { $0.type == "popup" }?.id as Any? ?? NSNull()]
    }

    static func page(_ json: [String: Any], platform: String, appVersion: String) -> HomePage? {
        guard let pageKey = HomeValue.text(json["page_key"]), let version = HomeValue.integer(json["version"]),
              version > 0,
              let raw = json["sections"] as? [Any] else { return nil }
        var sections: [HomeSection] = []
        var dropped: [HomeDrop] = []
        var skipped: [HomeSkip] = []
        var ids = Set<String>()
        var hasPopup = false
        for value in raw {
            let object = value as? [String: Any] ?? [:]
            let id = object["id"] as? String ?? ""
            let type = object["type"] as? String ?? ""
            let cardVersion = HomeValue.integer(object["version"])
            guard types.contains(type) else { skipped.append(HomeSkip(id: id, reason: "unknown_type"))
                continue
            }
            guard HomeSectionFilter.keep(
                minAppVersionJsonOrNull: object["min_app_version"],
                absent: object["min_app_version"] == nil,
                platform: platform,
                appVersion: appVersion
            ) else {
                skipped.append(HomeSkip(id: id, reason: "min_app_version"))
                continue
            }
            do {
                try validateCard(object, id: id, version: cardVersion, ids: &ids)
                let card = try section(object, id: id, type: type)
                if type == "popup" {
                    guard !hasPopup else { continue }
                    hasPopup = true
                }
                sections.append(card)
            } catch let DecodeFailure.reason(reason) {
                dropped.append(HomeDrop(id: id, type: type, version: cardVersion, reason: reason))
            } catch { dropped.append(HomeDrop(id: id, type: type, version: cardVersion, reason: "bad_type")) }
        }
        return HomePage(key: pageKey, version: version, sections: sections, dropped: dropped, skipped: skipped)
    }

    private static func validateCard(_ json: [String: Any], id: String, version: Int?,
                                     ids: inout Set<String>) throws {
        guard !id.isEmpty else { throw DecodeFailure.reason("missing_field") }
        guard ids.insert(id).inserted else { throw DecodeFailure.reason("duplicate_id") }
        guard json["version"] != nil else { throw DecodeFailure.reason("missing_version") }
        guard version == 1 else { throw DecodeFailure.reason("unsupported_version") }
    }

    enum DecodeFailure: Error { case reason(String) }
    static func section(_ json: [String: Any], id: String, type: String) throws -> HomeSection {
        guard let source = json["data_source"] as? [String: Any], let kind = source["kind"] as? String else {
            throw DecodeFailure.reason("missing_field")
        }
        let allowed: [String: Set<String>] = [
            "banner": ["static"],
            "icon_grid": ["static"],
            "activity_entry": ["static"],
            "popup": ["static"],
            "notice_bar": ["static", "api"],
            "product_scroll": ["product_pool"],
            "product_grid": ["product_pool"],
            "feed_infinite": ["union_material"],
        ]
        guard allowed[type]?.contains(kind) == true else { throw DecodeFailure.reason("bad_value") }
        guard let props = json["props"] as? [String: Any] ?? (type == "feed_infinite" ? [:] : nil) else {
            throw DecodeFailure.reason("missing_field")
        }
        var card = HomeSection(id: id, type: type, source: kind)
        card.title = props["title"] as? String
        card.adLabel = json["ad_label"] as? String
        if let more = props["more_action"] {
            guard let target = RouteTargetCheck.target(more) else { throw DecodeFailure.reason("bad_action") }
            card.more = target
        }
        try configure(&card, props: props, source: source)
        if ["banner", "icon_grid", "activity_entry"].contains(type) {
            guard let items = source["items"] as? [Any] else { throw DecodeFailure.reason("missing_field") }
            card.items = items.compactMap { item($0, type: type) }
            if type == "activity_entry", card.items.count > 3 {
                throw DecodeFailure.reason("bad_value")
            }
        }
        return card
    }

    private static func configure(_ card: inout HomeSection, props: [String: Any], source: [String: Any]) throws {
        switch card.type {
        case "banner":
            try configureBanner(&card, props: props)
        case "icon_grid", "product_grid":
            try configureColumns(&card, props: props)
        case "notice_bar":
            let mode = props["mode"] as? String ?? "static"
            guard ["static", "scroll"].contains(mode) else { throw DecodeFailure.reason("bad_value") }
            card.autoplay = mode == "scroll" ? 4000 : 0
            if card.source == "static" {
                guard let items = props["items"] as? [Any] else { throw DecodeFailure.reason("missing_field") }
                card.notices = items.compactMap(notice)
            }
        case "popup": card.popup = try popup(props, source: source, adLabel: card.adLabel)
        default: break
        }
    }

    private static func configureBanner(_ card: inout HomeSection, props: [String: Any]) throws {
        guard props["height_ratio"] != nil,
              props["autoplay_ms"] != nil else { throw DecodeFailure.reason("missing_field") }
        guard let ratio = props["height_ratio"] as? NSNumber, HomeValue.bool(ratio) == nil,
              let autoplay = HomeValue.integer(props["autoplay_ms"]) else { throw DecodeFailure.reason("bad_type") }
        guard ratio.doubleValue > 0, ratio.doubleValue.isFinite,
              autoplay >= 0 else { throw DecodeFailure.reason("bad_value") }
        card.ratio = ratio.doubleValue
        card.autoplay = Int64(autoplay)
    }

    private static func configureColumns(_ card: inout HomeSection, props: [String: Any]) throws {
        guard props["columns"] != nil else { throw DecodeFailure.reason("missing_field") }
        guard let columns = HomeValue.integer(props["columns"]) else { throw DecodeFailure.reason("bad_type") }
        guard (card.type == "icon_grid" ? [4, 5] : [2]).contains(columns)
        else { throw DecodeFailure.reason("bad_value") }
        card.columns = columns
    }

    static func item(_ raw: Any, type: String) -> HomeItem? {
        guard let json = raw as? [String: Any], let action = RouteTargetCheck.target(json["action"]) else { return nil }
        let title = HomeValue.text(json["title"])
        let image = HomeValue.image(json[type == "icon_grid" ? "icon" : "image"])
        switch type {
        case "banner": guard HomeValue.https(image) != nil else { return nil }
        case "icon_grid": guard title != nil, image != nil else { return nil }
        default: guard title != nil || image != nil else { return nil }
        }
        return HomeItem(title: title, subtitle: json["subtitle"] as? String, image: image, alt: json["alt"] as? String,
                        badge: json["badge"] as? String, adLabel: json["ad_label"] as? String, action: action)
    }

    static func notice(_ raw: Any) -> HomeNotice? {
        guard let json = raw as? [String: Any], let id = HomeValue.text(json["item_id"]),
              let version = HomeValue.integer(json["content_version"]), version > 0,
              let text = HomeValue.text(json["text"]), let closable = HomeValue.bool(json["closable"]),
              let start = HomeValue.millis(json["start_at"]) else { return nil }
        let end = HomeValue.millis(json["end_at"])
        if let rawEnd = json["end_at"], !(rawEnd is NSNull), end == nil {
            return nil
        }
        guard closable || end != nil, end.map({ $0 > start }) ?? true else { return nil }
        var target: RouteTarget?
        if let rawTarget = json["target"], !(rawTarget is NSNull) {
            guard let decoded = RouteTargetCheck.target(rawTarget) else { return nil }
            target = decoded
        }
        return HomeNotice(id: id, version: version, text: text, target: target, closable: closable, start: start,
                          end: end, adLabel: json["ad_label"] as? String)
    }

    static func popup(_ props: [String: Any], source: [String: Any], adLabel: String?) throws -> HomePopup {
        guard props["image"] != nil, props["daily_max"] != nil, props["time_window"] != nil else {
            throw DecodeFailure.reason("missing_field")
        }
        guard let max = HomeValue.integer(props["daily_max"]), let window = props["time_window"] as? [String] else {
            throw DecodeFailure.reason("bad_type")
        }
        guard let image = HomeValue.https(props["image"]), max > 0, window.count == 2,
              let start = HomeValue.minute(window[0]), let end = HomeValue.minute(window[1]), start < end else {
            throw DecodeFailure.reason("bad_value")
        }
        let first = (source["items"] as? [[String: Any]])?.first
        let action = RouteTargetCheck.target(first?["action"])
        if first?["action"] != nil, action == nil {
            throw DecodeFailure.reason("bad_action")
        }
        return HomePopup(image: image, dailyMax: max, startMinute: start, endMinute: end, action: action,
                         adLabel: HomeAdLabel.of(sectionLabel: adLabel, itemLabel: first?["ad_label"] as? String))
    }
}
