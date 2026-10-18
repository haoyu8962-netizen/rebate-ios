import Combine
import Config
import CouliNetwork
import Foundation
import Generated
import HomeCore
import Privacy
import Router
import UIKit

@MainActor final class AppHome: ObservableObject {
    @Published private(set) var controller: HomeController!
    @Published private(set) var grayscale = false
    let network: AppNetwork
    let routing: AppRouting
    let config: AppConfig
    let update: AppUpdate
    let privacy: PrivacyController
    let environment: EnvironmentStore
    let storage: HomeStorage
    let port: HomeContractPort?
    let api: HomeArticlesApi
    let timers: HomeTimers
    let clock: @Sendable () -> Int64
    let images: HomeImageLoader
    let bundled: @MainActor () -> Data?
    let appVersion: String
    let gate: RetryAfterGate
    let identity: AppIdentity
    let reconciler: SessionReconciler
    private var currentEnvironmentId: String
    let signals = AppHomeSignals()
    private var confirmedMemberScope: HomeScopeKey?
    var track: (TrackEvent) -> Void = { _ in }
    var onOpenEnvironmentSwitch: () -> Void = {}
    weak var clipboard: AppClipboard? {
        didSet {
            clipboardObservation = clipboard?.$prompt.sink { [weak self] value in
                self?.clipboardPrompt = value != nil
                self?.updateSignals()
            }
        }
    }

    var sceneActive = true
    var appeared = false
    var path: [RouteDestination]
    var root: RouteDestination
    var privacyPrompt = false
    var updatePrompt = false
    var forced = false
    var clipboardPrompt = false
    private var clipboardObservation: AnyCancellable?
    private var subscriptions: Set<AnyCancellable> = []
    #if DEBUG
    var previews: [UUID: HomePreviewModel] = [:]
    #endif

    init(network: AppNetwork, routing: AppRouting, config: AppConfig, login: AppLogin, update: AppUpdate,
         privacy: PrivacyController, environment: EnvironmentStore, storage: HomeStorage = .shared,
         port: HomeContractPort? = nil, timers: HomeTimers = HomeSystemTimers(),
         clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         images: HomeImageLoader = AppHomeImages(), bundled: @escaping @MainActor () -> Data? = HomeBundled.data,
         appVersion: String = AppRouting.appVersion,
         credentialsReadable: @escaping @MainActor () -> Bool = { PrivacyWithdrawalCleanup.runner.credentialsReadable },
         api: HomeArticlesApi? = nil) {
        self.network = network
        self.routing = routing
        self.config = config
        self.update = update
        self.privacy = privacy
        self.environment = environment
        currentEnvironmentId = environment.current.id
        self.storage = storage
        self.port = port
        self.api = api ?? network.client
        self.timers = timers
        self.clock = clock
        self.images = images
        self.bundled = bundled
        self.appVersion = appVersion
        gate = RetryAfterGate(clock: clock)
        let identity = AppIdentity(client: network.client, credentialsReadable: credentialsReadable)
        self.identity = identity
        let snapshot = identity.snapshot()
        reconciler = SessionReconciler(snapshot)
        path = routing.router.path
        root = routing.router.tabRoot
        controller = makeController(snapshot)
        confirmedMemberScope = snapshot.member ? controller.identity.lkgScope : nil
        observe(login: login)
        privacyPrompt = privacy.isPrompting
        updateSignals()
    }

