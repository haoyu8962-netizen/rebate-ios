import Foundation

/// 一次桥调用的有效性（APP-04 三端共性第 22 条）：调用结算、页面换文档或关闭、撤回同意、切换环境时置为无效。
/// 桥经 ApiClient 发出的每个请求都带上它，ApiClient 在等待结束、重试、真正发出之前都要查它（可能在任意线程查，加锁）。
public final class BridgeCallValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    public init() {}

    public var isValid: Bool {
        lock.withLock { valid }
    }

    /// 置为无效（不可恢复）。
    public func revoke() {
        lock.withLock { valid = false }
    }
}
