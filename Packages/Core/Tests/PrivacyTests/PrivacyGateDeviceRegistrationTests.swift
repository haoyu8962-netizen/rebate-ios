import Foundation
import XCTest
@testable import Privacy

/// APP-03b：PrivacyGate.onConsented 的设备注册步骤是异步的（DeviceRegistry），失败沿用闸门已有的 1s、2s、4s…退避。
final class PrivacyGateDeviceRegistrationTests: XCTestCase {
    private final class Scheduler: RetryScheduler {
        var jobs: [(Int64, () -> Void)] = []

        func schedule(delayMillis: Int64, action: @escaping () -> Void) {
            jobs.append((delayMillis, action))
        }

        func runNext() {
            guard !jobs.isEmpty else {
                return
            }
            jobs.removeFirst().1()
        }
    }

    private func consentedGate() -> (PrivacyGate, Scheduler) {
        let store = MemoryPrivacyStore()
        store.decisionRaw = "consented"
        store.consentedVersion = "1"
        let gate = PrivacyGate(store: store, clock: { 0 }, bundledPolicyVersion: "1")
        let scheduler = Scheduler()
        gate.retryScheduler = scheduler
        gate.withdrawalCleanup = { store.clearWithdrawalPending() }
        return (gate, scheduler)
    }

    func testAsyncDeviceStepRetriesWithBackoffUntilSuccessFirstInOrder() {
        let (gate, scheduler) = consentedGate()
        var order: [String] = []
        var completions: [(Bool) -> Void] = []
        gate.registerDeviceRegistration { done in
            order.append("device")
            completions.append(done)
        }
        gate.registerInitStep(name: PrivacyInitStep.push) { order.append("push") }

        gate.onConsented(now: 0)
        XCTAssertEqual(order, ["device", "push"], "设备注册是第一步，异步进行中不阻塞其余步骤")

        completions.removeFirst()(false)
        XCTAssertEqual(scheduler.jobs.map(\.0), [1000])
        scheduler.runNext()
        completions.removeFirst()(false)
        XCTAssertEqual(scheduler.jobs.map(\.0), [2000])
        scheduler.runNext()
        completions.removeFirst()(true)
        XCTAssertTrue(scheduler.jobs.isEmpty, "成功即停")
        XCTAssertEqual(order.filter { $0 == "device" }.count, 3)
    }

    func testWithdrawalDropsLateFailureAndRestartBeginsNewChain() {
        let (gate, scheduler) = consentedGate()
        var completions: [(Bool) -> Void] = []
        gate.registerDeviceRegistration { completions.append($0) }
        gate.onConsented(now: 0)

        gate.withdraw(now: 1)
        completions.removeFirst()(false)
        XCTAssertTrue(scheduler.jobs.isEmpty, "撤回后旧周期的失败不再排重试")
        gate.restartDeviceRegistration()
        XCTAssertTrue(completions.isEmpty, "基本模式下不重新注册")
    }

    func testRestartAfterEnvironmentSwitchCancelsOldBackoffChain() {
        let (gate, scheduler) = consentedGate()
        var completions: [(Bool) -> Void] = []
        gate.registerDeviceRegistration { completions.append($0) }
        gate.onConsented(now: 0)
        completions.removeFirst()(false)
        XCTAssertEqual(scheduler.jobs.count, 1)

        gate.restartDeviceRegistration()
        XCTAssertEqual(completions.count, 1, "立即从第 1 次重新开始")
        scheduler.runNext()
        XCTAssertEqual(completions.count, 1, "旧退避链作废")
        completions.removeFirst()(false)
        XCTAssertEqual(scheduler.jobs.map(\.0), [1000])
    }
}
