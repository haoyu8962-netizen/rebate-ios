import Config
import Foundation

/// 构建配置相关信息。默认环境按编译条件决定：Staging 定义 STAGING（project.yml），
/// Debug 与 Staging 都定义 DEBUG，Release 都不定义。
enum BuildInfo {
    /// Info.plist 的 CouliBuildConfiguration（= $(CONFIGURATION)）。
    static var configurationName: String {
        Bundle.main.object(forInfoDictionaryKey: "CouliBuildConfiguration") as? String ?? "?"
    }

    #if DEBUG
    static var defaultEnvironment: AppEnvironment {
        #if STAGING
        .staging
        #else
        .test
        #endif
    }
    #endif

    @MainActor
    static func makeEnvironmentStore() -> EnvironmentStore {
        #if DEBUG
        EnvironmentStore(defaultEnvironment: defaultEnvironment)
        #else
        EnvironmentStore()
        #endif
    }
}
