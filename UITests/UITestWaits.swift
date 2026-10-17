import Foundation
import XCTest

/// UITests 的每用例总上限（FU-IOS-0712 第 2 项，F-IOS-10）：测试包的 NSPrincipalClass（project.yml 的 INFOPLIST_KEY_NSPrincipalClass），
/// 包载入时登记观察者，每个用例开始前把 `executionTimeAllowance` 设成上限（缺省 480 秒；XCTest 按整分钟向上取整）。verify.sh 的测试步带
/// `-test-timeouts-enabled YES`，超过上限的用例被判失败并结束，不再一个用例跑上千秒。环境变量 `COULI_UI_TEST_ALLOWANCE`（秒）只给变异验证
/// 用（证明卡住的用例在上限内失败）。
@objc(CouliUITestTimeouts)
final class UITestTimeouts: NSObject, XCTestObservation {
    static let allowance: TimeInterval = {
        let raw = ProcessInfo.processInfo.environment["COULI_UI_TEST_ALLOWANCE"].flatMap(TimeInterval.init)
        return raw.map { max($0, 60) } ?? 480
    }()

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        testCase.executionTimeAllowance = Self.allowance
    }
}

/// 显式条件等待（FU-IOS-0712 第 2 项）：每 0.2 秒查一次条件，`ceiling` 只用来判失败——条件永不满足时在上限内失败，不挂死、不重试。
/// 返回条件是否成立（失败时已记 XCTFail）。
@MainActor
enum UIWait {
    @discardableResult
    static func until(
        _ what: String, ceiling: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(ceiling)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("等待超时（\(Int(ceiling)) 秒）：\(what)", file: file, line: line)
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return true
    }

    /// 按 Home 进后台，并等 App 发出「进后台的同步保存已执行完」的显式信号（Debug 包的 Darwin 通知，DebugUITestSignals）再继续，
    /// 不用固定秒数（F-IOS-02）。上限只用来判失败。
    @discardableResult
    static func pressHomeAndWaitForBackgroundSave(
        _ app: XCUIApplication, ceiling: TimeInterval = 60, file: StaticString = #filePath, line: UInt = #line
    ) -> Bool {
        let signal = DarwinSignal(UITestSignalNames.backgroundSaved)
        let before = signal.count
        XCUIDevice.shared.press(.home)
        return until("App 进后台的保存执行完（此刻 state=\(app.state.rawValue)）", ceiling: ceiling, file: file, line: line) {
            signal.count > before
        }
    }
}

/// 与 App 侧 DebugUITestSignals 同名的信号。
enum UITestSignalNames {
    static let backgroundSaved = "com.couli.app.debug.uitest.background-saved"
}

/// 一个 Darwin 通知的接收计数（模拟器里 App 与测试进程共用通知中心）。
final class DarwinSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var received = 0
    private let name: String

    init(_ name: String) {
        self.name = name
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DarwinSignal>.fromOpaque(observer).takeUnretainedValue().bump()
            },
            name as CFString, nil, .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString), nil
        )
    }

    var count: Int {
        lock.withLock { received }
    }

    private func bump() {
        lock.withLock { received += 1 }
    }
}
