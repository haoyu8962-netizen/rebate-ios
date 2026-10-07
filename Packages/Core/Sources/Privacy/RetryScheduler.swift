import Foundation

/// 设备注册退避重试的调度器（可注入，单测用假调度器推进虚拟时间）。
public protocol RetryScheduler {
    func schedule(delayMillis: Int64, action: @escaping () -> Void)
}

/// 生产调度器：在主队列上延时执行（PrivacyGate 只在主线程使用）。
public final class MainQueueRetryScheduler: RetryScheduler {
    public init() {}

    public func schedule(delayMillis: Int64, action: @escaping () -> Void) {
        let box = MainThreadAction(action)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMillis))) {
            box.run()
        }
    }
}

/// 只在主线程创建与执行的闭包包装（跨 asyncAfter 的 @Sendable 边界）。
private final class MainThreadAction: @unchecked Sendable {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func run() {
        action()
    }
}
