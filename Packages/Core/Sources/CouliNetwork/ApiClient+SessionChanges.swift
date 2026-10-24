import Foundation

/// 会话变化的种类（F-X-25 可信容器切号的会话来源）。
public enum SessionChange: Sendable, Equatable {
    /// 登录响应的新会话已保存（换代）：观察者自己读一次身份快照判定。
    case saved
    /// 明确清除了会话（退出、注销终点、10404、刷新被拒 / 存不下新令牌）：观察者**不必也不应**再读凭据确认，按「已清除」处理
    /// （此刻凭据门可能已关、读取可能失败，「暂时读不出」与「已明确清除」分开，invariants I5）。
    case cleared
}

public extension ApiClient {
    /// 登记会话变化的观察者。观察者在**锁外**、发生变化的那个线程上同步调用（登录保存在网络任务里；`signOut()` 由调用方线程，
    /// 通常是主线程）；观察者自己决定要不要切到主线程，不得假设线程。仅令牌刷新不通知（不是身份变化）。
    /// 切换环境、撤回同意不经这里：它们的清理入口经清理器注册表直接登记（见 App 的 TrustedWebAuthCleaner）。
    func observeSessionChanges(_ observer: @escaping @Sendable (SessionChange) -> Void) {
        lock.withLock { sessionObservers.append(observer) }
    }
}

extension ApiClient {
    /// 调用方不持 `lock`：取出观察者后在锁外依次通知。
    func postSessionChange(_ change: SessionChange) {
        let observers = lock.withLock { sessionObservers }
        for observer in observers {
            observer(change)
        }
    }
}
