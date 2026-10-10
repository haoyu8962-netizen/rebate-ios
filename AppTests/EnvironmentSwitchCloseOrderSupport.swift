import ClientCore
import Config
import CouliNetwork
import Foundation
import Session

// FU-IOS-0711 测试替身（EnvironmentSwitchCloseOrderTests 用）。

/// 读取保留项（环境记录、隐私决定）时调一次 `onPreservedRead`（调完即清）：此刻 switching 已生效、清理器尚未运行。
final class CloseOrderProbeDefaults: UserDefaults, @unchecked Sendable {
    var onPreservedRead: (() -> Void)?
    /// 先跳过几次保留项读取（启动对账先读选择记录、生效记录，之后才是清理前保存保留项）。
    var skipPreservedReads = 0

    override func object(forKey defaultName: String) -> Any? {
        if AppNamespace.preservedOnEnvironmentSwitchKeys.contains(defaultName), let probe = onPreservedRead {
            if skipPreservedReads > 0 {
                skipPreservedReads -= 1
            } else {
                onPreservedRead = nil
                probe()
            }
        }
        return super.object(forKey: defaultName)
    }
}

/// 记读取次数的令牌存储。
final class CloseOrderCountingTokens: SessionTokens, @unchecked Sendable {
    let inner: MemorySessionTokens
    private let lock = NSLock()
    private var count = 0

    init(_ inner: MemorySessionTokens) {
        self.inner = inner
    }

    var reads: Int {
        lock.withLock { count }
    }

    func readSession() throws -> SessionSnapshot? {
        lock.withLock { count += 1 }
        return try inner.readSession()
    }

    func save(access: String, refresh: String, scope: String, account: String?) throws {
        try inner.save(access: access, refresh: refresh, scope: scope, account: account)
    }

    func clear() throws {
        try inner.clear()
    }
}

/// 一次性暂停点：`arm` 之后第一次经过时停下，等 `resume`。
final class CloseOrderPause: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let paused = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)

    func arm() {
        lock.withLock { armed = true }
    }

    /// 同步暂停（调用方不持任何锁）。
    func pass() {
        let stop: Bool = lock.withLock {
            defer { armed = false }
            return armed
        }
        if stop {
            paused.signal()
            resume.wait()
        }
    }

    func waitUntilPaused() async -> Bool {
        await Task.detached { [paused] in closeOrderWait(paused, seconds: 5) }.value
    }
}

/// 准入之后、交回凭据之前暂停的设备凭据（模拟「切换前已组好请求、尚未写出」）。准入在暂停之前判定。
struct CloseOrderPausingDevice: DeviceCredentials {
    let pause: CloseOrderPause
    var deviceId: String? = "device-fixture"
    var installSecret: String? = "test-only.install.fu0711"

    func credentials(admittedBy admit: () -> UInt64?) -> (deviceId: String, installSecret: String)? {
        let admitted = admit() != nil
        pause.pass()
        return admitted ? credentials : nil
    }
}

struct CloseOrderFixedReader: DeviceIdentifierReading {
    @MainActor
    func readIdentifier() -> String? {
        "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
    }
}

/// 可切换成败的清理器（失败回退、启动阻断用）。
final class CloseOrderSwitchableCleaner: EnvironmentSwitchCleaning {
    struct Failed: Error {}
    let cleanerName = "FU0711.switchable"
    var failuresLeft = 0

    func cleanForEnvironmentSwitch() throws {
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw Failed()
        }
    }
}

/// 保留项读取那一刻的观察。
final class CloseOrderSeen {
    var switching: [Bool] = []
    var networkBarrier: [Bool] = []
    var deviceBarrier: [Bool] = []
    var tokenPresent: [Bool] = []
    var tokenReadsDelta: [Int] = []
    var deviceReadsDelta: [Int] = []
    var sentDelta: [Int] = []
    var resumedFinished: [Bool] = []
}

/// 限时等待信号量（同步函数里调用，避免在异步上下文直接调用 noasync 的 wait）。
func closeOrderWait(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
    semaphore.wait(timeout: .now() + seconds) == .success
}

extension ApiResult {
    /// 是否成功（测试用）。
    var closeOrderSucceeded: Bool {
        if case .success = self {
            return true
        }
        return false
    }
}
