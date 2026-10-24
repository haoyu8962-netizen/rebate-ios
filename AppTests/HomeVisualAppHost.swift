import ClientCore
import Clipboard
@testable import Couli
import Foundation
import MeCore
import OrderCore
import SwiftUI

/// 只换端口与系统依赖；完整 RootView / Router / TabShell / HomeRouteView 使用产品实现。
@MainActor
enum HomeVisualAppHost {
    static func root(_ fixture: HomeAppFixture, defaults: UserDefaults, directory: URL) -> AnyView {
        let clipboard = AppClipboard(
            system: FakeSystemClipboard(), store: MemoryClipboardHashStore(), api: FakeParseApi(),
            router: fixture.router,
            deps: AppClipboard.Deps(
                privacy: { fixture.privacy.routerPrivacy }, privacyPrompting: { fixture.privacy.isPrompting },
                forceUpdate: { false }, configJson: { "{}" },
                guest: { fixture.home.controller.identity.level != .member },
                sessionGeneration: { fixture.client.sessionGeneration }, networkEpoch: { 1 }, serverForced: {},
                networkForced: { _ in }
            )
        )
        let search = AppSearch(network: fixture.network, config: fixture.config, privacy: fixture.privacy,
                               routing: fixture.routing, restorationDefaults: defaults,
                               credentialsReadable: { fixture.runner.credentialsReadable })
        search.clipboard = clipboard
        let local = ClientFile(name: "me-visual.json", baseDirectory: directory)
        let me = AppMe(
            network: fixture.network, routing: fixture.routing, config: fixture.config, login: fixture.login,
            update: fixture.update, system: FakeMeSystem(), mask: AmountMaskStore(defaults: defaults),
            local: MeLocalStore(file: local, pending: local.sibling("me-visual.pending")),
            pushSource: TestPushSource(token: nil),
            credentialsReadable: { fixture.runner.credentialsReadable }, withdrawalRegistry: fixture.withdrawal,
            environmentRegistry: fixture.environmentSwitch
        )
        let permissions = AppPermissions(file: ClientFile(name: "permissions.json", baseDirectory: directory))
        return AnyView(RootView(routing: fixture.routing)
            .environmentObject(fixture.environment).environmentObject(fixture.router)
            .environmentObject(fixture.privacy).environmentObject(fixture.update)
            .environmentObject(permissions).environmentObject(fixture.login)
            .environmentObject(search).environmentObject(clipboard).environmentObject(me)
            .environmentObject(fixture.home))
    }
}
