import ClientCore
import Foundation

@MainActor public final class HomePrefsStore {
    private let defaults: UserDefaults
    private let id = UUID()
    private var serial: UInt64 = 0
    private var boundary: UInt64 = 0
    private let closedPrefix = "home.closed."
    private let shownPrefix = "home.shown."
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func ticket() -> HomeWriteTicket {
        serial += 1
        return HomeWriteTicket(store: id, serial: serial)
    }

    private func valid(_ ticket: HomeWriteTicket) -> Bool {
        ticket.store == id && ticket.serial > boundary
    }

    public func closedKeys() -> Set<String> {
        Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(closedPrefix) }
            .map { String($0.dropFirst(closedPrefix.count)) })
    }

    @discardableResult public func recordClosed(_ key: String, ticket: HomeWriteTicket, at: Int64) -> Bool {
        guard valid(ticket) else { return false }
        defaults.set(at, forKey: closedPrefix + key)
        return defaults.synchronize()
    }

    private func countKey(_ section: String, _ millis: Int64) -> String {
        shownPrefix + HomeRowKey.make("day", [section, String((millis / 1000 + 8 * 3600) / 86400)])
    }

    public func shownToday(sectionId: String,
                           nowMs: Int64) -> Int {
        defaults.integer(forKey: countKey(sectionId, nowMs))
    }

    @discardableResult public func recordShown(sectionId: String, nowMs: Int64, ticket: HomeWriteTicket) -> Bool {
        guard valid(ticket) else { return false }
        let key = countKey(sectionId, nowMs)
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
        return defaults.synchronize()
    }

    public func clearAll() throws {
        boundary = serial
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(closedPrefix) || key.hasPrefix(shownPrefix) {
            defaults.removeObject(forKey: key)
        }
        guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
    }
}

@MainActor public struct HomeStorage {
    public static let shared = HomeStorage(
        lkg: HomeLkgStore(root: ClientFile(name: HomeLkgStore.directoryName).url),
        prefs: HomePrefsStore(defaults: UserDefaults(suiteName: "couli_home_prefs") ?? .standard)
    )
    public let lkg: HomeLkgStore
    public let prefs: HomePrefsStore
    public init(lkg: HomeLkgStore, prefs: HomePrefsStore) {
        self.lkg = lkg
        self.prefs = prefs
    }
}
