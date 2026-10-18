import Foundation
import Router
import Update

public enum HomeSectionFilter {
    public static func keep(minAppVersionJsonOrNull: Any?, absent: Bool, platform: String, appVersion: String) -> Bool {
        if absent {
            return true
        }
        guard let versions = minAppVersionJsonOrNull as? [String: Any], let minimum = versions[platform] as? String,
              let order = UpdateGate.compareVersions(a: appVersion, b: minimum) else { return false }
        return order >= 0
    }
}

public enum RouteTargetCheck {
    static func target(_ value: Any?) -> RouteTarget? {
        guard let json = value as? [String: Any], let route = HomeValue.text(json["route"]) else { return nil }
        var params: [String: JSONValue]?
        if let value = json["params"] {
            guard let object = value as? [String: Any], let decoded = JSONValue.object(from: object) else { return nil }
            params = decoded
        }
        return RouteTarget(route: route, params: params)
    }

    public static func decode(json: [String: Any]?) -> [String: Any]? {
        guard let target = target(json) else { return nil }
        var result: [String: Any] = ["route": target.route]
        if let params = target.params {
            result["params"] = params.mapValues(\.anyValue)
        }
        return result
    }
}

public enum HomeSpm {
    public static func of(sectionId: String, slot: Int) -> String {
        "home.\(sectionId).\(slot)"
    }
}

public enum HomeAdLabel {
    public static func of(sectionLabel: Any?,
                          itemLabel: Any?) -> String? {
        (itemLabel as? String) ?? (sectionLabel as? String)
    }
}

public enum HomeLkgScope {
    public static func of(level: String, userId: String?, env: String) -> String {
        HomeRowKey.make("scope", [env, level, level == "member" ? userId ?? "" : ""])
    }
}

public enum HomeLocalData {
    public static func clearsOn(event: String, item: String) -> Bool {
        if ["consent_revoked", "env_switch"].contains(event) {
            return true
        }
        return ["logout", "account_switch", "session_invalid"].contains(event) && item == "lkg_current_scope"
    }
}

public enum NoticeFilter {
    public static func closeKey(sectionId: String, itemId: String, contentVersion: Int) -> String {
        HomeRowKey.make("notice", [sectionId, itemId, String(contentVersion)])
    }

    public static func visible(sectionId: String, itemsJson: [Any], closedKeys: [String],
                               nowMs: Int64) -> [String: Any] {
        let visible = itemsJson.compactMap(HomeJson.notice).filter { $0.visible(
            section: sectionId,
            closed: Set(closedKeys),
            now: nowMs
        ) }
        var closable: [String: Bool] = [:]
        for notice in visible {
            closable[notice.id] = notice.closable
        }
        return ["visibleItemIds": visible.map(\.id), "closable": closable, "cardHidden": visible.isEmpty,
                "nextExpiryMs": visible.compactMap(\.end).min().map { $0 as Any } ?? NSNull()]
    }
}

public enum PopupPolicy {
    // 测试交回约定的注入接口保留显式参数。
    // swiftlint:disable:next function_parameter_count
    public static func decide(popupJson: [String: Any], level: String, nowMs: Int64, shownToday: Int,
                              coldStartShown: Bool, blockers: [String], imageLoaded: Bool) -> [String: Any] {
        let popup = try? HomeJson.popup(popupJson["props"] as? [String: Any] ?? [:],
                                        source: popupJson["data_source"] as? [String: Any] ?? [:], adLabel: nil)
        let show = popup.map { level != "basic" && !coldStartShown && blockers.isEmpty && imageLoaded &&
            shownToday < $0.dailyMax && $0.inWindow(nowMs)
        } ?? false
        return ["decisionRaw": show ? "show" : "skip", "countAfter": shownToday + (show ? 1 : 0)]
    }
}

public struct ExposureTracker {
    private var stay: Int?
    private var since: Int64?
    private var fired = false
    public init(sectionId _: String, slot _: Int) {}
    public mutating func onVisible(tMs: Int64, ratio: Double, stay: Int) -> Bool {
        if self.stay != stay {
            self.stay = stay
            since = nil
            fired = false
        }
        guard ratio >= 0.5 else { since = nil
            return false
        }
        if since == nil {
            since = tMs
        }
        guard !fired, let since, tMs - since >= 500 else { return false }
        fired = true
        return true
    }
}

public struct CardErrorDedupe {
    private var sent: Set<[String]> = []
    public init() {}
    public mutating func shouldSend(pageVersion: Int, sectionId: String, reason: String) -> Bool {
        sent.insert([String(pageVersion), sectionId, reason]).inserted
    }
}

@MainActor public final class CardErrorDedupeBox {
    public static let shared = CardErrorDedupeBox()
    private var value = CardErrorDedupe()
    public init() {}
    public func shouldSend(pageVersion: Int, sectionId: String, reason: String) -> Bool {
        value.shouldSend(pageVersion: pageVersion, sectionId: sectionId, reason: reason)
    }
}
