@testable import BridgeHost
import Foundation
import XCTest

/// 契约里方法的 timeout_ms。
@MainActor
func contractTimeout(_ method: String) -> UInt64 {
    UInt64(BridgeContract.shared.methods[method]?.timeoutMs ?? -1)
}

/// 显式条件等待（FU-IOS-0712 第 2 项）：每 10 毫秒查一次，30 秒上限只用来判失败（条件永不满足时在上限内失败，不挂死）。
@MainActor
func waitFor(
    _ what: String, ceiling: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(ceiling)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("等待超时（\(Int(ceiling)) 秒）：\(what)", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// 可控的截止计时器（F-IOS-10）：记下每次登记的时长，`fireAll` 之后才到期；被取消（调用先结算）时立即返回。
@MainActor
final class ManualDeadlines {
    private(set) var armed: [UInt64] = []
    private var fired = false

    var timer: @MainActor (UInt64) async -> Void {
        { [self] millis in
            armed.append(millis)
            while !fired, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }

    func fireAll() {
        fired = true
    }
}

@MainActor
final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
