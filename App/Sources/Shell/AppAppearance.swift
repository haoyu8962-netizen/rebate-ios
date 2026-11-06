import SwiftUI
import UIKit

/// App 外观（APP-11v S2-4：深色运行时接线）。
///
/// 现状：`Info.plist` 的 `UIUserInterfaceStyle=Light` 把整 App 锁成浅色；解锁、整 App 跟随系统深色归 DSX-127（D10-671：先做全部页面
/// 深色快照与对比度扫描，最后合）。在那之前不改 Info.plist，只把「跟随系统外观」这条运行时路径接好：
/// `followsSystem` 为真时，把所在窗口的外观覆盖改为系统当前外观并随系统切换，页面按 `CouliColor` 的深色取值（生成物
/// `DesignTokens.colorsDark`）呈现。DSX-127 解锁时：删掉 Info.plist 的锁并把 `followsSystem` 改为恒真（或接到设置项），无需再改页面。
enum AppAppearance {
    /// 是否跟随系统外观。Release 恒为假（等 DSX-127 解锁）；Debug / Staging 可用启动参数 `-CouliFollowSystemAppearance YES`
    /// 打开，在不经 UI 测试场景、不强制覆盖外观的正常启动中验证系统深色下的首页。
    static var followsSystem: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "CouliFollowSystemAppearance")
        #else
        false
        #endif
    }

    /// 系统当前外观。模拟器上先读设备的外观设置（见 `simulatorStyle`），读不到再取屏幕特征。
    @MainActor
    static func systemStyle(_ window: UIWindow) -> UIUserInterfaceStyle {
        #if DEBUG && targetEnvironment(simulator)
        if let style = simulatorStyle() {
            return style
        }
        #endif
        return (window.windowScene?.screen ?? UIScreen.main).traitCollection.userInterfaceStyle
    }

    #if DEBUG && targetEnvironment(simulator)
    /// 模拟器设备的外观设置（`xcrun simctl ui <udid> appearance dark` / XCUIDevice.appearance 写入；2 = 深色）。
    /// APP-06v-b 实测：iOS 26 模拟器上 Info.plist 的浅色锁连屏幕特征也锁成浅色，屏幕特征读不到系统深色，「跟随系统外观」
    /// 开关形同虚设；只在 Debug / Staging 的模拟器上用这份设置补上，真机与 Release 不走这里。
    static func simulatorStyle() -> UIUserInterfaceStyle? {
        // 先经偏好服务读（刚切换外观时设置文件可能还没落盘，文件读到的是旧值），读不到再读文件。
        let domain = "com.apple.uikitservices.userInterfaceStyleMode"
        if let mode = UserDefaults(suiteName: domain)?.object(forKey: "UserInterfaceStyleMode") as? Int {
            return mode == 2 ? .dark : .light
        }
        let env = ProcessInfo.processInfo.environment
        let root: URL
        if let shared = env["SIMULATOR_SHARED_RESOURCES_DIRECTORY"] {
            root = URL(fileURLWithPath: shared)
        } else if let home = env["SIMULATOR_HOST_HOME"], let udid = env["SIMULATOR_UDID"] {
            root = URL(fileURLWithPath: home)
                .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/data")
        } else {
            return nil
        }
        let file = root.appendingPathComponent(
            "Library/Preferences/\(domain).plist"
        )
        guard let values = NSDictionary(contentsOf: file), let mode = values["UserInterfaceStyleMode"] as? Int else {
            return nil
        }
        return mode == 2 ? .dark : .light
    }
    #endif
}

/// 把「跟随系统外观」落到所在窗口（放在根视图背景里）。不跟随时什么都不改，保持 Info.plist 的浅色锁定。
struct AppAppearanceHook: UIViewRepresentable {
    func makeUIView(context _: Context) -> UIView {
        Probe()
    }

    func updateUIView(_: UIView, context _: Context) {}

    private final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private var observing = false

        @objc private func becameActive() {
            apply()
        }

        private func apply() {
            guard AppAppearance.followsSystem, let window else { return }
            let style = AppAppearance.systemStyle(window)
            if window.overrideUserInterfaceStyle != style {
                window.overrideUserInterfaceStyle = style
            }
            if !observing {
                // 系统外观切换后回到前台时重新取一次（选择器式观察者随对象释放自动移除）
                observing = true
                NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                                       name: UIApplication.didBecomeActiveNotification, object: nil)
            }
        }
    }
}
