import Config
import Foundation

/// 网络层的清理项：撤回同意与切换环境时先作废全部在途请求、它们的重试与重放（`ApiClient.invalidateSessions`），
/// 再由会话清理项清令牌。同一个实例同时登记进撤回同意的清理注册表与切换环境的清理注册表，排在令牌清理项之前。
@MainActor
public final class NetworkInvalidationCleaner: EnvironmentSwitchCleaning {
    public static let name = "Network.invalidateSessions"

    public let cleanerName = NetworkInvalidationCleaner.name
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    public func cleanForEnvironmentSwitch() throws {
        client.invalidateSessions()
    }
}
