#if DEBUG
import Config

/// 调试能力（03 §3.6）。整个类型只在 Debug / Staging 编译（App target 的 DEBUG），Release 制品里不存在。
///
/// 首页草稿预览 HomePreview 不属于这里（03 §3.6：独立只读能力，连 prod 照常可用，APP-11）；
/// 代理或抓包信任在任何构建里都不允许（03 §4.8 CSB-04），也不在这里。
enum DebugCapability: String, Sendable, CaseIterable {
    case switchServer
    case clockOffset
    case bridgeConformance
    case debugRoutes
    case diagnostics
    case resultInjection
    case mockData
}

struct DebugCapabilities: Sendable, Equatable {
    let environment: AppEnvironment

    /// 当前环境是 prod 时只保留「切换服务器地址」，其余一律关闭（不依赖服务端开关）。
    func isAvailable(_ capability: DebugCapability) -> Bool {
        if environment == .prod {
            return capability == .switchServer
        }
        return true
    }
}
#endif
