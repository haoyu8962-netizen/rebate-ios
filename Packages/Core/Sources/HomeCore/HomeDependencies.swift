import Combine
import CouliNetwork
import Foundation
import Generated

public struct HomeCall: Sendable {
    public let anonymous: Bool
    public let owner: RequestOwnership?
    public let sendAllowed: @Sendable () -> Bool
    public init(anonymous: Bool, owner: RequestOwnership?, sendAllowed: @escaping @Sendable () -> Bool) {
        self.anonymous = anonymous
        self.owner = owner
        self.sendAllowed = sendAllowed
    }
}

public protocol HomeContractPort: AnyObject, Sendable {
    func getPage(pageKey: String, call: HomeCall) async -> ApiResult
    func listSectionItems(pageKey: String, sectionId: String, cursor: String?, call: HomeCall) async -> ApiResult
}

public protocol HomeArticlesApi: Sendable {
    func send(_ call: ApiCall, isValid: @escaping @Sendable () -> Bool,
              sendAllowed: @escaping @Sendable () -> Bool, expected: RequestOwnership?) async -> ApiResult
}

extension ApiClient: HomeArticlesApi {}
@MainActor public protocol HomeSignals: AnyObject {
    var visible: Bool { get }
    var screenReader: Bool { get }
    func blockers() -> Set<String>
    var changed: AnyPublisher<Void, Never> { get }
}

public final class HomeTimerHandle {
    private let cancellation: () -> Void
    public init(cancel: @escaping () -> Void) {
        cancellation = cancel
    }

    public func cancel() {
        cancellation()
    }
}

@MainActor public protocol HomeTimers {
    func after(_ ms: Int64, _ block: @escaping @MainActor () -> Void) -> HomeTimerHandle
}

@MainActor public struct HomeSystemTimers: HomeTimers {
    public init() {}
    public func after(_ ms: Int64, _ block: @escaping @MainActor () -> Void) -> HomeTimerHandle {
        let task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(max(0, ms)))
            guard !Task.isCancelled else { return }
            block()
        }
        return HomeTimerHandle { task.cancel() }
    }
}

public protocol HomeImageLoader: Sendable { func load(_ url: String) async -> Bool }
/// 网络线程只读这份锁保护的存活标记，不从发送前闸门跳到主线程。
final class HomeLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true
    var valid: Bool {
        lock.withLock { alive }
    }

    func invalidate() {
        lock.withLock { alive = false }
    }
}

@MainActor public struct HomeDeps {
    let port: HomeContractPort?
    let articles: HomeArticlesApi
    let lkg: HomeLkgStore
    let prefs: HomePrefsStore
    let signals: HomeSignals
    let timers: HomeTimers
    let clock: @Sendable () -> Int64
    let images: HomeImageLoader
    let bundled: @MainActor () -> Data?
    let appVersion: String
    let gate: RetryAfterGate
    let dedupe: CardErrorDedupeBox
    let track: @MainActor (TrackEvent) -> Void
    let open: @MainActor (HomeTap) -> Void
    let forceUpdate: @MainActor () -> Void
    let text: @MainActor (String, [String: String]) -> String
    let identityCheck: @MainActor () -> IdentityCheck
    public func checkIdentity() -> IdentityCheck {
        identityCheck()
    }

    public init(port: HomeContractPort?, articles: HomeArticlesApi, lkg: HomeLkgStore, prefs: HomePrefsStore,
                signals: HomeSignals, timers: HomeTimers, clock: @escaping @Sendable () -> Int64,
                images: HomeImageLoader, bundled: @escaping @MainActor () -> Data?, appVersion: String,
                gate: RetryAfterGate, dedupe: CardErrorDedupeBox, track: @escaping @MainActor (TrackEvent) -> Void,
                open: @escaping @MainActor (HomeTap) -> Void, forceUpdate: @escaping @MainActor () -> Void,
                text: @escaping @MainActor (String, [String: String]) -> String,
                identityCheck: @escaping @MainActor () -> IdentityCheck = { .current }) {
        self.port = port
        self.articles = articles
        self.lkg = lkg
        self.prefs = prefs
        self.signals = signals
        self.timers = timers
        self.clock = clock
        self.images = images
        self.bundled = bundled
        self.appVersion = appVersion
        self.gate = gate
        self.dedupe = dedupe
        self.track = track
        self.open = open
        self.forceUpdate = forceUpdate
        self.text = text
        self.identityCheck = identityCheck
    }
}
