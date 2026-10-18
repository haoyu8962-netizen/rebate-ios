#if DEBUG
import Foundation
import HomeCore

/// 首页 UI 测试专用设施（APP-11 测试第 5 版，只在 Debug / Staging 编译，Release 制品扫描查类型名与启动参数）：
/// - `-CouliHomeTestReset 1`：首页端口创建之前（AppHome 读本机数据之前）清掉首页 LKG 与首页偏好（公告关闭、弹窗次数），
///   清完发 Darwin 通知 `homeReset`。每个 UI 用例都从「没有缓存、没有关闭记录」开始，不受上一个用例或手动操作影响。
/// - 本机假服务每回答一次首页页面，发 `homePage.<名字>`（名字即 `-CouliFakeHome` 的值，缺省 main），UI 测试据此确认屏幕上
///   的是哪一页（重置后没有 LKG，首屏就是这次回答的页面），不靠可被关闭的公告认页。
/// 通知不带任何数据。
@MainActor
enum DebugHomeUITestSupport {
    static let resetArgument = "-CouliHomeTestReset"
    static let homeReset = "com.couli.app.debug.uitest.home-reset"
    static let homePagePrefix = "com.couli.app.debug.uitest.home-page."

    /// 启动参数带 `resetArgument` 时清空首页本机数据并发信号；清理失败不发（UI 测试等不到信号就在上限内失败）。
    static func resetIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments, storage: HomeStorage = .shared
    ) {
        guard arguments.contains(resetArgument) else { return }
        // 同一进程内改配置开关（第 6 版 T-07）：先登记，再发「已清」——测试收到清完信号后发的开关通知一定接得住
        DebugFakeFlags.listen()
        do {
            try storage.lkg.clearAll()
            try storage.prefs.clearAll()
        } catch {
            return
        }
        post(homeReset)
    }

    /// 本机假服务回答了某一页。
    static func pageServed(_ name: String) {
        post(homePagePrefix + name)
    }

    private static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true
        )
    }
}

/// `-CouliFakeFlags ui.grayscale=true`（多个用逗号隔开）：本机假服务的配置里改功能开关（首页置灰 UI 测试用；值按 true / false
/// 解析，其余开关按包内配置）。
/// 第 6 版（T-07）：同一进程内改开关——UI 测试发 Darwin 通知 `flagPrefix + "ui.grayscale=true"`（或 `=false`），之后假服务回答的
/// 配置按新值（覆盖启动参数）；App 回前台按生产路径重新拉配置即可看到变化。假服务每回答一次配置发 `configServed`。只在带
/// `-CouliHomeTestReset` 启动时登记（见 `DebugHomeUITestSupport.resetIfRequested`）。
enum DebugFakeFlags {
    static let flagPrefix = "com.couli.app.debug.uitest.fake-flag."
    static let configServed = "com.couli.app.debug.uitest.config-served"
    /// 能在运行中改的开关（Darwin 通知不带数据，名字里写死取值）。
    static let runtimeFlags = ["ui.grayscale"]

    private static let lock = NSLock()
    private nonisolated(unsafe) static var overrides: [String: Bool] = [:]
    private nonisolated(unsafe) static var listening = false

    static func apply(to features: inout [String: Any], defaults: UserDefaults = .standard) {
        var flags = features["flags"] as? [String: Any] ?? [:]
        if let raw = defaults.string(forKey: "CouliFakeFlags") {
            for pair in raw.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    flags[parts[0]] = parts[1] == "true"
                }
            }
        }
        for (key, value) in lock.withLock({ overrides }) {
            flags[key] = value
        }
        features["flags"] = flags
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(configServed as CFString), nil, nil, true
        )
    }

    /// 登记运行中改开关的 Darwin 通知（只登记一次）。
    static func listen() {
        let first = lock.withLock {
            defer { listening = true }
            return !listening
        }
        guard first else { return }
        for key in runtimeFlags {
            for value in ["true", "false"] {
                CFNotificationCenterAddObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(), nil,
                    { _, _, name, _, _ in
                        guard let raw = name?.rawValue as String? else { return }
                        DebugFakeFlags.received(String(raw.dropFirst(DebugFakeFlags.flagPrefix.count)))
                    },
                    (flagPrefix + key + "=" + value) as CFString, nil, .deliverImmediately
                )
            }
        }
    }

    private static func received(_ pair: String) {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        lock.withLock { overrides[parts[0]] = parts[1] == "true" }
    }
}
#endif
