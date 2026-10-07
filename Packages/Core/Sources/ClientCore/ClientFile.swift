import Foundation

/// 本 App 的小文件（LKG 配置、埋点队列、权限节流记录）：放在 Application Support/com.couli.app/ 下，不在缓存目录——
/// 「清除缓存」只清图片与 WebView 的 HTTP 缓存，不清这些（03 §4.3）。不放任何凭据（CSB-05）。
public struct ClientFile: Sendable {
    public static let directoryName = "com.couli.app"

    public let url: URL

    /// - Parameter baseDirectory: 测试注入的目录；默认 Application Support。
    public init(name: String, baseDirectory: URL? = nil) {
        let base = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = base.appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    private init(url: URL) {
        self.url = url
    }

    /// 同目录下的另一个文件（如待清理标记）。
    public func sibling(_ name: String) -> ClientFile {
        ClientFile(url: url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false))
    }

    /// nil = 文件不存在；读不了（权限、设备锁定等）抛错。
    public func read() throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 原子写用的临时文件（同目录 `<name>.tmp`）。
    public var temporaryURL: URL {
        url.appendingPathExtension("tmp")
    }

    /// 写入：先写 `<name>.tmp` 再替换正式文件。nil = 删除正式文件与临时文件（撤回同意、切换环境的清理也走这里）；
    /// 任一个删不掉就抛错（清理器据此保留待清理状态）。不存在算成功。
    public func write(_ text: String?) throws {
        let manager = FileManager.default
        guard let text else {
            var failure: Error?
            for target in [temporaryURL, url] where manager.fileExists(atPath: target.path) {
                do {
                    try manager.removeItem(at: target)
                } catch {
                    failure = failure ?? error
                }
            }
            if let failure {
                throw failure
            }
            return
        }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: temporaryURL.path) {
            try manager.removeItem(at: temporaryURL)
        }
        try Data(text.utf8).write(to: temporaryURL)
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try manager.moveItem(at: temporaryURL, to: url)
        }
    }
}
