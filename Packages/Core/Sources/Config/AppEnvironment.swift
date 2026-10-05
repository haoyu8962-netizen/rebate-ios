/// 服务器环境（03 §3.6）：一个环境 = 标识 + 服务基址。
///
/// 本模块只定义类型，不含任何具体环境、地址与切换逻辑。原因：Xcode 对自定义配置名（Staging）
/// 按本地包自己的 Release 配置编译包，包里看不到 DEBUG（实测 Xcode 27，见 project.yml 注释），
/// 所以「只在 Debug / Staging 存在」的东西不能写在包里，统一放在 App target 的调试源码集
/// （App/Sources/Debug，App target 在 Debug、Staging 都定义 DEBUG）。
/// 具体环境与地址集中在 App/Sources/Environment/AppEnvironment+Endpoints.swift。
public struct AppEnvironment: Hashable, Sendable, Identifiable {
    /// 环境标识（local / test / staging / prod），持久化用。
    public let id: String
    public let endpoints: EnvironmentEndpoints

    public init(id: String, endpoints: EnvironmentEndpoints) {
        self.id = id
        self.endpoints = endpoints
    }
}

/// 本 App 在 UserDefaults 与 Keychain 里的命名空间；切换环境时按它清理。
public enum AppNamespace {
    public static let userDefaultsPrefix = "com.couli.app."
    public static let keychainService = "com.couli.app"

    /// 手动选择的环境（只有 Debug / Staging 的调试面板会写）。
    public static let environmentSelectionKey = userDefaultsPrefix + "environment.selection"
    /// 上次清理完成、已生效的环境（每个构建在启动时核对，见 `EnvironmentApplier`）。
    public static let appliedEnvironmentKey = userDefaultsPrefix + "environment.applied"

    /// 环境记录键：命名空间清理器不删，清理期间也会先保存、清理后恢复。
    public static let environmentRecordKeys: Set<String> = [environmentSelectionKey, appliedEnvironmentKey]
}
