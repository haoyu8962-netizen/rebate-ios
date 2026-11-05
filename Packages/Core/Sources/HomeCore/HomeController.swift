import Combine
import CouliNetwork
import Foundation
import Generated

@MainActor public final class HomeController: ObservableObject, IdentityResumable {
    public let identity: HomeIdentity
    public let id: UUID
    @Published public internal(set) var state: HomeUiState
    public internal(set) var settledPageResults = 0
    let deps: HomeDeps
    let preview: Bool
    let lifetime = HomeLifetime()
    let tasks = SettlingTasks()
    let deferrals = IdentityDeferral()
    let prefsTicket: HomeWriteTicket
    var started = false
    var userInteracted = false
    var pageRequest = 0
    var page: HomePage?
    var subscriptions: Set<AnyCancellable> = []
    var fallbackTimer: HomeTimerHandle?
    var gateTimer: HomeTimerHandle?
    var noticeTimer: HomeTimerHandle?
    var sectionItems: [String: [HomeItem]] = [:]
    var apiNotices: [String: [HomeNotice]] = [:]
    var feeds: [String: HomeFeedUi] = [:]
    var pendingSections: Set<String> = []
    /// D4（D10-607）：卡片还没有任何商品时，对「items 空但带游标」自动续取，每张卡每次渲染最多 3 次。已用次数与待续游标
    /// 跨限流保留：续取被本地闸门或 42901 拦下，放开后从原游标恢复、不重新计数（安卓 r1 S1）。
    var continuationCounts: [String: Int] = [:]
    var continuationCursors: [String: String] = [:]
    var loadingSections: Set<String> = []
    var failedImages: Set<HomeImageTicket> = []
    var memoryClosed: Set<String> = []
    var candidate: HomeSection?
    var popupReady = false
    var coldStartShown = false

    public init(identity: HomeIdentity, deps: HomeDeps, preview: Bool = false) {
        self.identity = identity
        self.deps = deps
        self.preview = preview
        let id = UUID()
        self.id = id
        state = HomeUiState(render: HomeRenderTicket(controller: id, generation: 0))
        prefsTicket = deps.prefs.ticket()
        deps.signals.changed.sink { [weak self] in self?.signalsChanged() }.store(in: &subscriptions)
        // @Published 发的是新值；deadline 已先写入，发送前检查不依赖 blocked。
        deps.gate.$blocked.sink { [weak self] blocked in self?.gateChanged(blocked) }.store(in: &subscriptions)
    }

    public var currentVersion: HomeVersionInfo? {
        guard let version = state.pageVersion, let source = state.source else { return nil }
        return HomeVersionInfo(version: version, source: source)
    }

    /// 界面文案一律经注入的文案函数取（App：契约字典 → 草稿表）；视图不另查表，页底口径说明不会漏出键名（APP-11 P2）。
    public func text(_ key: String) -> String {
        deps.text(key, [:])
    }

    public func whenIdle() async {
        await tasks.whenIdle()
    }

    func accepts(_ render: HomeRenderTicket) -> Bool {
        lifetime.valid && render == state.render
    }

    public func start() {
        guard !started, lifetime.valid, !preview else { return }
        started = true
        afterIdentity(slot: "initial_lkg") { [weak self] in self?.readInitialLkg() }
        if deps.port == nil {
            showBundled()
        } else {
            fallbackTimer = deps.timers.after(1500) { [weak self] in self?.showBundled() }
            fetchPage(pull: false)
        }
    }

    private func readInitialLkg() {
        guard state.source == nil else { return }
        if let scope = identity.lkgScope, let data = deps.lkg.read(scope) {
            if let cached = decode(data) {
                display(cached, source: .lkg, cold: true)
            } else {
                try? deps.lkg.clearScope(scope)
            }
        }
    }

    func decode(_ data: Data) -> HomePage? {
        HomeJson.parse(data, platform: "ios", appVersion: deps.appVersion)
    }

    func showBundled() {
        // 未确认身份时仍可显示通用包内页；已确定换代的旧实例不能采用计时结果。
        guard lifetime.valid, deps.identityCheck() != .stale, state.source == nil else { return }
        guard let data = deps.bundled(), let page = decode(data) else {
            state.loadFailed = failure(.transportFailure(kind: "invalid_page", httpStatus: nil,
                                                         idempotencyKey: nil, pendingKeyUnknown: false))
            return
        }
        display(page, source: .bundled, cold: true)
    }

    public func refresh(_ render: HomeRenderTicket) {
        guard accepts(render), !preview else { return }
        guard deps.port != nil else { state.refreshing = false
            return
        }
        guard !deps.gate.active else { state.refreshing = false
            toast429()
            return
        }
        fetchPage(pull: true)
    }

