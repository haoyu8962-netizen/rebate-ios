import Config
import Router
import SwiftUI

// TODO(APP-02b): 启动、隐私闸门、Tab；TODO(APP-02c): 强更。APP-02a 接入 Router 与深链（最小外壳）。
@main
struct CouliApp: App {
    @StateObject private var environment: EnvironmentStore
    @StateObject private var router: Router
    private let routing: AppRouting

    init() {
        let environment = BuildInfo.makeEnvironmentStore()
        let routing = AppRouting(environment: environment)
        _environment = StateObject(wrappedValue: environment)
        _router = StateObject(wrappedValue: routing.router)
        self.routing = routing
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(router)
                .onOpenURL { url in
                    routing.handle(url: url)
                }
                .onChange(of: environment.gate) { _ in
                    routing.drainLaunchQueue()
                }
        }
    }
}
