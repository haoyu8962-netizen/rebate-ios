@testable import Couli
import CouliNetwork
import Foundation
import MeCore
import Session
import WalletCore
import XCTest

/// FU-IOS-0713 测试设施：按身份读取位置遍历两种故障形态（只在测试里用）。
/// - 「仅第 n 次」：故障窗口内第 n 次会话读取暂时失败，其余照常；
/// - 「第 n 次起持续」：故障窗口内第 n 次起的读取全部暂时失败，直到窗口结束（`disarm`）。
/// n 从 1 起遍历：某一轮窗口内实际发生的读取次数 < n，说明这个位置之后已经没有读取，覆盖完成；每一轮都核对确实命中（读取次数 ≥ n）。
/// 窗口内一次读取都没有判失败（用例的前提不成立）；上限耗尽判「覆盖未完成」。不依赖某个位置号，实现增减读取次数时自动跟随。
enum ReadFault: String, CaseIterable {
    case once = "仅第n次"
    case from = "第n次起"

    func arm(_ store: CountingSessionTokens, _ nth: Int) {
        switch self {
        case .once: store.failRead(nth: nth)
        case .from: store.failReads(fromNth: nth)
        }
    }
}

/// 一次故障窗口的计数：`begin` 记下起点并布设故障，`end` 撤掉故障并返回窗口内的读取次数。
@MainActor
final class FaultWindow {
    let store: CountingSessionTokens
    private var base = 0
    private(set) var used = 0

    init(_ store: CountingSessionTokens) {
        self.store = store
    }

    func begin(_ fault: ReadFault, _ nth: Int) {
        base = store.reads
        fault.arm(store, nth)
    }

    @discardableResult
    func end() -> Int {
        used = store.reads - base
        store.disarm()
        return used
    }
}

/// 按读取位置遍历（两种形态）。`body` 跑一轮完整场景（含窗口的开始与结束），返回窗口内的读取次数。
@MainActor
func forEachReadPosition(
    _ label: String, limit: Int = 40, file: StaticString = #filePath, line: UInt = #line,
    _ body: (ReadFault, Int) async throws -> Int
) async rethrows {
    for fault in ReadFault.allCases {
        var nth = 1
        while true {
            let used = try await body(fault, nth)
            if nth == 1, used == 0 {
                XCTFail("\(label)/\(fault.rawValue)：故障窗口内没有任何身份读取（前提不成立）", file: file, line: line)
                return
            }
            if used < nth {
                break
            }
            nth += 1
            if nth > limit {
                XCTFail("\(label)/\(fault.rawValue)：\(limit) 个位置后仍有读取，覆盖未完成", file: file, line: line)
                return
            }
        }
    }
}

/// 每轮一个独立的 UserDefaults 套件（缓存目录随套件名区分）；用例结束统一删除。
@MainActor
final class FreshSuites {
    private var names: [String] = []

    func make(_ base: String, _ tag: String) -> (String, UserDefaults) {
        let name = "\(base).\(tag).\(UUID().uuidString.prefix(8))"
        names.append(name)
        return (name, UserDefaults(suiteName: name) ?? .standard)
    }

    func removeAll() {
        for name in names {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        }
        names = []
    }
}

/// 钱包写读入口的透明计数（生产 `WalletApi` 调用入口：先同步记一笔、再原样转给真实 ApiClient）。经 `AppWallet(api:)` 注入，
/// 页面、面板、共享结算都经它调用。入口次数与假服务收到的实际发送次数分别断言（发送前本地拒绝时两者不同，F-IOS-16）。
final class CountingWalletApi: WalletApi, @unchecked Sendable {
    private let inner: WalletApi
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    init(_ inner: WalletApi) {
        self.inner = inner
    }

    /// 某个 operationId 经 `send` 入口的调用次数（确认上一笔另记 `confirm:<op>`，放弃另记 `abandon:<op>`）。
    func calls(_ key: String) -> Int {
        lock.withLock { counts[key] ?? 0 }
    }

    private func record(_ key: String) {
        lock.withLock { counts[key, default: 0] += 1 }
    }

    func send(
        _ call: ApiCall, isValid: @escaping @Sendable () -> Bool, sendAllowed: @escaping @Sendable () -> Bool,
        expected: RequestOwnership?
    ) async -> ApiResult {
        record(call.operationId)
        return await inner.send(call, isValid: isValid, sendAllowed: sendAllowed, expected: expected)
    }

    func confirmPending(operationId: String, stepUpToken: String?, target: PendingTarget) async -> ApiResult {
        record("confirm:" + operationId)
        return await inner.confirmPending(operationId: operationId, stepUpToken: stepUpToken, target: target)
    }

    func abandonPending(operationId: String, target: PendingTarget) async -> ApiResult {
        record("abandon:" + operationId)
        return await inner.abandonPending(operationId: operationId, target: target)
    }

    func pendingStatus(operationId: String) async -> PendingLookup {
        await inner.pendingStatus(operationId: operationId)
    }

    func restorePending() async {
        await inner.restorePending()
    }
}

/// 「我的」读取入口的透明计数（生产 `MeApi` 调用入口：先同步记一笔并回调 `onEntry`，再转给真实 ApiClient）。经 `AppMe(api:)` 注入。
/// `onEntry` 在调用入口同步执行：故障窗口可以在「下一个请求进入入口」时结束（之后的网络层读取不在窗口内）。
final class CountingMeApi: MeApi, @unchecked Sendable {
    private let inner: MeApi
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var hook: (@Sendable (String) -> Void)?

    init(_ inner: MeApi) {
        self.inner = inner
    }

    func calls(_ operationId: String) -> Int {
        lock.withLock { counts[operationId] ?? 0 }
    }

    /// 设置 / 清除入口回调（任意线程）。
    func onEntry(_ body: (@Sendable (String) -> Void)?) {
        lock.withLock { hook = body }
    }

    func send(
        _ call: ApiCall, isValid: @escaping @Sendable () -> Bool, sendAllowed: @escaping @Sendable () -> Bool,
        expected: RequestOwnership?
    ) async -> ApiResult {
        let body = lock.withLock { () -> (@Sendable (String) -> Void)? in
            counts[call.operationId, default: 0] += 1
            return hook
        }
        body?(call.operationId)
        return await inner.send(call, isValid: isValid, sendAllowed: sendAllowed, expected: expected)
    }
}
