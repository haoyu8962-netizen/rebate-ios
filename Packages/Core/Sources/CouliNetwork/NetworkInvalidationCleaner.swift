import Config
import Foundation

/// 网络层的清理项：撤回同意与切换环境时先作废全部在途请求、它们的重试与重放（`ApiClient.invalidateSessions`），
/// 再由会话清理项清令牌。同一个实例同时登记进撤回同意的清理注册表与切换环境的清理注册表，排在令牌清理项之前。
@MainActor
public final class NetworkInvalidationCleaner: WithdrawalReadBarrierRaising, EnvironmentSwitchClosing {
    public static let name = "Network.invalidateSessions"

    public let cleanerName = NetworkInvalidationCleaner.name
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// 撤回清理入口在发布待清理标记之前调用（APP-08 iOS r3h NEW-05）：同步竖起网络禁读屏障、推进作废世代、竖起设备屏障。
    public func raiseWithdrawalReadBarriers() {
        client.raiseWithdrawalReadBarriers()
    }

    /// 切换环境入口在发布 switching、读取保留项之前调用（FU-IOS-0711）：设备屏障 → 推进作废世代并竖网络屏障、取消在途传输
    /// （与 `sendOnce` 最终准入同一把传输锁）。与清理器第一步相同，可重复。
    public func closeForEnvironmentSwitch() {
        client.invalidateSessions()
    }

    public func cleanForEnvironmentSwitch() throws {
        client.invalidateSessions()
    }
}
