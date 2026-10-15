import Foundation
import UIKit
import WebKit

/// 「我的」类页面要的系统能力（App 给；生产 `IOSMeSystem`，测试替身）。都在主线程调用。
@MainActor
protocol MeSystemPorts: AnyObject {
    /// 系统权限的只读状态（不申请、不改节流）：granted / permanently_denied / not_asked / unavailable。
    func permissionStatus(_ type: String) async -> String
    /// PermissionRequester 记下的最近被拒时刻。
    func permissionDeniedAt(_ type: String) -> Int64?
    func openNotificationSettings()
    func openAppSettings()
    /// 经系统打开外部链接（不在 App 内 WebView 加载）；拉不起为 false。
    func openExternal(_ url: String) async -> Bool
    /// 微信是否已装：yes / no / unknown。
    func wechatInstalled() -> String
    /// 图片与网页缓存的大小（字节）；读不出为 nil。
    func cacheBytes() async -> Int64?
    /// 只清图片与网页缓存（AC-S1-137）；返回清理动作是否都完成且没有 I/O 错误（不按清后的占用判定，大小由调用方重算后照实显示）。
    func clearCache() async -> Bool
    func osVersion() -> String?
    func model() -> String?
}

/// iOS 的系统能力（APP-12）。
/// - 权限状态经 PermissionRequester 同一套映射（`AppPermissions.status`，只查不申请）；
/// - 通知设置：`UIApplication.openNotificationSettingsURLString`（iOS 16+，系统里本 App 的通知设置页）；
/// - 微信已装检测：只查生成物登记的查询项。生成的 Info.plist 没有 LSApplicationQueriesSchemes（apps.json 没有微信条目），一律 unknown
///   （走 CsHandoff，拉不起再 CsOpenFailed），不调 canOpenURL、不读应用列表、不手写清单。TODO(N-33)：生成物补查询项后按 canOpenURL 判断；
/// - 清除缓存：只清 URLCache（系统图片加载 AsyncImage 走 URLSession.shared）与 WKWebsiteDataStore 的磁盘 / 内存 / fetch / 离线缓存；
///   不清 Cookie、Web Storage、钥匙串（会话、设备注册）、Application Support（配置 LKG、订单 / 钱包缓存）、UserDefaults（pending_action、本机偏好）。
///   成功口径（R3-01 裁定）：清理动作都完成且没有抛错即成功；系统缓存的磁盘占用不保证同步缩小，不拿清后的占用当成功条件。
@MainActor
final class IOSMeSystem: MeSystemPorts {
    private weak var permissions: AppPermissions?
    /// 图片缓存（AsyncImage 走 URLSession.shared → URLCache.shared）；测试可换成替身。
    private let urlCache: URLCache
    /// 清 WKWebsiteDataStore 的网页缓存；测试可换成替身。
    private let removeWebData: @MainActor () async -> Void
    static let webCacheTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
    ]

    init(permissions: AppPermissions?, urlCache: URLCache = .shared,
         removeWebData: @escaping @MainActor () async -> Void = IOSMeSystem.removeWebKitCaches) {
        self.permissions = permissions
        self.urlCache = urlCache
        self.removeWebData = removeWebData
    }

    static func removeWebKitCaches() async {
        await WKWebsiteDataStore.default().removeData(ofTypes: webCacheTypes, modifiedSince: .distantPast)
    }

    func permissionStatus(_ type: String) async -> String {
        guard let permissions else { return await PermissionSystem.status(type) }
        return await permissions.status(type)
    }

    func permissionDeniedAt(_ type: String) -> Int64? {
        permissions?.deniedAt(type)
    }

    func openNotificationSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    func openExternal(_ url: String) async -> Bool {
        guard let target = URL(string: url) else { return false }
        return await UIApplication.shared.open(target)
    }

    func wechatInstalled() -> String {
        "unknown"
    }

    /// WebKit 的网络缓存目录（Library/Caches/WebKit 与 Library/Caches/<bundle>/WebKit）。
    private static var webKitDirectories: [URL] {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return [] }
        var dirs = [caches.appendingPathComponent("WebKit", isDirectory: true)]
        if let bundle = Bundle.main.bundleIdentifier {
            dirs.append(caches.appendingPathComponent(bundle, isDirectory: true).appendingPathComponent("WebKit"))
        }
        return dirs
    }

    nonisolated static func directorySize(_ url: URL) -> Int64? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        }
        guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func cacheBytes() async -> Int64? {
        let dirs = Self.webKitDirectories
        let web = await Task.detached { dirs.compactMap(Self.directorySize).reduce(0, +) }.value
        return Int64(urlCache.currentDiskUsage) + web
    }

    /// 清理动作完成即成功：两步都是系统接口，不抛错、没有 I/O 错误回报；App 没有自己管理的图片 / 临时文件缓存目录（图片只在 URLCache，
    /// NSTemporaryDirectory 只是 Application Support 不可用时的数据兜底，不是缓存，不清）。清后的大小由设置页重算、照实显示（可能不为 0）。
    func clearCache() async -> Bool {
        urlCache.removeAllCachedResponses()
        await removeWebData()
        return true
    }

    func osVersion() -> String? {
        UIDevice.current.systemVersion
    }

    /// 机型标识（如 iPhone17,1；模拟器取 SIMULATOR_MODEL_IDENTIFIER）。
    func model() -> String? {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw in
            String(bytes: Array(raw.prefix { $0 != 0 }), encoding: .utf8) ?? ""
        }
        return identifier.isEmpty ? nil : identifier
    }
}
