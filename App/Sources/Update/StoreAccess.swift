import Foundation
import Generated
import UIKit

/// 本机的商店能力：安装来源、能否打开某家商店的详情页、打开。
/// `canOpen` 只是能力检查；真正打开失败时由 `open` 的回调告知（rule-gaps G08）。
@MainActor
protocol StoreAccess: AnyObject {
    /// 已按商店对照表归一化的安装来源商店键；读不到或不在表里为 nil。
    var installSource: String? { get }
    func canOpen(_ storeKey: String) -> Bool
    func open(_ storeKey: String, completion: @escaping @MainActor (Bool) -> Void)
}

/// iOS 的商店能力：只查商店对照表（`AppStores`，specs/app-stores.yaml 生成），代码里不写死商店键与打开方式。
///
/// - 安装来源：iOS 只有 App Store，一律按对照表里 platform=ios、channels 含 appstore 的那一行；
///   它的 `key` 目前为 null（needs N-17），所以安装来源读不到（nil）。
/// - 能否打开：对照表里有这把键、`open_method` 与 `target` 都不为 null、`target` 是合法 URL 时，才交给系统判断；
///   值为 null 的商店一律视为「本机打不开」（任务书 §1）。目前对照表全为 null，所以一律打不开、`UIApplication.open` 不会被调用。
///   TODO(N-17): 商店键与打开方式补齐后按 App Store 官方文档核对 open_method 的含义（提审前 09 CAP-X-12 自查）。
@MainActor
final class AppStoreAccess: StoreAccess {
    static let platform = "ios"
    static let channel = "appstore"

    private let table: [AppStoreSpec]
    private let application: () -> UIApplication

    init(table: [AppStoreSpec] = AppStores.forPlatform(AppStoreAccess.platform),
         application: @escaping () -> UIApplication = { UIApplication.shared }) {
        self.table = table
        self.application = application
    }

    var installSource: String? {
        table.first { $0.channels.contains(Self.channel) }?.key
    }

    func canOpen(_ storeKey: String) -> Bool {
        guard let url = detailURL(storeKey) else { return false }
        return application().canOpenURL(url)
    }

    func open(_ storeKey: String, completion: @escaping @MainActor (Bool) -> Void) {
        guard let url = detailURL(storeKey) else {
            completion(false)
            return
        }
        application().open(url, options: [:]) { success in
            completion(success)
        }
    }

    /// 对照表里这家商店详情页的地址；任一项为 null 或不是合法 URL 时为 nil（= 打不开）。
    func detailURL(_ storeKey: String) -> URL? {
        guard let spec = table.first(where: { $0.key == storeKey }),
              spec.openMethod != nil,
              let target = spec.target,
              let url = URL(string: target),
              url.scheme != nil
        else {
            return nil
        }
        return url
    }
}