    private func observe(login: AppLogin) {
        login.$sessionVersion.dropFirst().sink { [weak self] _ in self?.checkSession() }.store(in: &subscriptions)
        privacy.observeState { [weak self] state in
            self?.privacyPrompt = state.mustPrompt
            self?.checkSession()
            self?.updateSignals()
        }
        environment.$current.dropFirst().sink { [weak self] current in
            self?.currentEnvironmentId = current.id
            self?.checkSession(environmentId: current.id)
        }.store(in: &subscriptions)
        environment.$switchAttempts.dropFirst().sink { [weak self] _ in self?.checkSession() }.store(in: &subscriptions)
        routing.router.$path.sink { [weak self] value in self?.pathChanged(value) }.store(in: &subscriptions)
        routing.router.$tabRoot.sink { [weak self] value in self?.root = value
            self?.updateSignals()
        }
        .store(in: &subscriptions)
        update.$ui.sink { [weak self] value in
            self?.updatePrompt = value.showPrompt
            self?.forced = value.status == .belowMin
            self?.updateSignals()
        }.store(in: &subscriptions)
        config.$snapshotJson.sink { [weak self] json in self?.configurationChanged(json) }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSignals() }
            }.store(in: &subscriptions)
    }

    func makeController(_ snapshot: IdentitySnapshot, environmentId: String? = nil) -> HomeController {
        let basic = privacy.state.decision == .basicMode
        let owner = HomeIdentity(env: environmentId ?? environment.current.id,
                                 level: basic ? .basic : snapshot.member ? .member : .guest,
                                 userId: basic ? nil : snapshot.account, loginEpoch: basic ? nil : snapshot.loginEpoch,
                                 known: basic || snapshot.known, request: basic ? nil : snapshot.request)
        return HomeController(
            identity: owner,
            deps: dependencies(signals: signals, snapshot: snapshot, environmentId: environmentId)
        )
    }

    func dependencies(signals: AppHomeSignals, snapshot: IdentitySnapshot? = nil,
                      environmentId: String? = nil) -> HomeDeps {
        let fixed = snapshot ?? identity.snapshot()
        let fixedEnvironment = environmentId ?? currentEnvironmentId
        let basic = privacy.state.decision == .basicMode
        return HomeDeps(port: port, articles: api, lkg: storage.lkg, prefs: storage.prefs, signals: signals,
                        timers: timers, clock: clock, images: images, bundled: bundled, appVersion: appVersion,
                        gate: gate, dedupe: .shared, track: { [weak self] in self?.track($0) },
                        open: { [weak self] tap in self?.routing.router.open(RouteRequest(
                            route: tap.target.route,
                            values: tap.target.params ?? [:],
                            from: .inApp
                        )) },
                        forceUpdate: { [weak update] in update?.onServerForced() }, text: HomeDraftTexts.text,
                        identityCheck: { [weak self] in
                            guard let self, environment.current.id == fixedEnvironment,
                                  (self.privacy.state.decision == .basicMode) == basic else { return .stale }
                            if basic {
                                return .current
                            }
                            let now = identity.snapshot()
                            return AppIdentity.check(matchesNow: now.mark == fixed.mark,
                                                     fixed: FixedIdentity(key: AppIdentity.ownerKey(
                                                         account: fixed.account,
                                                         fixed,
                                                         cleared: 0
                                                     ),
                                                     account: fixed.account, known: fixed.known),
                                                     now: now, cleared: 0)
                        })
    }

    func checkSession() {
        checkSession(environmentId: environment.current.id)
    }

    private func checkSession(environmentId: String) {
        let snapshot = identity.snapshot()
        let outcome = reconciler.observe(snapshot)
        let basic = privacy.state.decision == .basicMode
        let boundaryChanged = controller.identity.env != environmentId || (controller.identity.level == .basic) != basic
        if !boundaryChanged, outcome == .deferred {
            return
        }
        if !boundaryChanged, outcome == .same, controller.identity.known {
            controller.resumeAfterIdentityConfirmed()
            #if DEBUG
            for model in previews.values {
                model.resumeAfterIdentityConfirmed()
            }
            #endif
            return
        }
        controller.invalidate()
        #if DEBUG
        for model in previews.values {
            model.leave()
        }
        #endif
        gate.reset()
        if outcome == .changed, let scope = confirmedMemberScope {
            try? storage.lkg.clearScope(scope)
        }
        controller = makeController(snapshot, environmentId: environmentId)
        if snapshot.known {
            confirmedMemberScope = snapshot.member ? controller.identity.lkgScope : nil
        }
        if appeared {
            controller.start()
        }
        updateSignals()
    }

    func tabAppeared() {
        checkSession()
        appeared = true
        controller.start()
        updateSignals()
    }

    func sceneChanged(active: Bool) {
        sceneActive = active
        checkSession()
        updateSignals()
    }

    func connect(me: AppMe) {
        me.homeVersion = { [weak self] in self?.currentVersionText }
    }

    var currentVersionText: String? {
        controller.currentVersion.map { "\($0.version) (\($0.source.rawValue))" }
    }

    func pathChanged(_ value: [RouteDestination]) {
        path = value
        #if DEBUG
        for id in Array(previews.keys) where !value.contains(where: { $0.id == id }) {
            previews.removeValue(forKey: id)?.leave()
        }
        #endif
        updateSignals()
    }

    func updateSignals() {
        var blockers: Set<String> = []
        if privacyPrompt {
            blockers.insert("privacy_dialog")
        }
        if updatePrompt {
            blockers.insert("update_prompt")
        }
        if forced {
            blockers.insert("force_update")
        }
        if clipboardPrompt {
            blockers.insert("clipboard_prompt")
        }
        signals.set(
            visible: sceneActive && path.isEmpty && root.route == "Home",
            reader: UIAccessibility.isVoiceOverRunning,
            blockers: blockers
        )
        #if DEBUG
        for (id, model) in previews {
            model.signals.set(
                visible: sceneActive && path.last?.id == id,
                reader: UIAccessibility.isVoiceOverRunning,
                blockers: blockers
            )
        }
        #endif
    }

    private func configurationChanged(_ json: String) {
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        let flags = (object?["features"] as? [String: Any])?["flags"] as? [String: Any]
        grayscale = flags?["ui.grayscale"] as? Bool ?? false
    }
}
