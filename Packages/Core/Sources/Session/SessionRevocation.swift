import Foundation

/// 会话撤销标记（FU-IOS-0712 第 1 项；跨端教训 10、14、15、17，Android FU-AND-0715 / 鸿蒙 FU-HM-0715 同口径）。
///
/// 清会话时在**删除令牌之前**落盘一条撤销标记，冷启动读到令牌后先核对：删除失败、进程被杀后重建也不会把旧会话与旧登录世代读回来。
/// - 标记写成 `couli-rv1|<目标>|<目标字节数>|<FNV-1a 32 位十六进制>|end`。空、截断、缺结束符、长度 / 摘要不符、认不出的目标一律
///   按「任何会话都撤销」（不完整即阻断，教训 15）；
/// - 目标：`e:<登录世代>`（撤销这一次登录）、`r:<refresh_token 摘要>`（升级前没有登录世代的会话）、`*`（清除时不知道存储里是哪一份，
///   待核验：阻断任何会话）、`s:<登录世代>`（新登录保存后删不掉的旧标记改写成「除了这一次登录，其余都撤销」）。
public enum SessionRevocation {
    static let prefix = "couli-rv1|"
    static let suffix = "|end"
    public static let anySession = "*"

    /// 标记文本。
    public static func encode(_ target: String) -> String {
        let bytes = Array(target.utf8)
        return prefix + target + "|\(bytes.count)|" + fnv32(bytes) + suffix
    }

    /// 完整的标记给出目标；不完整（空、截断、摘要不符等）为 nil。
    public static func decode(_ text: String) -> String? {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix),
              text.count > prefix.count + suffix.count else { return nil }
        let body = String(text.dropFirst(prefix.count).dropLast(suffix.count))
        let parts = body.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, let length = Int(parts[1]) else { return nil }
        let bytes = Array(parts[0].utf8)
        guard bytes.count == length, fnv32(bytes) == parts[2] else { return nil }
        return parts[0]
    }

    /// 这条标记（原始字节）是否撤销目标为 `target` 的会话。不完整、不是文本、认不出的目标一律撤销。
    public static func blocks(_ data: Data, target: String) -> Bool {
        guard let text = String(data: data, encoding: .utf8), let marked = decode(text) else { return true }
        return blocks(marked: marked, target: target)
    }

    static func blocks(marked: String, target: String) -> Bool {
        if marked == anySession {
            return true
        }
        if marked.hasPrefix("e:") || marked.hasPrefix("r:") {
            return marked == target
        }
        if marked.hasPrefix("s:") {
            return target != "e:" + marked.dropFirst(2)
        }
        return true
    }

    /// 一份会话的撤销目标：有登录世代按世代，升级前的会话按 refresh_token 摘要（不落令牌原文）。
    public static func target(loginEpoch: String?, refresh: String) -> String {
        if let loginEpoch, !loginEpoch.isEmpty {
            return "e:" + loginEpoch
        }
        return "r:" + fnv32(Array(refresh.utf8))
    }

    static func fnv32(_ bytes: [UInt8]) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in bytes {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return String(format: "%08x", hash)
    }
}

/// 进程内的「撤销标记写过几次」（任何一个 `SecureSessionTokens` 实例落标记都加一）：实例缓存「已确认没有标记」时带上这个读数，
/// 读数变了就重新核对（同一进程里清理器与网络层各有一个实例，教训 17：不能把「无标记」永久缓存）。
enum SessionRevocationSignals {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var counter: UInt64 = 0

    static var value: UInt64 {
        lock.withLock { counter }
    }

    static func bump() {
        lock.withLock { counter &+= 1 }
    }
}

/// 独立撤销记录的介质（令牌所在的 Keychain 整体不可写时，标记落在这里；Android F-AND-32 / 鸿蒙 FU-HM-0715 同口径）。
/// `read` 返回正式文件与临时文件里**存在**的内容；只有明确不存在才算没有，其余 I/O 错误一律抛出（教训 17）。
public protocol SessionRevocationMedium: AnyObject, Sendable {
    func read() throws -> [Data]
    func write(_ data: Data) throws
    /// 删掉正式文件与临时文件；不存在算成功。
    func delete() throws
}

