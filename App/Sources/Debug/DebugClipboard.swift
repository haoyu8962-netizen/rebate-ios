#if DEBUG
import Clipboard
import Foundation

/// 剪贴板识别的调试能力（APP-07；只在 Debug / Staging 编译，Release 制品扫描查 `marker`）：
/// - `-CouliClipboardDiagnostics`：根视图角落放一个读屏可读的计数（探测、parse 请求、App 写系统剪贴板的次数），UI 测试据此断言
///   「点击前 0 次请求、点击后 1 次」「写入次数为 0」；不含任何剪贴板内容。
enum DebugClipboard {
    static let marker = "COULI_DEBUG_CLIPBOARD_APP07_IOS_4e1b9a"

    static var diagnostics: Bool {
        ProcessInfo.processInfo.arguments.contains("-CouliClipboardDiagnostics")
    }
}

extension AppClipboard {
    /// 计数（不含内容）：detect=<探测次数> parse=<parse 请求次数> writes=<App 写系统剪贴板次数>。
    var debugDiagnostics: String {
        _ = DebugClipboard.marker
        let writes = (systemClipboard as? UIKitSystemClipboard)?.writeCount ?? 0
        return "detect=\(detectCount) parse=\(parseCount) writes=\(writes)"
    }
}
#endif
