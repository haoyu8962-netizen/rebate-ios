import Foundation

/// 周期触发（可注入，单测用假实现推进虚拟时间）。
public protocol RepeatingTicker: AnyObject {
    func start(intervalMillis: Int64, tick: @escaping () -> Void)
    func stop()
}

/// 每 10 秒触发一次上报（03 §4.7「每 10 条或 10 秒」；每 10 条的触发在 `TrackerQueue.track` 里）。
public final class TrackerUploadTimer {
    public static let intervalMillis: Int64 = 10000

    private let queue: TrackerQueue
    private let ticker: any RepeatingTicker

    public init(queue: TrackerQueue, ticker: any RepeatingTicker) {
        self.queue = queue
        self.ticker = ticker
    }

    public func start() {
        ticker.start(intervalMillis: Self.intervalMillis) { [weak queue] in
            queue?.flush()
        }
    }

    public func stop() {
        ticker.stop()
    }
}

/// 生产实现：主线程 RunLoop 上的 Timer。
public final class MainRunLoopTicker: RepeatingTicker {
    private var timer: Timer?

    public init() {}

    public func start(intervalMillis: Int64, tick: @escaping () -> Void) {
        stop()
        let box = TickBox(tick)
        let created = Timer(timeInterval: TimeInterval(intervalMillis) / 1000, repeats: true) { _ in
            box.run()
        }
        RunLoop.main.add(created, forMode: .common)
        timer = created
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}

/// 只在主线程创建与执行的闭包包装（跨 Timer 的 @Sendable 边界）。
private final class TickBox: @unchecked Sendable {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func run() {
        action()
    }
}
