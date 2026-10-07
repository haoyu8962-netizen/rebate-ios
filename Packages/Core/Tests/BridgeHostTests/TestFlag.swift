import Foundation

/// 跨线程置位的标志（取消回调可能在任意线程）。
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var value: Bool {
        lock.withLock { raised }
    }

    func set() {
        lock.withLock { raised = true }
    }
}
