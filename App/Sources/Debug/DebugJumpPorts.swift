#if DEBUG
import Foundation
import Trade

/// 截图、UI 测试用的外跳假端口（APP-06b；只在 Debug / Staging 编译，共性第 42 条）：包在系统实现 `AppJumpPorts` 外面，按启动参数
/// 给假安装状态（`-CouliFakeInstalled taobao=false`）、不真的拉起外部 App / 浏览器（`-CouliFakeTradeNoExternal`）。由
/// `DebugFakeTrade.ports(wrapping:)` 在假服务打开时创建；Release 不编译本文件，制品扫描查 `marker`、类名、字段名与启动参数。
@MainActor
final class DebugJumpPorts: JumpPorts {
    static let marker = "COULI_DEBUG_JUMP_PORTS_APP06B_IOS_9b3e60"
    static let noExternalArgument = "-CouliFakeTradeNoExternal"
    static let installedDefaultsKey = "CouliFakeInstalled"

    private let system: AppJumpPorts
    /// 制品扫描标记（被实例引用，-O 下保留）。
    let tag = DebugJumpPorts.marker
    /// 假安装状态：返回 nil 的平台按系统实现（恒为 unknown）。
    var debugInstalled: ((String) -> String?)?
    /// 不真的离开 App：scheme / universal_link 按拉起失败，h5 按已交浏览器。
    var debugNoExternal = false

    init(system: AppJumpPorts) {
        self.system = system
    }

    func installed(_ platform: String) -> String {
        debugInstalled?(platform) ?? system.installed(platform)
    }

    func launchApp(type: String, value: String) async -> Bool {
        DebugPurchaseLog.record("jump:\(type)")
        if debugNoExternal {
            guard let url = URL(string: value), url.scheme != nil else { return false }
            // APP-06v-b：商品详情视觉截图（注入卡）时，假「拉起失败」晚 2.5 秒回答，让 open 回答时的轻提示（如复核失败
            // ProductRequoteCached）在截图时刻稳定显示，不被随后口令复制的提示半途替换（只改回答时机，结果不变）。
            if DebugFakeProductCards.isActive {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
            return false
        }
        return await system.launchApp(type: type, value: value)
    }

    func openBrowser(_ value: String) async -> Bool {
        DebugPurchaseLog.record("jump:h5")
        if debugNoExternal {
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return false
            }
            return true
        }
        return await system.openBrowser(value)
    }

    func copy(_ text: String) -> Bool {
        DebugPurchaseLog.record("jump:copy_tpwd")
        return system.copy(text)
    }
}
#endif
