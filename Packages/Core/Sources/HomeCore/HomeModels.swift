import CouliNetwork
import Foundation
import Router

public enum HomeLevel: String, Sendable { case member, guest, basic }
public struct HomeScopeKey: Hashable, Sendable {
    let parts: [String]
}

public struct HomeIdentity: Equatable, Sendable {
    public let env: String
    public let level: HomeLevel
    public let userId: String?
    public let loginEpoch: String?
    public let known: Bool
    public let request: RequestOwnership?
    public init(env: String, level: HomeLevel, userId: String?, loginEpoch: String?, known: Bool = true,
                request: RequestOwnership? = nil) {
        self.env = env
        self.level = level
        self.userId = userId
        self.loginEpoch = loginEpoch
        self.known = known
        self.request = request
    }

    public var lkgScope: HomeScopeKey? {
        guard known else { return nil }
        if level == .member {
            guard let userId, !userId.isEmpty, let loginEpoch, !loginEpoch.isEmpty else { return nil }
            return HomeScopeKey(parts: [env, level.rawValue, userId, loginEpoch])
        }
        return HomeScopeKey(parts: [env, level.rawValue])
    }
}

public struct RouteTarget: Equatable, Sendable {
    public let route: String
    public let params: [String: JSONValue]?
    public init(route: String, params: [String: JSONValue]? = nil) {
        self.route = route
        self.params = params
    }
}

public enum HomeSource: String, Sendable { case network, lkg, bundled = "default" }
public struct HomeVersionInfo: Sendable { public let version: Int
    public let source: HomeSource
}

public struct HomeRenderTicket: Hashable, Sendable { let controller: UUID
    let generation: Int
}

public struct HomeImageTicket: Hashable, Sendable {
    public let render: HomeRenderTicket
    public let sectionId: String
    public let slot: Int
}

public struct HomeTap: Equatable, Sendable {
    public let render: HomeRenderTicket
    public let sectionId: String
    public let slot: Int
    public let target: RouteTarget
    public var spm: String {
        HomeSpm.of(sectionId: sectionId, slot: slot)
    }
}

public struct HomeNoticeClose: Sendable {
    public let render: HomeRenderTicket
    public let sectionId: String
    public let itemId: String
    public let contentVersion: Int
    let persistence: Bool
    let write: HomeWriteTicket
}

public struct HomeFeedTicket: Equatable, Sendable {
    public let render: HomeRenderTicket
    public let sectionId: String
    let cursor: String?
}

public struct HomePopupTicket: Hashable, Sendable { public let render: HomeRenderTicket
    let instance: UUID
}

public struct HomeFailureUi: Equatable, Sendable {
    public let code: Int?
    public let traceId: String?
    public let message: String
    public var retryEnabled: Bool
    public init(code: Int?, traceId: String?, message: String, retryEnabled: Bool) {
        self.code = code
        self.traceId = traceId
        self.message = message
        self.retryEnabled = retryEnabled
    }
}

public struct HomeToast: Sendable { public let id = UUID()
    public let message: String
}

public struct HomeDrop: Sendable {
    public let id: String
    public let type: String
    public let version: Int?
    public let reason: String
}

public struct HomeProductUi: Sendable {
    public let productKey: String
    public let fields: [String: JSONValue]
}

public struct HomeItemUi: Identifiable, Sendable {
    public let id: String
    public var title: String?
    public var subtitle: String?
    public var image: String?
    public var spokenName: String
    public var adLabel: String?
    public var badge: String?
    public var tap: HomeTap?
    public var close: HomeNoticeClose?
    public var product: HomeProductUi?
    public var imageTicket: HomeImageTicket?
    public var imageFailed = false
}

public struct HomeFeedUi: Sendable {
    public var ticket: HomeFeedTicket
    public var loading = false
    public var failure: HomeFailureUi?
    public var exhausted = false
}

public struct HomeSectionUi: Identifiable, Sendable {
    public let id: String
    public let type: String
    public var key: String {
        HomeRowKey.make("section", [id])
    }

    public var title: String?
    public var items: [HomeItemUi] = []
    public var more: HomeTap?
    public var feed: HomeFeedUi?
    public var autoplay = false
    public var columns = 2
    public var heightRatio = 0.4
    public var autoplayMillis: Int64 = 0
}

public struct HomePopupUi: Identifiable, Sendable {
    public var id: HomePopupTicket {
        ticket
    }

    public let ticket: HomePopupTicket
    public let sectionId: String
    public let image: String
    public let clickable: Bool
    public let adLabel: String?
}

public enum HomeRowKey {
    public static func make(_ kind: String, _ parts: [String]) -> String {
        ([kind] + parts).map { "\($0.utf8.count):\($0)" }.joined()
    }
}

public struct HomeUiState: Sendable {
    public var render: HomeRenderTicket
    public var source: HomeSource?
    public var pageVersion: Int?
    public var sections: [HomeSectionUi] = []
    public var loadFailed: HomeFailureUi?
    public var popup: HomePopupUi?
    public var toast: HomeToast?
    public var refreshing = false
    public var refreshDisabled = false
    public var dropped: [HomeDrop] = []
    public var sectionErrors: [String: HomeFailureUi] = [:]
    public var rowKeys: [String] {
        sections.flatMap { section -> [String] in
            guard section.type == "feed_infinite" else { return [section.key] }
            var keys = section.items.map { HomeRowKey.make("product", [section.id, $0.id]) }
            if section.feed != nil {
                keys.append(HomeRowKey.make("feed_status", [section.id]))
            }
            return keys
        } + [HomeRowKey.make("footer", [])]
    }
}
