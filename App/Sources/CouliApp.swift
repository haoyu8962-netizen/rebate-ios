import Config
import SwiftUI

// TODO(APP-02): AppShell（启动、隐私闸门、Tab、Router、深链、强更）。本任务只有最小可运行入口。
@main
struct CouliApp: App {
    @StateObject private var environment = BuildInfo.makeEnvironmentStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
        }
    }
}
