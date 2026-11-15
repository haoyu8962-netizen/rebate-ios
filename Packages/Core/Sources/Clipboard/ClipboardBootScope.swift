import Darwin
import Foundation

/// 本次开机标识（D10-1753 ①）：`sysctl kern.boottime` 的开机时刻，取到秒。本进程只取一次（进程活不过一次开机，进程内不会变）；
/// 取不到或不可信（调用失败、长度不对、时刻不为正）为 nil，调用方按「取不到」降级为只放内存。
/// 只在本机比对，不上传、不进日志与埋点。系统时间被手动大幅调整时内核会改写这个时刻，结果是旧计数作废、多做一次探测，不会少识别。
public enum ClipboardBoot {
    public static let current: String? = read()

    static func read() -> String? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0, size == MemoryLayout<timeval>.size,
              time.tv_sec > 0
        else { return nil }
        return String(time.tv_sec)
    }
}

/// 只在本次开机内有效的本机记录（D10-1753 ①⑤）：iOS 的 changeCount 只在同一次开机内递增可比，跨开机留下的计数不能再拿来判断
/// 「没变化」或「App 自写」（BR-ID-16：变化计数等非内容元数据只用来减少重复尝试，不作授权依据）。
/// - 落盘：值存 `key`（格式与旧版相同），开机标识另存 `key` + `_boot`；
/// - 读取：存的开机标识与当前不同，或没有开机标识（旧版本只有 `key` 的记录），整条作废、按没有记录处理；
/// - 取不到开机标识：只放内存、不落盘（进程结束即没有）；
/// - 写入先写值、再写标识：写到一半失败只会留下「标识对不上」的记录，按作废处理，不会让旧值顶着新标识生效。
public final class ClipboardBootScopedRecord: @unchecked Sendable {
    public static let bootSuffix = "_boot"

    public let key: String
    private let store: ClipboardHashStore
    private let boot: () -> String?
    private let lock = NSLock()
    private var memory: String?

    public init(key: String, store: ClipboardHashStore, boot: @escaping () -> String? = { ClipboardBoot.current }) {
        self.key = key
        self.store = store
        self.boot = boot
    }

    public var bootKey: String {
        key + Self.bootSuffix
    }

    public func read() -> String? {
        guard let current = boot() else {
            return lock.withLock { memory }
        }
        guard store.read(bootKey) == current else { return nil }
        return store.read(key)
    }

    /// 返回是否记下（取不到开机标识时记在内存也算记下）。
    @discardableResult
    public func write(_ value: String) -> Bool {
        guard let current = boot() else {
            lock.withLock { memory = value }
            return true
        }
        do {
            try store.write(key, value)
            try store.write(bootKey, current)
            return true
        } catch {
            return false
        }
    }

    /// 删除值与开机标识（含内存里的那份）；落盘删除失败抛错。
    public func clear() throws {
        lock.withLock { memory = nil }
        try store.write(key, nil)
        try store.write(bootKey, nil)
    }
}
