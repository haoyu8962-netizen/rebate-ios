#if DEBUG
import Config
import Foundation
import Privacy

/// 截图与 UI 测试用的启动参数（只在 Debug / Staging 编译）：
/// - `-CouliPrivacyPreset reset|consented|basic`：在隐私闸门读取之前改写本机隐私决定（模拟全新安装 / 已同意 / 基本模式）；
/// - `-CouliHideDebugInfo 1`：首页占位下不显示调试信息（与设计稿比对截图用）。
enum DebugPrivacyPreset {
    static func applyFromLaunchArguments(defaults: UserDefaults = .standard) {
        guard let preset = defaults.string(forKey: "CouliPrivacyPreset") else { return }
        for key in AppNamespace.privacyDecisionKeys {
            defaults.removeObject(forKey: key)
        }
        let store = UserDefaultsPrivacyStore(defaults: defaults)
        switch preset {
        case "consented":
            store.commitConsent(version: BundledLegal.privacyPolicyVersion, atMillis: 0)
        case "basic":
            store.commitBasicMode()
        default:
            break
        }
    }

    static var hidesDebugInfo: Bool {
        UserDefaults.standard.bool(forKey: "CouliHideDebugInfo")
    }
}
#endif
