import Foundation

/// 回跳的进程内一次性收件箱（同安卓甲 `WebCodeInbox`；只在内存，不落盘）：入站方 `deliver`，等待方按 sha256(state)（UTF-8 字节的
/// 小写十六进制，`webCodeStateSha256`）`claim`。设想用途：onOpenURL 兜底与会话并存时的认领、孤儿交接；生产暂未接入（备用路径，暂不做，D10-3709 ④），只有接口与行为。
/// - 回跳先到、等待后到，或等待先到、回跳后到，都能交付；只交给 state 哈希相同的等待；交付一次后，同一 state 在 `slotTtlMillis`
///   内再来的回跳丢弃。
/// - 单槽：没有等待认领的回跳放进槽位，新的覆盖旧的；state 不符的等待不吞掉它（伪造的回跳也不打断真实等待）。槽位最多保留
///   `slotTtlMillis`。
/// - 等待所在的任务被取消时注销，`claim` 返回 nil；回跳一经交付就经 continuation 带回调用方（取消晚于交付时仍返回这条回跳，不会丢）。
/// 只在主线程使用。
@MainActor
public final class WebCodeInbox: WebCodeCallbackSink {
    /// 槽位与「已交付」记录的保留时长：10 分钟。
    public static let slotTtlMillis: Int64 = 10 * 60 * 1000

    private struct Slot {
        let stateSha256: String
        let callback: WebCodeCallback
        let deliveredAtMillis: Int64
    }

    private struct Waiter {
        let id: Int
        let stateSha256: String
        let continuation: CheckedContinuation<WebCodeCallback?, Never>
    }

    private let clock: () -> Int64
    private var slot: Slot?
    private var waiters: [Waiter] = []
    private var nextWaiterId = 0
    /// 已经交付过的 state 哈希 → 交付时间（同一 state 再来的回跳丢弃；超过 `slotTtlMillis` 的剪掉）。
    private var consumed: [String: Int64] = [:]

    /// clock：毫秒墙钟（测试注入）。
    public init(clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.clock = clock
    }

    /// 交付一条回跳：有 state 哈希相同的等待就交给它，否则放进槽位；同一 state 已交付过（`slotTtlMillis` 内）就丢弃。
    public func deliver(_ callback: WebCodeCallback) {
        let hash = webCodeStateSha256(callback.state)
        let now = clock()
        prune(now)
        guard consumed[hash] == nil else { return }
        if let index = waiters.firstIndex(where: { $0.stateSha256 == hash }) {
            let waiter = waiters.remove(at: index)
            consumed[hash] = now
            waiter.continuation.resume(returning: callback)
        } else {
            slot = Slot(stateSha256: hash, callback: callback, deliveredAtMillis: now)
        }
    }

    /// 按 sha256(state) 认领：槽位里已有匹配的回跳就立即取走；否则挂起，直到匹配的回跳到达。所在任务被取消 → nil（并注销等待）。
    /// 回跳一经交付就由 continuation 直接带回调用方，不存在「交到手却丢失」的窗口；取消晚于交付时仍返回这条回跳。
    public func claim(stateSha256: String) async -> WebCodeCallback? {
        let now = clock()
        prune(now)
        if let held = slot, held.stateSha256 == stateSha256 {
            slot = nil
            consumed[stateSha256] = now
            return held.callback
        }
        guard !Task.isCancelled else { return nil }
        nextWaiterId += 1
        let id = nextWaiterId
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, stateSha256: stateSha256, continuation: continuation))
            }
        } onCancel: {
            // 取消可能来自任意线程：回主线程注销（注销时这次等待仍在表里才 resume nil，只 resume 一次）
            Task { @MainActor [weak self] in
                self?.unregister(id)
            }
        }
    }

    /// 清空槽位与已交付记录（设想在退出登录、切换账号、切换环境时调用；清理链暂未接入，D10-3709 ④）。正在等的认领不受影响。
    public func clear() {
        slot = nil
        consumed.removeAll()
    }

    private func unregister(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: nil)
    }

    private func prune(_ now: Int64) {
        if let held = slot, now - held.deliveredAtMillis > Self.slotTtlMillis {
            slot = nil
        }
        consumed = consumed.filter { now - $0.value <= Self.slotTtlMillis }
    }
}
