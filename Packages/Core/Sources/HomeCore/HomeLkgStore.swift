import ClientCore
import CryptoKit
import Foundation

public struct HomeWriteTicket: Sendable {
    let store: UUID
    let serial: UInt64
}

/// 主执行器是写入和清理共用的串行区；票据在请求发起前取得，清理界限与接受顺序分别校验。
@MainActor public final class HomeLkgStore {
    public static let directoryName = "home-lkg"
    private let root: URL
    public let pendingFlagURL: URL
    private let id = UUID()
    private var serial: UInt64 = 0
    private var clearBoundary: UInt64 = 0
    private var scopeBoundaries: [HomeScopeKey: UInt64] = [:]
    private var accepted: [HomeScopeKey: UInt64] = [:]
    private var pending = false
    private let manager = FileManager.default
    public init(root: URL) {
        self.root = root
        pendingFlagURL = root.deletingLastPathComponent().appendingPathComponent("home-lkg.pending")
    }

    public var isPendingClear: Bool {
        pending || manager.fileExists(atPath: pendingFlagURL.path)
    }

    public func ticket() -> HomeWriteTicket {
        serial += 1
        return HomeWriteTicket(store: id, serial: serial)
    }

    private func url(_ key: HomeScopeKey) -> URL {
        let bytes = Data(HomeRowKey.make("lkg", key.parts).utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest + ".json")
    }

    public func read(_ key: HomeScopeKey) -> Data? {
        guard completePendingClear() else { return nil }
        return try? Data(contentsOf: url(key))
    }

    @discardableResult public func write(_ key: HomeScopeKey, _ data: Data, ticket: HomeWriteTicket) -> Bool {
        guard !isPendingClear, ticket.store == id, ticket.serial > clearBoundary,
              ticket.serial > scopeBoundaries[key, default: 0],
              ticket.serial >= accepted[key, default: 0] else { return false }
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let file = url(key)
            let temporary = file.appendingPathExtension("tmp")
            try data.write(to: temporary)
            if manager.fileExists(atPath: file.path) {
                _ = try manager.replaceItemAt(file, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: file)
            }
            accepted[key] = ticket.serial
            return true
        } catch { return false }
    }

    public func clearScope(_ key: HomeScopeKey) throws {
        scopeBoundaries[key] = serial
        let file = url(key)
        for path in [file, file.appendingPathExtension("tmp")] where manager.fileExists(atPath: path.path) {
            do {
                try manager.removeItem(at: path)
            } catch {
                // 单作用域删除失败也必须隔离读写；全清标记保证重启不能复活旧账号内容。
                pending = true
                try? persistPending()
                throw error
            }
        }
    }

    public func clearAll() throws {
        clearBoundary = serial
        pending = true
        var markerError: Error?
        do { try persistPending() } catch { markerError = error }
        do {
            try eraseDirectoryContents()
            if manager.fileExists(atPath: pendingFlagURL.path) {
                try manager.removeItem(at: pendingFlagURL)
            }
            pending = false
            accepted = [:]
        } catch { throw markerError ?? error }
    }

    private func persistPending() throws {
        try manager.createDirectory(at: pendingFlagURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("pending".utf8).write(to: pendingFlagURL, options: .atomic)
    }

    private func eraseDirectoryContents() throws {
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &directory) else { return }
        guard directory.boolValue else { try manager.removeItem(at: root)
            return
        }
        // 枚举失败必须抛出，不能当作不存在。保持根目录，允许标记父目录只读时删尽内容。
        for child in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try manager.removeItem(at: child)
        }
    }

    @discardableResult public func completePendingClear() -> Bool {
        guard isPendingClear else { return true }
        do { try clearAll()
            return true
        } catch { return false }
    }
}
