import Foundation

/// 请求排队前登记，回包结算完才结束；取消请求也必须等任务真正返回。
/// 不包含倒计时与系统权限等长生命周期任务。
@MainActor
public final class SettlingTasks {
    private var outstanding = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func begin() {
        outstanding += 1
    }

    public func end() {
        outstanding -= 1
        guard outstanding == 0 else { return }
        let ready = waiters
        waiters = []
        for waiter in ready {
            waiter.resume()
        }
    }

    public var isIdle: Bool {
        outstanding == 0
    }

    public func whenIdle() async {
        while outstanding > 0 {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
