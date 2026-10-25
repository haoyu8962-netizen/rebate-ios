#if DEBUG
import DesignSystem
import Foundation
import SwiftUI

/// 商品详情视觉 UI 测试的只读记录（APP-06v-b 评审 r1 S1-2 / S2-8；只在 Debug / Staging 编译，且只在注入卡
/// `COULI_FAKE_PRODUCT_CARDS` 生效时记录与显示）：
/// - `open:<link_id>:no_rebate=<0|1>`：假服务每收到一次 open 记一条（请求体 `no_rebate` 是否为 true）；
/// - `announce:<文字>`：每次状态变化的礼貌播报（`CouliStatusAnnouncer.polite`，如下架「商品已下架」）记一条；
/// - `route:<路由名>`：购买执行器经 `env.open` 打开的每个路由（AppTrade.open，如 Help / Search / Login）；
/// - `jump:<步骤类型>`：DebugJumpPorts 实际执行的每次外跳端口调用（scheme / universal_link / h5 / copy_tpwd；不真的离开 App）。
/// UI 测试读根视图左上角 1×1 的只读元素 `debug.purchase.log`：accessibilityValue = 全部记录按发生顺序以「 | 」连接。
/// 不影响任何回答内容与界面；Release 不编译本文件，制品扫描查类型名与标识。
@MainActor
final class DebugPurchaseLog: ObservableObject {
    static let shared = DebugPurchaseLog()
    static let identifier = "debug.purchase.log"

    @Published private(set) var entries: [String] = []

    /// 任意线程调用（假服务在网络线程回答）；在主线程追加。
    nonisolated static func record(_ entry: String) {
        guard DebugFakeProductCards.isActive else { return }
        Task { @MainActor in
            shared.entries.append(entry)
        }
    }

    /// 注入卡生效时接上播报观察（App 启动时调用一次）。
    static func install() {
        guard DebugFakeProductCards.isActive else { return }
        CouliStatusAnnouncer.observer = { text in
            DebugPurchaseLog.record("announce:\(text)")
        }
    }

    var value: String {
        entries.joined(separator: " | ")
    }
}

/// `debug.purchase.log` 只读元素（1×1、透明，不挡点击）。
struct DebugPurchaseLogReadout: View {
    @ObservedObject var log = DebugPurchaseLog.shared

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: DebugPurchaseLog.identifier))
            .accessibilityValue(Text(verbatim: log.value))
            .accessibilityIdentifier(DebugPurchaseLog.identifier)
    }
}
#endif
