import Foundation

/// 刷新窗口上登记的一个调用方：有效性约束、等结果的 continuation、是否已结束（调用方的 Task 被取消，如桥调用到
/// 截止时间）。`ended`、`window`、`continuation` 在 `ApiClient.lock` 里读写；continuation 取出后置 nil，只结算一次。
final class RefreshCaller: @unchecked Sendable {
    let isValid: (@Sendable () -> Bool)?
    var ended = false
    var window: RefreshWindow?
    var continuation: CheckedContinuation<RefreshOutcome, Never>?
    /// 并入时窗口已作废（R4-01）：不参与该窗口的有效性判定；窗口结算后不拿它的结果，重新入队（另开窗口或复用新令牌）。
    var deferred = false
    /// 已作废窗口结算时置位：`awaitRefresh` 醒来后重新入队一次。
    var readmit = false

    init(_ isValid: (@Sendable () -> Bool)?) {
        self.isValid = isValid
    }
}

/// 刷新窗口的有效调用方（APP-04 三端共性第 41、54 条）：判定、调用方结束、最后一个有效调用方结束时取消刷新。
extension ApiClient {
    /// 窗口里是否还有有效的调用方（APP-04 三端共性第 41 条）：没有有效性约束的调用方始终算有效；已结束（Task 被取消）
    /// 的调用方与已作废的窗口不算。登记表在 `lock` 里取快照，有效性在锁外求值（桥的有效性有自己的锁）。
    ///
    /// 判定为没有有效调用方时，在同一把锁里把窗口作废（R4-01）：提交前用调用方版本复核，判空之后有新的调用方入队就
    /// 重新判断，不会把刚并入的有效调用方一起取消。作废之后并入的调用方不再参与本窗口（`deferred`），等本窗口结算后
    /// 重新入队，不会出现两个窗口同时拿旧 refresh_token 刷新。返回 false 时窗口已作废。
    func refreshHasLiveCaller(_ window: RefreshWindow) -> Bool {
        while true {
            let (version, none, callers, abandoned) = lock.withLock {
                (window.callerVersion, window.callers.isEmpty,
                 window.callers.filter { !$0.ended && !$0.deferred }, window.abandoned)
            }
            guard !abandoned else {
                return false
            }
            if none || callers.contains(where: { $0.isValid?() ?? true }) {
                return true
            }
            let committed: Bool = lock.withLock {
                guard window.abandoned || window.callerVersion == version else {
                    return false
                }
                window.abandoned = true
                return true
            }
            if committed {
                return false
            }
        }
    }

    /// 调用方的 Task 被取消：有有效性约束的调用方记为已结束，立即按 transient(call_cancelled) 结算它自己（不等窗口），
    /// 再判定窗口是否已没有有效调用方。
    func refreshCallerEnded(_ caller: RefreshCaller) {
        guard caller.isValid != nil else {
            return
        }
        let (window, continuation) = lock.withLock {
            caller.ended = true
            defer { caller.continuation = nil }
            return (caller.window, caller.continuation)
        }
        continuation?.resume(returning: .transient(LocalRejectReason.callCancelled))
        if let window {
            cancelRefreshIfAbandoned(window)
        }
    }

    /// 窗口里已没有有效调用方（最后一个有效调用方到期或失效）：作废窗口并取消它在途的刷新请求（APP-04 三端共性第 54 条）。
    /// 窗口随即以 transient(call_cancelled) 结算全部等待者，不清会话、不动令牌。其他有效调用方还在时什么都不做。
    func cancelRefreshIfAbandoned(_ window: RefreshWindow) {
        guard !refreshHasLiveCaller(window) else {
            return
        }
        lock.withLock { window.task }?.cancel()
    }
}
