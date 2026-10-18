#if DEBUG
import Combine
import CouliNetwork
import Foundation
import HomeCore
import Router

struct HomePreviewBanner {
    let pageKey: String
    let environmentName: String
    let draftVersion: Int
    let validUntil: String
}

@MainActor final class HomePreviewModel: ObservableObject {
    enum Phase: Equatable { case loading, draft, expired, failed(HomeFailureUi?), invalidated }
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var controller: HomeController?
    @Published private(set) var banner: HomePreviewBanner?
    let signals = AppHomeSignals()
    let destination: RouteDestination
    private let identity: HomeIdentity
    private let deps: HomeDeps
    private unowned let home: AppHome
    private let life = DebugHomeRequestLife()
    private let tasks = SettlingTasks()
    private let deferrals = IdentityDeferral()
    private var retired: [HomeController] = []
    private var gateObservation: AnyCancellable?
    private var gateTimer: HomeTimerHandle?
    private var loading = false
    init(home: AppHome, destination: RouteDestination) {
        self.home = home
        self.destination = destination
        identity = home.controller.identity
        deps = home.dependencies(signals: signals)
        gateObservation = home.gate.$blocked.sink { [weak self] _ in self?.gateChanged() }
        fetch()
    }

    func whenIdle() async {
        await tasks.whenIdle()
        await controller?.whenIdle()
        for controller in retired {
            await controller.whenIdle()
        }
        retired = []
    }

    func retry() {
        guard life.valid, !home.gate.active, !loading else { return }
        fetch()
    }

    private func fetch() {
        guard life.valid, !loading, !home.gate.active,
              let pageKey = destination.params["page_key"]?.stringValue,
              let token = destination.params["token"]?.stringValue else { return }
        loading = true
        phase = .loading
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "token", value: token)]
        let call = ApiCall(
            operationId: "previewPage",
            pathParams: ["page_key": pageKey],
            query: query.percentEncodedQuery,
            forceUpdateByCaller: true
        )
        let probe = home.gate.probe(extra: { [life] in life.valid })
        tasks.begin()
        Task { [self] in
            let result = await home.api.send(
                call,
                isValid: { [life] in life.valid },
                sendAllowed: probe.allowed,
                expected: identity.request
            )
            defer { loading = false
                tasks.end()
            }
            accept(result, pageKey: pageKey)
        }
    }

    private func accept(_ result: ApiResult, pageKey: String) {
        guard life.valid, deferrals.admit(deps.checkIdentity(), slot: "preview", resume: { [weak self] in
            self?.accept(result, pageKey: pageKey)
        }) else { return }

        if case let .success(data?, _, _) = result,
           let page = HomeJson.parse(data, platform: "ios", appVersion: home.appVersion) {
            let controller = HomeController(
                identity: identity,
                deps: deps,
                preview: true
            )
            self.controller = controller
            controller.showDraft(data)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "HH:mm"
            banner = HomePreviewBanner(pageKey: pageKey, environmentName: identity.env, draftVersion: page.version,
                                       validUntil: formatter
                                           .string(from: Date(timeIntervalSince1970: Double(home.clock() + 600000) /
                                                   1000)))
            phase = .draft
        } else if case .failure(code: 30701, msg: _, data: _, traceId: _, effect: _, idempotencyKey: _) = result {
            phase = .expired
        } else {
            if case let .failure(code, _, _, _, effect, _) = result {
                if code == 42901 {
                    home.gate.start(effect.disableMillis ?? 5000)
                }
                if code == 10405 {
                    home.update.onServerForced()
                }
            }
            phase = .failed(HomeErrors.failure(result, blocked: home.gate.active, text: HomeDraftTexts.text))
            gateChanged()
        }
    }

    func resumeAfterIdentityConfirmed() {
        deferrals.resume()
        controller?.resumeAfterIdentityConfirmed()
    }

    private func gateChanged() {
        guard life.valid else { return }
        let active = home.gate.active
        if case var .failed(error) = phase {
            error?.retryEnabled = !active
            phase = .failed(error)
        }
        gateTimer?.cancel()
        if active {
            gateTimer = home.timers.after(max(1, home.gate.remainingMillis)) { [weak self] in self?.gateChanged() }
        }
    }

    func leave() {
        life.invalidate()
        deferrals.reset()
        gateTimer?.cancel()
        gateObservation = nil
        if let controller {
            controller.invalidate()
            retired.append(controller)
        }
        controller = nil
        banner = nil
        phase = .invalidated
    }

    func exit() {
        leave()
        // 只移除本导航实例；既不按名字批量删除，也不改变原 Tab。
        home.routing.router.path.removeAll { $0.id == destination.id }
    }

    func switchEnvironment() {
        home.onOpenEnvironmentSwitch()
    }
}

final class DebugHomeRequestLife: @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true
    var valid: Bool {
        lock.withLock { alive }
    }

    func invalidate() {
        lock.withLock { alive = false }
    }
}

extension AppHome {
    func preview(for destination: RouteDestination) -> HomePreviewModel {
        if let existing = previews[destination.id] {
            return existing
        }
        checkSession()
        let model = HomePreviewModel(home: self, destination: destination)
        previews[destination.id] = model
        updateSignals()
        return model
    }
}

enum HomePreviewPolicy {
    static func of(routeParams: [String: String], result: [String: Any]) -> [String: Any] {
        ["pageKey": routeParams["page_key"] ?? "", "token": routeParams["token"] ?? "",
         "screenRaw": result["kind"] as? String == "ok" ? "draft" : result["code"] as? Int == 30701 ? "expired" :
             "error",
         "writesLkg": false, "writesPopupCount": false, "writesNoticeClosed": false, "sendsEvents": false,
         "switchesEnv": false]
    }
}
#endif
