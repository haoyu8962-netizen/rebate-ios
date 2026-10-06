#if DEBUG
import Config
import SwiftUI
import Update

/// 调试面板标记。Release 制品扫描（tools/ci/release-scan.sh）查这个字符串，命中即阻断发布。
enum DebugPanelMarker {
    static let identifier = "COULI_DEBUG_PANEL"
}

// TODO(APP-02): 入口由 AppShell 挪到正式的调试入口；诊断、时钟偏移等能力在各自任务加入。
/// 最小调试面板：显示当前环境、切换环境（只在 Debug / Staging 编译）。
struct DebugPanelView: View {
    @ObservedObject var store: EnvironmentStore
    @ObservedObject var update: AppUpdate
    @State private var lastError: String?
    @State private var updateScenario = DebugUpdateScenario.current

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AppEnvironment.selectable) { environment in
                        Button {
                            select(environment)
                        } label: {
                            HStack {
                                Text(verbatim: environment.id)
                                Spacer()
                                if environment == store.current {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(!store.debugCapabilities.isAvailable(.switchServer))
                        .accessibilityIdentifier("debug.environment.\(environment.id)")
                    }
                } header: {
                    Text(verbatim: "Environment")
                } footer: {
                    Text(verbatim: "Switching clears local session and caches first.")
                }
                Section {
                    Text(verbatim: store.current.endpoints.apiBaseURL.absoluteString)
                    Text(verbatim: store.current.endpoints.h5BaseURL.absoluteString)
                } header: {
                    Text(verbatim: "Endpoints")
                }
                Section {
                    ForEach(DebugUpdateScenario.allCases) { scenario in
                        Button {
                            DebugUpdateScenario.current = scenario
                            updateScenario = scenario
                            update.debugRecheck()
                        } label: {
                            HStack {
                                Text(verbatim: scenario.label)
                                Spacer()
                                if scenario == updateScenario {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(!store.debugCapabilities.isAvailable(.mockData))
                        .accessibilityIdentifier("debug.update.\(scenario.rawValue)")
                    }
                    Text(verbatim: "status \(update.ui.status.rawValue)")
                        .accessibilityIdentifier("debug.update.status")
                } header: {
                    Text(verbatim: "App update check (fake data)")
                } footer: {
                    Text(verbatim: AppVersionCheckExample.marker)
                }
                Section {
                    NavigationLink {
                        ComponentCatalogView()
                    } label: {
                        Text(verbatim: "Component catalog")
                    }
                    .accessibilityIdentifier("debug.componentCatalog")
                } header: {
                    Text(verbatim: "Design system")
                }
                Section {
                    ForEach(DebugOnlyRoutes.all.keys.sorted(), id: \.self) { name in
                        Text(verbatim: name)
                    }
                    .disabled(!store.debugCapabilities.isAvailable(.debugRoutes))
                } header: {
                    Text(verbatim: "Debug-only routes")
                } footer: {
                    Text(verbatim: DebugOnlyRoutes.tableMarker)
                }
                if let lastError {
                    Section {
                        Text(verbatim: lastError)
                    } header: {
                        Text(verbatim: "Cleanup failed; environment unchanged")
                    }
                }
            }
            .navigationTitle(Text(verbatim: "Debug"))
        }
        .accessibilityIdentifier(DebugPanelMarker.identifier)
    }

    private func select(_ environment: AppEnvironment) {
        do {
            try store.switchTo(environment)
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }
}
#endif
