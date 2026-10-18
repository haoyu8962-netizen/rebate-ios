import SwiftUI

/// 场景切换的生产顺序；购买页先回前台，订单随后确认身份并补取。
@MainActor
enum AppScenePhases {
    struct Targets {
        var routing: AppRouting?
        var config: AppConfig?
        var search: AppSearch?
        var clipboard: AppClipboard?
        var orders: AppOrders?
        var wallet: AppWallet?
        var me: AppMe?
        var login: AppLogin?
        var home: AppHome?
    }

    static func apply(_ phase: ScenePhase, _ targets: Targets) {
        switch phase {
        case .background:
            targets.routing?.sceneEnteredBackground()
            targets.config?.enteredBackground()
            let searchCommitted = targets.search?.restoration.sceneEnteredBackground()
            targets.search?.trade?.sceneChanged(active: false)
            targets.clipboard?.sceneBackground()
            targets.orders?.sceneEnteredBackground()
            #if DEBUG
            // 进后台的同步保存都执行完、搜索恢复内容与后台标记已提交并核对（UI 测试的显式完成信号，FU-IOS-0712 R1-05）；
            // 提交失败或没完成不发
            DebugUITestSignals.backgroundSaveFinished(committed: searchCommitted ?? false)
            #else
            _ = searchCommitted
            #endif
        case .active:
            targets.routing?.sceneBecameActive()
            targets.config?.enteredForeground()
            targets.search?.restoration.sceneBecameActive()
            targets.search?.trade?.sceneChanged(active: true)
            // 剪贴板：冷启动第一次与进过后台之后的那一次才判定（下拉通知等 inactive → active 不算，共性第 1 条）
            targets.clipboard?.sceneActive()
            targets.orders?.sceneBecameActive()
        case .inactive:
            targets.orders?.sceneActive = false
            // 系统弹窗、切换 App 的过渡：同样作废续执行许可（03 §4.5「进入后台不外跳」，保守）
            targets.search?.trade?.sceneChanged(active: false)
        @unknown default: break
        }
        // 钱包：active 之外（inactive、background）都立即作废等待中的导航与浮层许可（APP-09 iOS R2-03）
        targets.wallet?.scenePhaseChanged(phase)
        // 「我的」：同样作废导航许可（10006 票据），回前台按新的一次进入取 Me（G36）
        targets.me?.scenePhaseChanged(phase)
        // 绑手机页：active 之外都作废导航与弹窗许可（APP-05b，APP-09 共性第 77 条）
        targets.login?.scenePhaseChanged(active: phase == .active)
        targets.home?.sceneChanged(active: phase == .active)
    }
}
