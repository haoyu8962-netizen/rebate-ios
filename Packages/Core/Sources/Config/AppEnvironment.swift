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

    // MARK: 本机隐私决定（APP-02b，BR-ID-11、BR-ID-12、BR-ID-13）

    /// 本机隐私决定的唯一记录（字典：decision、consented_version、consented_at_ms、basic_mode、
    /// withdrawal_cleanup_pending）。几项合在一个值里，每次改写都是对这一个键的一次写入：
    /// 撤回同意时「基本模式 + 清除同意记录 + 待清理标记」同时落盘，进程在任何时刻中断都不会只写了一半
    /// （APP-02b 第 2 轮评审，三端统一）。待清理标记存在期间不得读取任何会话凭据，下次启动重试清理，清干净才删除。
    public static let privacyRecordKey = userDefaultsPrefix + "privacy.record"

    /// 「本机隐私决定」键：用户对本机安装包里的协议做的选择，与服务器环境无关。
    ///
    /// 切换环境时保留（03 §3.6「切换环境」要清的是会话、令牌、device_id 与 install_secret、LKG、页面缓存、
    /// pending_action，不含隐私决定；清掉会让已同意的用户在测试包里重新走首启弹窗，已进基本模式的用户
    /// 被当成未决，都不是用户的意思）。新环境里重新注册设备后，按保存的版本与点击时间补报同意记录（BR-ID-12）。
    ///
    /// 撤回同意（BR-ID-13）走的是另一条路：清令牌、device_id、install_secret（撤回清理器注册表），
    /// 并把这条记录改写为基本模式——记录不在撤回清理里删除，否则撤回后下次冷启动会变回「未决」再弹首启弹窗。
    /// 「撤回清理未完成」标记同样保留：切换环境不能把它清掉而让未清干净的凭据重新可读。
    public static let privacyDecisionKeys: Set<String> = [privacyRecordKey]

    // MARK: 强更检查（APP-02c）

    /// 强更检查的本机记录（最近一次成功检查、成功时刻、「暂不更新」记下的版本、10405 带来的最低版本）。
    /// 切换环境时随命名空间一起清掉（版本配置按环境不同）。
    public static let updateRecordKey = userDefaultsPrefix + "update.record"

    /// 切换环境时不删的全部键：环境记录 + 本机隐私决定。
    public static let preservedOnEnvironmentSwitchKeys: Set<String> = environmentRecordKeys.union(privacyDecisionKeys)
}
