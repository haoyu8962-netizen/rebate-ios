#if DEBUG
import Foundation
import Push

/// 推送令牌的 Debug 假来源（APP-12 G17；只在 Debug / Staging 编译，Release 用 NoPushTokenSource）。启动参数 `-CouliFakePushToken <后缀>` 打开时，
/// 隐私同意后的推送初始化步骤（`start`）之后给一个明显的测试令牌 `debug-push-token-<后缀>`；`change(to:)` 模拟令牌变化（集成测试与调试用）。
/// 令牌值只交给上报管线，不进日志、埋点、诊断信息与界面。Release 制品扫描查类型名、启动参数与令牌前缀。
@MainActor
final class DebugPushTokenSource: PushTokenSource {
    static let launchArgument = "CouliFakePushToken"
    static let prefix = "debug-push-token-"

    private var started = false
    private var token: String?
    private let initial: String?
    private var listeners: [Int: @MainActor () -> Void] = [:]
    private var next = 0

    init(initial: String?) {
        self.initial = initial
    }

    /// 启动参数里的假令牌（没有为 nil：不给令牌，与 Release 一样不上报）。
    static func fromLaunchArguments(defaults: UserDefaults = .standard) -> DebugPushTokenSource? {
        guard let suffix = defaults.string(forKey: launchArgument), !suffix.isEmpty else { return nil }
        return DebugPushTokenSource(initial: prefix + suffix)
    }

    func start() {
        guard !started else { return }
        started = true
        if token == nil, let initial {
            token = initial
            notify()
        }
    }

    func stop() {
        started = false
        token = nil
    }

    func current() -> String? {
        started ? token : nil
    }

    func subscribe(_ listener: @escaping @MainActor () -> Void) -> () -> Void {
        next += 1
        let id = next
        listeners[id] = listener
        return { [weak self] in
            MainActor.assumeIsolated { self?.listeners[id] = nil }
        }
    }

    /// 模拟 SDK 通知令牌值变了。
    func change(to suffix: String) {
        token = Self.prefix + suffix
        if started {
            notify()
        }
    }

    private func notify() {
        for listener in listeners.values {
            listener()
        }
    }
}
#endif
