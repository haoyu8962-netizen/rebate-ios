import Config

// 各环境与地址集中在本文件。正式域名未给定，prod / local / test 用 .invalid 占位（needs.md N-05）；staging 用真实主机
// （FU-X-STAGING-HOSTS，主机名只写在下面 #if DEBUG 里），stream 只给 staging（D10-598 ①，/v1/agent/* 走它）。
// Release 只编译进 prod：非 prod 环境与地址只能写在 #if DEBUG 里（Release 制品扫描会查）。
// 放在 App target 而不是 Core 包：Staging 下包看不到 DEBUG，App target 看得到（见 project.yml）。
extension AppEnvironment {
    static let prod = AppEnvironment(
        id: "prod",
        endpoints: EnvironmentEndpoints(api: "https://api.prod.couli.invalid", h5: "https://h5.prod.couli.invalid")
    )

    #if DEBUG
    static let local = AppEnvironment(
        id: "local",
        endpoints: EnvironmentEndpoints(api: "https://api.local.couli.invalid", h5: "https://h5.local.couli.invalid")
    )
    static let test = AppEnvironment(
        id: "test",
        endpoints: EnvironmentEndpoints(api: "https://api.test.couli.invalid", h5: "https://h5.test.couli.invalid")
    )
    static let staging = AppEnvironment(
        id: "staging",
        endpoints: EnvironmentEndpoints(
            api: "https://api-stg.couliapp.cn",
            h5: "https://h5-stg.couliapp.cn",
            stream: "https://stream-stg.couliapp.cn"
        )
    )

    /// 调试面板可选的全部环境（只在 Debug / Staging 编译）。
    static let selectable: [AppEnvironment] = [.local, .test, .staging, .prod]
    #endif
}
