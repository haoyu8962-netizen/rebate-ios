import Foundation

/// 会话变化的种类（F-X-25 可信容器切号的会话来源）。
public enum SessionChange: Sendable, Equatable {
    /// 登录响应的新会话已保存（换代）：观察者自己读一次身份快照判定。
    case saved
    /// 明确清除了会话（退出、注销终点、10404、刷新被拒 / 存不下新令牌）：观察者**不必也不应**再读凭据确认，按「已清除」处理
    /// （此刻凭据门可能已关、读取可能失败，「暂时读不出」与「已明确清除」分开，invariants I5）。
    case cleared
}

/// 会话变化相关的锁内状态（`ApiClient.sessionChanges`，只在 `ApiClient.lock` 里读写）。
struct SessionChangeState {
    /// 会话变化的观察者（F-X-25 可信容器切号）：在锁外调用，见 `observeSessionChanges`。
    var observers: [@Sendable (SessionChange) -> Void] = []
    /// 锁内记下、出锁后由 `withSessionLock` 发出的会话变化（读会话发现条目损坏时的 `.cleared`，D10-1716 ③）。
    var pending: [SessionChange] = []
    /// 存储里的损坏会话条目已按清会话处理过（换代、通知过）且没删掉（D10-1716 ②）：之后读到同一损坏条目不再换代、不再通知。
    /// 删除成功、或成功写入会话（登录保存、刷新保存）时清掉。
    var corruptEntryHandled = false
}

public extension ApiClient {
    /// 登记会话变化的观察者。观察者在**锁外**、发生变化的那个线程上同步调用（登录保存在网络任务里；`signOut()` 由调用方线程，
    /// 通常是主线程）；观察者自己决定要不要切到主线程，不得假设线程。仅令牌刷新不通知（不是身份变化）。
    /// 读会话时第一次发现存储里的会话条目损坏，也按 `.cleared` 通知一次（D10-1716，出锁后发）；
    /// 清会话删不掉而隔离中的除外（清会话本身已通知）。
    /// 切换环境、撤回同意不经这里：它们的清理入口经清理器注册表直接登记（见 App 的 TrustedWebAuthCleaner）。
    func observeSessionChanges(_ observer: @escaping @Sendable (SessionChange) -> Void) {
        lock.withLock { sessionChanges.observers.append(observer) }
    }
}

extension ApiClient {
    /// 调用方不持 `lock`：取出观察者后在锁外依次通知。
    func postSessionChange(_ change: SessionChange) {
        let observers = lock.withLock { sessionChanges.observers }
        for observer in observers {
            observer(change)
        }
    }

    /// 调用方不持 `lock`：取 `lock` 执行 `body`，出锁后发出 `body` 里记下的待发会话变化（`sessionChanges.pending`，D10-1716 ③）。
    /// 每一处在锁里调用 `readSessionLocked()` 的地方都经它取锁（读会话可能发现损坏条目而记下 `.cleared`），通知不在持锁时同步回调。
    func withSessionLock<R>(_ body: () throws -> R) rethrows -> R {
        defer { postPendingSessionChanges() }
        return try lock.withLock(body)
    }

    /// 调用方不持 `lock`：取出待发的会话变化，在锁外依次通知。
    func postPendingSessionChanges() {
        let pending: [SessionChange] = lock.withLock {
            defer { sessionChanges.pending = [] }
            return sessionChanges.pending
        }
        for change in pending {
            postSessionChange(change)
        }
    }
}
