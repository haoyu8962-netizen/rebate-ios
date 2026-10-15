import Config
import DesignSystem
import Foundation
import Privacy
import Router
import SwiftUI
import Wallet
import WalletCore

/// 钱包本机数据的清理项（G22、APP-03b 撤回清理名单）：撤回同意与切换环境时删除钱包摘要缓存与提现金额草稿；删不掉抛错（撤回清理不算完成，
/// 待清理状态保留在缓存目录之外，读、写之前先完成清理）。无论落盘删除成功与否，都同步通知 AppWallet 作废内存里的钱包显示与执行器。
/// 金额隐藏是设备级界面偏好（与订单页同一份，不随账号、不随环境，G24），不在此列。登出、换账号、会话失效由 AppWallet 按归属清理。
@MainActor
final class WalletCacheCleaner: EnvironmentSwitchCleaning {
    static let name = "Wallet.cache"
    let cleanerName = WalletCacheCleaner.name
    let store: WalletCacheStore
    var onCleared: (@MainActor () -> Void)?

    init(store: WalletCacheStore) {
        self.store = store
    }

    func cleanForEnvironmentSwitch() throws {
        defer { onCleared?() }
        try store.clearAll()
    }

    static let shared = WalletCacheCleaner(store: WalletCacheStore(root: WalletCacheStore.defaultRoot()))

    /// 登记进撤回同意与切换环境两个注册表（已登记过就不重复）。在启动对账之前调用。
    static func register(
        _ cleaner: WalletCacheCleaner = shared,
        withdrawal: EnvironmentSwitchCleanerRegistry = PrivacyWithdrawalCleanup.registry,
        environmentSwitch: EnvironmentSwitchCleanerRegistry = .shared
    ) {
        for registry in [withdrawal, environmentSwitch] where !registry.registeredNames.contains(name) {
            registry.register(cleaner)
        }
    }
}

/// 钱包类路由（Wallet、Withdraw、WithdrawRecords、PayoutAccount、RealName、LaborAgreement）的页面。一个导航实例只建一次执行器（AppWallet
/// 按 RouteDestination.id 缓存，出栈时作废）。
struct WalletRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var wallet: AppWallet

    var body: some View {
        Group {
            if let entry = wallet.entry(for: destination) {
                entry.screen()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }
}
