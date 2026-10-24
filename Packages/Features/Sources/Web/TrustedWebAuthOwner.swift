import BridgeHost
import Foundation
import WebKit

// MARK: - 退役、换 store 与数据归属（评审 r1 S0-01、S1-01；r2 S0-R2-01、S1-R2-01）

extension TrustedWebAuthCoordinator {
    static func ownerFile(_ pendingFile: URL) -> URL {
        pendingFile.deletingLastPathComponent().appendingPathComponent("trusted-web-owner.json")
    }

    func trackRetirement(_ retirement: TrustedWebRetirement) {
        retirements.removeAll { $0.unloaded }
        retirements.append(retirement)
    }

    /// 一类清理：系统完成信号与超时赛跑，先到为准；超时后迟到的完成被丢弃（I2）。
    func clear(_ kind: TrustedWebDataKind, in store: WKWebsiteDataStore, documents: [WKWebView]) async -> Bool {
        let operation = dependencies.clear
        let timeout = UInt64(max(dependencies.cleanupTimeout, 0) * 1_000_000_000)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = OnceGate<Bool>(continuation)
            let timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeout)
                guard !Task.isCancelled else { return }
                gate.resume(false)
            }
            Task { @MainActor in
                let confirmed: Bool
                do {
                    confirmed = try await operation(kind, store, documents)
                } catch {
                    confirmed = false
                }
                if gate.resume(confirmed) {
                    timer.cancel()
                }
            }
        }
    }

    /// 当前 store 有旧身份数据时换一个新的空 store，并把当前标识与换下的旧标识持久记录（r2 S0-R2-01）。记不进磁盘为 false。
    func rotateStoreIfDirty() -> Bool {
        guard dirtyStores.contains(where: { $0 === currentStore }) else { return true }
        let fresh = dependencies.makeStore()
        var record = storeRegistry.load()
        if let old = TrustedWebDataStore.identifier(of: currentStore) {
            record.retired.insert(old)
        }
        record.current = TrustedWebDataStore.identifier(of: fresh)
        record.retired = record.retired.filter { $0 != record.current }
        do {
            try storeRegistry.save(record)
        } catch {
            return false
        }
        currentStore = fresh
        if dependencies.isProduction {
            TrustedWebDataStore.adopt(fresh)
        }
        return true
    }

    /// 删除换下的旧 store（后台，不阻塞页面）：持久的待删列表；生产冷启动另外清掉一切非当前标识的残留 store。删不掉（仍在使用）
    /// 的留在列表里，下次事务成功后与冷启动时重试。旧 store 里的数据此前已经过两遍清理，且不再被任何可信文档使用。
    func startStoreCleanup(sweepAll: Bool) {
        guard let remove = dependencies.removeStore else { return }
        let registry = storeRegistry
        let production = dependencies.isProduction && sweepAll
        Task { @MainActor in
            var candidates = registry.load().retired
            let current = registry.load().current
            if production, #available(iOS 17.0, *) {
                for id in await WKWebsiteDataStore.allDataStoreIdentifiers where id != current {
                    candidates.insert(id)
                }
            }
            var removed: Set<UUID> = []
            for id in candidates where id != current {
                if await (try? remove(id)) != nil {
                    removed.insert(id)
                }
            }
            var record = registry.load()
            record.retired = record.retired.union(candidates).subtracting(removed).filter { $0 != record.current }
            try? registry.save(record)
        }
    }

    /// 等本协调器全部退役的旧 WebView 卸载（总时限 `cleanupTimeout`）；超时为 false，未卸载的留着下次再等。
    func waitRetired() async -> Bool {
        let deadline = Date().addingTimeInterval(max(dependencies.cleanupTimeout, 0))
        for retirement in retirements where !retirement.unloaded {
            guard await retirement.waitUnloaded(timeout: deadline.timeIntervalSinceNow) else {
                return false
            }
        }
        retirements.removeAll { $0.unloaded }
        return true
    }

    /// 首次确认身份时与持久的数据归属比对（S1-01）：归属账号与当前不同（含游客 → 账号）或归属记录读不出 → 当作待清理补清，
    /// 再放行页面；归属缺失（从没确认过）→ 记下当前身份；同一账号 → 只更新记录。
    /// 覆盖「新会话已写盘、待清标记还没写盘就崩溃」与「AppWeb 创建前发出的清会话通知无人接收」两种窗口。
    func reconcileOwner(_ current: WebSessionIdentity) {
        guard pending == nil else { return }
        switch ownerStore.load() {
        case .none:
            recordOwner(current)
        case let .pending(owner):
            guard let owner else {
                apply(.reload, owner: nil)
                return
            }
            // 归属账号与当前不同（含游客 → 账号的崩溃窗口，r2 S2-R2-03）→ 先补清。
            if owner.account != current.account {
                apply(.reload, owner: owner)
            } else if owner != current {
                recordOwner(current)
            }
        }
    }

    /// 冷启动读不出身份（r2 S2-R2-04）：有任何归属记录（含读不出）就按归属不明先补清；没有记录（从没加载过可信文档）不动。
    func reconcileUnknownOwner() {
        guard pending == nil else { return }
        if case let .pending(owner) = ownerStore.load() {
            apply(.reload, owner: owner)
        }
    }

    /// 记下可信 store 当前的数据归属；身份未知时删掉记录（下次首次确认时按缺失处理）。写失败不阻断：下次比对时多清不少清。
    func recordOwner(_ owner: WebSessionIdentity?) {
        if let owner, owner.known {
            try? ownerStore.save(owner: owner)
        } else {
            try? ownerStore.remove()
        }
    }
}

/// 只结算一次的续体（先到为准，之后的结果丢弃）。
@MainActor
final class OnceGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    /// 返回这一次是否真的结算了。
    @discardableResult
    func resume(_ value: Value) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }
}

/// 倒数到零时调用一次 `done`。
@MainActor
final class Countdown {
    private var remaining: Int
    private let done: @MainActor () -> Void

    init(_ count: Int, done: @escaping @MainActor () -> Void) {
        remaining = count
        self.done = done
    }

    func tick() {
        guard remaining > 0 else { return }
        remaining -= 1
        if remaining == 0 {
            done()
        }
    }
}