/// 文件实现：Application Support/com.couli.app/session.revoked（不备份；首次解锁后可读，与令牌的 Keychain 可访问性一致）。
/// 写入：临时文件 `session.revoked.tmp` 写入并 fsync → 改名为正式文件 → fsync 目录。读取核对正式文件与临时文件。
public final class FileSessionRevocationMarks: SessionRevocationMedium, @unchecked Sendable {
    public static let fileName = "session.revoked"
    public let url: URL
    public var temporaryURL: URL {
        url.appendingPathExtension("tmp")
    }

    public init(url: URL) {
        self.url = url
    }

    /// 生产位置。
    public static func standard() -> FileSessionRevocationMarks {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return FileSessionRevocationMarks(
            url: base.appendingPathComponent("com.couli.app", isDirectory: true).appendingPathComponent(fileName)
        )
    }

    public func read() throws -> [Data] {
        try [url, temporaryURL].compactMap(Self.readIfPresent)
    }

    /// 只有 ENOENT 算不存在（父目录不存在同为 ENOENT）；ENOTDIR、EACCES、EISDIR、EIO 等一律抛出。
    static func readIfPresent(_ file: URL) throws -> Data? {
        let descriptor = open(file.path, O_RDONLY)
        if descriptor < 0 {
            let code = errno
            if code == ENOENT {
                return nil
            }
            throw SessionRevocationIOError(operation: "open", code: code)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw SessionRevocationIOError(operation: "fstat", code: errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG
        else { throw SessionRevocationIOError(operation: "type", code: EISDIR) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, 4096) }
            if count < 0 {
                throw SessionRevocationIOError(operation: "read", code: errno)
            }
            if count == 0 {
                break
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    public func write(_ data: Data) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = temporaryURL
        let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { throw SessionRevocationIOError(operation: "open-temp", code: errno) }
        var failed: Int32?
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 {
                    failed = errno
                    return
                }
                offset += written
            }
        }
        if failed == nil, fsync(descriptor) != 0 {
            failed = errno
        }
        close(descriptor)
        if let failed {
            throw SessionRevocationIOError(operation: "write-temp", code: failed)
        }
        guard rename(temp.path, url.path) == 0 else { throw SessionRevocationIOError(operation: "rename", code: errno) }
        let dir = open(directory.path, O_RDONLY)
        if dir >= 0 {
            _ = fsync(dir)
            close(dir)
        }
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    public func delete() throws {
        for file in [url, temporaryURL] where unlink(file.path) != 0 {
            let code = errno
            if code != ENOENT {
                throw SessionRevocationIOError(operation: "unlink", code: code)
            }
        }
    }
}

public struct SessionRevocationIOError: Error, Equatable, Sendable {
    public let operation: String
    public let code: Int32
}

/// 内存实现（单测）：可分别让读 / 写 / 删失败；`events` 记下写入与删除的先后（核对「标记先于令牌删除落盘」）。
public final class MemorySessionRevocationMarks: SessionRevocationMedium, @unchecked Sendable {
    private let lock = NSLock()
    private var formal: Data?
    private var temp: Data?
    private var readFailure = false
    private var writeFailure = false
    private var deleteFailure = false
    private var log: [String] = []

    public init() {}

    public var failReads: Bool {
        get { lock.withLock { readFailure } }
        set { lock.withLock { readFailure = newValue } }
    }

    public var failWrites: Bool {
        get { lock.withLock { writeFailure } }
        set { lock.withLock { writeFailure = newValue } }
    }

    public var failDeletes: Bool {
        get { lock.withLock { deleteFailure } }
        set { lock.withLock { deleteFailure = newValue } }
    }

    /// 直接放内容（模拟截断、空文件、旧标记、只剩临时文件）。
    public func put(formal: Data?, temp: Data? = nil) {
        lock.withLock {
            self.formal = formal
            self.temp = temp
        }
    }

    public var stored: (formal: Data?, temp: Data?) {
        lock.withLock { (formal, temp) }
    }

    public var events: [String] {
        lock.withLock { log }
    }

    public func read() throws -> [Data] {
        try lock.withLock {
            guard !readFailure else { throw SessionRevocationIOError(operation: "read", code: EIO) }
            return [formal, temp].compactMap(\.self)
        }
    }

    public func write(_ data: Data) throws {
        try lock.withLock {
            guard !writeFailure else { throw SessionRevocationIOError(operation: "write", code: EIO) }
            formal = data
            temp = nil
            log.append("file.write")
        }
    }

    public func delete() throws {
        try lock.withLock {
            guard !deleteFailure else { throw SessionRevocationIOError(operation: "delete", code: EIO) }
            formal = nil
            temp = nil
            log.append("file.delete")
        }
    }
}