    public func retryLoadFailed(_ render: HomeRenderTicket) {
        refresh(render)
    }

    public func interacted(_ render: HomeRenderTicket) {
        if accepts(render) {
            userInteracted = true
        }
    }

    public func consumeToast(_ id: UUID) {
        if state.toast?.id == id {
            state.toast = nil
        }
    }

    public func showDraft(_ data: Data) {
        guard preview, lifetime.valid, let page = decode(data) else { return }
        display(page, source: .network, cold: true)
    }

    public func invalidate() {
        lifetime.invalidate()
        fallbackTimer?.cancel()
        gateTimer?.cancel()
        noticeTimer?.cancel()
        deferrals.reset()
        subscriptions.removeAll()
        candidate = nil
        pendingSections = []
        page = nil
        state = HomeUiState(render: HomeRenderTicket(controller: id, generation: state.render.generation + 1))
    }

    func call(_ probe: SendProbe) -> HomeCall {
        HomeCall(anonymous: identity.level == .basic, owner: identity.request, sendAllowed: probe.allowed)
    }

    func probe() -> SendProbe {
        deps.gate.probe(extra: { [lifetime] in lifetime.valid })
    }

    func fetchPage(pull: Bool) {
        guard lifetime.valid, let port = deps.port else { return }
        pageRequest += 1
        let sequence = pageRequest
        let write = deps.lkg.ticket()
        let probe = probe()
        let call = call(probe)
        if pull {
            state.refreshing = true
        }
        tasks.begin()
        Task { [self] in
            let result = await port.getPage(pageKey: "home", call: call)
            defer { settledPageResults += 1
                tasks.end()
            }
            afterIdentity(slot: "page.\(sequence)") { [weak self] in
                self?.settlePage(result, sequence: sequence, pull: pull, write: write, probe: probe)
            }
        }
    }

    func settlePage(_ result: ApiResult, sequence: Int, pull: Bool, write: HomeWriteTicket, probe: SendProbe) {
        guard lifetime.valid else { return }
        effects(result)
        let latest = sequence == pageRequest
        if pull, latest {
            state.refreshing = false
        }
        if case let .success(data?, _, _) = result, let decoded = decode(data) {
            if !decoded.sections.isEmpty, let scope = identity.lkgScope {
                _ = deps.lkg.write(scope, data, ticket: write)
            }
            guard latest else { return }
            let shouldShow = pull || state.source == nil || (state.source == .bundled && !userInteracted)
            if shouldShow {
                display(decoded, source: .network, cold: !pull)
            }
        } else if pull, latest {
            state
                .toast = HomeToast(message: probe.gated(result) ? deps.text("error.42901", [:]) : failure(result)
                    .message)
        }
    }

    func afterIdentity(slot: String, _ action: @escaping @MainActor () -> Void) {
        guard lifetime.valid else { return }
        guard deferrals.admit(deps.identityCheck(), slot: slot, resume: { [weak self] in
            self?.afterIdentity(slot: slot, action)
        }) else { return }
        action()
    }

    public func resumeAfterIdentityConfirmed() {
        deferrals.resume()
    }

    func toast429() {
        state.toast = HomeToast(message: deps.text("error.42901", [:]))
    }

    func effects(_ result: ApiResult) {
        guard case let .failure(code, _, _, _, effect, _) = result else { return }
        if code == 42901 {
            deps.gate.start(effect.disableMillis ?? 5000)
        }
        if code == 10405 {
            deps.forceUpdate()
        }
    }

    func failure(_ result: ApiResult) -> HomeFailureUi {
        HomeErrors.failure(result, blocked: deps.gate.active, text: deps.text)
    }
}

public enum HomeErrors {
    @MainActor public static func failure(_ result: ApiResult, blocked: Bool,
                                          text: (String, [String: String]) -> String) -> HomeFailureUi {
        var code = 50001
        var trace: String?
        var key = "error.50001"
        if case let .failure(value, _, _, traceId, effect, _) = result {
            code = value
            trace = traceId
            key = effect.textKey ?? "error.\(code)"
            if (50000..<60000).contains(code), ErrorCodes.info(code) == nil {
                key = "error.50001"
            }
        }
        if case .localReject(reason: LocalRejectReason.sendBlocked) = result {
            code = 42901
            key = "error.42901"
        }
        let message = code == 42901 ? text(key, [:]) : ErrorTrace.message(
            key: key, traceId: trace, append: (50000..<60000).contains(code), format: text
        )
        return HomeFailureUi(
            code: {
                if case .failure = result {
                    return code
                }
                if code == 42901 {
                    return code
                }
                return nil
            }(),
            traceId: trace,
            message: message,
            retryEnabled: !blocked
        )
    }
}
