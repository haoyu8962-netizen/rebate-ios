import Foundation

/// 本机 hash 记录的存储端口（只存 hash、时间与 iOS changeCount，不存原文；BR-ID-16「本机只存 hash」）。生产为 App 的文件存储，测试用内存。
/// 读失败或内容损坏按空处理（只会多出一次提示，不会多上传：手动粘贴仍要用户点击）；写必须确认落盘，失败抛错（共性第 14、23、25 条）。
public protocol ClipboardHashStore: AnyObject {
    func read(_ key: String) -> String?
    /// value 为 nil 删除。没有确认落盘就抛错。
    func write(_ key: String, _ value: String?) throws
}

/// 内存实现（测试与没有持久化时）。`failWrites` 模拟存储故障（测试用）。
public final class MemoryClipboardHashStore: ClipboardHashStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public var failWrites = false

    public init() {}

    public func read(_ key: String) -> String? {
        lock.withLock { values[key] }
    }

    public func write(_ key: String, _ value: String?) throws {
        try lock.withLock {
            if failWrites {
                throw ClipboardStoreError.writeFailed
            }
            values[key] = value
        }
    }
}

public enum ClipboardStoreError: Error, Equatable {
    case writeFailed
}

/// App 自己写入剪贴板的内容（F-CLIP-02；brief §2.3）：桥 clipboard.write、复制口令 copy_tpwd、各原生复制按钮都经同一个写入口
/// （`ClipboardWriter`），写入前先 `record`。保留最近 `capacity` 条 hash（重复写入同一内容移到最新），商品与邀请两种识别都排除。
/// iOS 另记写入后的 changeCount（brief §3：「写入后记下的 changeCount + 读到后的 hash」两道），同样保留最近 `capacity` 个。
/// 撤回同意时 `clear`。三端同名。
public struct ClipboardWriteLedger {
    public static let defaultCapacity = 10
    static let hashKey = "self_written"
    static let changeKey = "self_written_change"
    private static let separator: Character = ","

    private let capacity: Int
    private let hash: (String) -> String
    private let store: ClipboardHashStore

    public init(
        capacity: Int = defaultCapacity,
        hash: @escaping (String) -> String = ClipboardText.sha256,
        store: ClipboardHashStore = MemoryClipboardHashStore()
    ) {
        self.capacity = capacity
        self.hash = hash
        self.store = store
    }

    /// 记下一段自写内容的 hash；返回是否确认落盘（没落盘时调用方不得写系统剪贴板，共性第 23、25 条）。
    @discardableResult
    public func record(_ text: String) -> Bool {
        let value = hash(text)
        let next = Array((hashes().filter { $0 != value } + [value]).suffix(capacity))
        return (try? store.write(Self.hashKey, next.joined(separator: String(Self.separator)))) != nil
    }

    public func contains(_ text: String) -> Bool {
        hashes().contains(hash(text))
    }

    /// 最近 capacity 条（旧的在前）。
    public func hashes() -> [String] {
        Array(list(Self.hashKey).suffix(capacity))
    }

    /// iOS：自写之后系统剪贴板的 changeCount。
    @discardableResult
    public func recordChangeCount(_ count: Int) -> Bool {
        let value = String(count)
        let next = Array((list(Self.changeKey).filter { $0 != value } + [value]).suffix(capacity))
        return (try? store.write(Self.changeKey, next.joined(separator: String(Self.separator)))) != nil
    }

    public func containsChangeCount(_ count: Int) -> Bool {
        list(Self.changeKey).contains(String(count))
    }

    /// 撤回同意：删除自写记录（失败抛错，清理器据此保留待清理标记）。
    public func clear() throws {
        try store.write(Self.hashKey, nil)
        try store.write(Self.changeKey, nil)
    }

    private func list(_ key: String) -> [String] {
        (store.read(key) ?? "").split(separator: Self.separator).map(String.init).filter { !$0.isEmpty }
    }
}

/// 出过提示条的内容（G08）：出了提示条就记录（点了或关了都算），同一 hash 严格小于 24 小时不再提示。只存 hash 与时间；时钟可注入。
/// 只按 24 小时到期清理，不设条数上限（共性第 7 条：容量淘汰会让仍在 24 小时内的内容再次提示）。撤回同意时 `clear`。三端同名。
public final class PromptHistory {
    static let key = "prompted"
    private let clock: () -> Int64
    private let store: ClipboardHashStore

    public init(clock: @escaping () -> Int64, store: ClipboardHashStore = MemoryClipboardHashStore()) {
        self.clock = clock
        self.store = store
    }

    @discardableResult
    public func record(_ hash: String) -> Bool {
        let now = clock()
        let kept = stamps().filter { $0.hash != hash && ClipboardClassifier.withinWindow(now - $0.atMs) }
        let next = kept + [ClipboardPromptStamp(hash: hash, atMs: now)]
        return (try? store.write(Self.key, next.map { "\($0.hash)@\($0.atMs)" }.joined(separator: ","))) != nil
    }

    public func stamps() -> [ClipboardPromptStamp] {
        (store.read(Self.key) ?? "").split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: "@", maxSplits: 1)
            guard parts.count == 2, !parts[0].isEmpty, let at = Int64(parts[1]) else { return nil }
            return ClipboardPromptStamp(hash: String(parts[0]), atMs: at)
        }
    }

    public func clear() throws {
        try store.write(Self.key, nil)
    }
}

/// 系统剪贴板端口（App 给 UIPasteboard 实现；测试用假实现计数）。只暴露 changeCount、模式探测与写入：自动识别不读正文（brief §3 iOS），
/// 正文只经用户点击的系统粘贴控件交给 App（UIPasteControl）。
@MainActor
public protocol SystemClipboard: AnyObject {
    var changeCount: Int { get }
    /// detectPatterns（probableWebURL、links）：命中返回 true；不得调 detectValues 或读 `.string`。
    func detectLink(_ completion: @escaping @MainActor (Bool) -> Void)
    func write(_ text: String)
}

/// App 写剪贴板的唯一入口（桥 clipboard.write、复制口令 copy_tpwd、各原生复制按钮）：写入前先确认自写 hash 已落盘，失败不写并返回 false
/// （共性第 23、25 条）；写入后记下 changeCount（iOS 第一道排除）。
@MainActor
public final class ClipboardWriter {
    private let system: SystemClipboard
    private let ledger: ClipboardWriteLedger

    public init(system: SystemClipboard, ledger: ClipboardWriteLedger) {
        self.system = system
        self.ledger = ledger
    }

    @discardableResult
    public func write(_ text: String) -> Bool {
        guard ledger.record(text) else { return false }
        system.write(text)
        ledger.recordChangeCount(system.changeCount)
        return true
    }
}
