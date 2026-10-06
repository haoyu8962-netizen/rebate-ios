@testable import Couli
import Foundation
import Router
import Update

/// 测试替身：版本检查器。`outcome` 为 nil 时不回调（检查一直进行中），否则同步回调（不必等异步）。
@MainActor
final class StubUpdateChecker: UpdateChecker {
    var outcome: UpdateCheckOutcome?
    private(set) var calls = 0
    private var pending: [@MainActor (UpdateCheckOutcome) -> Void] = []

    init(_ outcome: UpdateCheckOutcome?) {
        self.outcome = outcome
    }

    func check(completion: @escaping @MainActor (UpdateCheckOutcome) -> Void) {
        calls += 1
        if let outcome {
            completion(outcome)
        } else {
            pending.append(completion)
        }
    }

    /// 投递挂着的检查结果。
    func deliver(_ outcome: UpdateCheckOutcome) {
        let waiting = pending
        pending = []
        for completion in waiting {
            completion(outcome)
        }
    }
}

/// 测试替身：商店能力。
@MainActor
final class StubStoreAccess: StoreAccess {
    var installSource: String?
    var openable: Set<String>
    var openSucceeds = true
    private(set) var opened: [String] = []

    init(installSource: String? = nil, openable: Set<String> = []) {
        self.installSource = installSource
        self.openable = openable
    }

    func canOpen(_ storeKey: String) -> Bool {
        openable.contains(storeKey)
    }

    func open(_ storeKey: String, completion: @escaping @MainActor (Bool) -> Void) {
        opened.append(storeKey)
        completion(openSucceeds)
    }
}

enum UpdateFixtures {
    /// 不设最低与建议版本：任何本机版本都是 ok。
    static let ok = UpdateCheckResult(
        minSupported: nil, recommended: nil, latest: "1.0.0", defaultStore: "huawei",
        stores: [UpdateStoreListing(store: "huawei", version: "1.0.0")]
    )

    /// 契约示例的形状：强更（min = latest = 99.0.0），huawei 已上架 99.0.0。
    static let force = UpdateCheckResult(
        minSupported: "99.0.0", recommended: "99.0.0", latest: "99.0.0", defaultStore: "huawei",
        stores: [UpdateStoreListing(store: "huawei", version: "99.0.0")],
        updateTitle: "t", updateNotes: "a\nb"
    )

    /// 强更，但没有任何已知上架版本。
    static let forceNoStore = UpdateCheckResult(
        minSupported: "99.0.0", recommended: "99.0.0", latest: "99.0.0", defaultStore: "huawei", stores: []
    )

    /// 建议更新（recommended 99.0.0，latest 99.1.0），默认商店 huawei 已上架 99.1.0。
    static let recommend = UpdateCheckResult(
        minSupported: nil, recommended: "99.0.0", latest: "99.1.0", defaultStore: "huawei",
        stores: [UpdateStoreListing(store: "huawei", version: "99.1.0")]
    )

    @MainActor
    static func makeUpdate(
        checker: StubUpdateChecker = StubUpdateChecker(.success(ok)),
        stores: StubStoreAccess = StubStoreAccess(),
        store: MemoryUpdateStore = MemoryUpdateStore(),
        clock: @escaping () -> Int64 = PendingActionStore.wallClockMillis
    ) -> AppUpdate {
        let gate = UpdateGate(
            store: store, clock: clock, appVersion: "1.0.0",
            platform: "ios", channel: "appstore", installSource: stores.installSource
        )
        return AppUpdate(gate: gate, checker: checker, stores: stores, clock: clock)
    }
}
