import Foundation
import ObjectiveC

/// 撤回同意标记的内容：已撤回；cleanupPending = 本地凭据清理还没完成。
public struct WithdrawalMarkerState: Codable, Equatable, Sendable {
    public var cleanupPending: Bool

    public init(cleanupPending: Bool) {
        self.cleanupPending = cleanupPending
    }
}

/// 撤回同意的持久标记（R1-02、F-ALL-05）：写入要么确认落盘、要么抛错。没有标记 = 没有撤回。
public protocol WithdrawalMarker: AnyObject {
    /// nil = 没有标记。读失败或内容解不开时按「已撤回、待清理」（保守）。
    func read() -> WithdrawalMarkerState?
    /// 写入并确认落盘；失败抛错。
    func write(_ state: WithdrawalMarkerState) throws
    /// 删除；不存在算成功。
    func remove() throws
}

/// 文件标记：原子写入（临时文件 + 改名）后对文件 fsync，再从磁盘读回核对。写在 Application Support 下，
/// 不在 UserDefaults 命名空间与 Keychain 服务里，切换环境不清（与本机隐私决定一样保留）。
public final class FileWithdrawalMarker: WithdrawalMarker, @unchecked Sendable {
    public struct MismatchError: Error {}

    /// App 的标记文件（Application Support/couli/privacy-withdrawal.json）。
    public static let standard = FileWithdrawalMarker(url: defaultURL)

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("couli", isDirectory: true)
            .appendingPathComponent("privacy-withdrawal.json", isDirectory: false)
    }

    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func read() -> WithdrawalMarkerState? {
        lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            guard let data = try? Data(contentsOf: url),
                  let state = try? JSONDecoder().decode(WithdrawalMarkerState.self, from: data)
            else {
                return WithdrawalMarkerState(cleanupPending: true)
            }
            return state
        }
    }

    public func write(_ state: WithdrawalMarkerState) throws {
        try lock.withLock {
            let data = try JSONEncoder().encode(state)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.synchronize()
            guard try Data(contentsOf: url) == data else {
                throw MismatchError()
            }
        }
    }

    public func remove() throws {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return
            }
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// 内存标记（单测，以及非 `UserDefaults.standard` 的存储实例）。failWrites / failRemoves 模拟写入、删除失败。
public final class MemoryWithdrawalMarker: WithdrawalMarker, @unchecked Sendable {
    public struct WriteFailed: Error {}

    private let lock = NSLock()
    private var state: WithdrawalMarkerState?
    private var failingWrites = false
    private var failingRemoves = false

    public init(state: WithdrawalMarkerState? = nil) {
        self.state = state
    }

    public var failWrites: Bool {
        get { lock.withLock { failingWrites } }
        set { lock.withLock { failingWrites = newValue } }
    }

    public var failRemoves: Bool {
        get { lock.withLock { failingRemoves } }
        set { lock.withLock { failingRemoves = newValue } }
    }

    public func read() -> WithdrawalMarkerState? {
        lock.withLock { state }
    }

    public func write(_ next: WithdrawalMarkerState) throws {
        try lock.withLock {
            guard !failingWrites else {
                throw WriteFailed()
            }
            state = next
        }
    }

    public func remove() throws {
        try lock.withLock {
            guard !failingRemoves else {
                throw WriteFailed()
            }
            state = nil
        }
    }
}

/// 按 UserDefaults 实例取撤回标记：`.standard` 用 App 的标记文件；其他实例用挂在该实例上的内存标记（随实例释放）。
public enum WithdrawalMarkers {
    private nonisolated(unsafe) static var associationKey: UInt8 = 0
    private static let lock = NSLock()

    public static func marker(for defaults: UserDefaults) -> any WithdrawalMarker {
        if defaults === UserDefaults.standard {
            return FileWithdrawalMarker.standard
        }
        return lock.withLock {
            if let existing = objc_getAssociatedObject(defaults, &associationKey) as? MemoryWithdrawalMarker {
                return existing
            }
            let created = MemoryWithdrawalMarker()
            objc_setAssociatedObject(defaults, &associationKey, created, .OBJC_ASSOCIATION_RETAIN)
            return created
        }
    }
}
