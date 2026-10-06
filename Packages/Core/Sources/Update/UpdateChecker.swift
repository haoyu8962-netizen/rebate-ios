import Foundation

/// 一次版本检查的结果。
public enum UpdateCheckOutcome: Sendable, Equatable {
    case success(UpdateCheckResult)
    /// 请求失败、超时、响应解析不了：不拦用户自己的操作（Gate 保持上次已知结论或 unknown）。
    case failure
}

/// 版本检查器（`GET /v1/app-versions/check`）。网络层归 APP-03；本任务只有两种实现：
/// Release 的 `FailingUpdateChecker`（永远失败）与 App 的 Debug / Staging 调试假数据（读契约 openapi 示例）。
/// 完成回调在主线程调用，可以同步调用（测试替身）。
@MainActor
public protocol UpdateChecker: AnyObject {
    func check(completion: @escaping @MainActor (UpdateCheckOutcome) -> Void)
}

/// Release 用的占位检查器：永远返回失败，Release 因此一直按 unknown 处理，不会误拦用户。
/// TODO(APP-03): 网络层接入后换成真正的 `GET /v1/app-versions/check`（带 X-Platform、X-Channel、X-App-Version），
/// 并把 `/v1/config.app_update.recheck_interval_sec` 接到 `UpdateCheckResult.recheckIntervalSec`（rule-gaps G01）。
@MainActor
public final class FailingUpdateChecker: UpdateChecker {
    public init() {}

    public func check(completion: @escaping @MainActor (UpdateCheckOutcome) -> Void) {
        completion(.failure)
    }
}
