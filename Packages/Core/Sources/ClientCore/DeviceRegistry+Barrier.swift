import CouliNetwork
import Foundation
import Privacy

// MARK: - 设备凭据的撤回禁读屏障（APP-08 iOS r3g NEW-05）

/// 锁顺序：全局只有「设备锁（`DeviceRegistry.lock`）→ 网络锁（`ApiClient.lock`）」一个方向。
/// - 设备锁里会读 ApiClient 的作废世代（`invalidationTicket`）、调用组请求的准入判断（`admit`，取网络锁）；
/// - ApiClient 持网络锁时从不调用设备凭据；撤回开始（`invalidateSessions`）先不持网络锁地调 `withdrawalStarted`（只取设备锁），
///   再取网络锁推进作废世代。
/// 因此「网络锁里判断通过 → 撤回开始 → 读设备凭据」的交错不存在：读取在设备锁里先看屏障；撤回要竖屏障必须等读取放开设备锁。
public extension DeviceRegistry {
    /// 组请求用的带准入读取（APP-08 iOS r3g NEW-05）：在设备锁里先看屏障，再调 `admit`（取网络锁，顺序「设备锁 → 网络锁」），
    /// 准入世代能放下屏障（或屏障本来就没竖）才读。撤回开始（屏障竖起）要等这里读完才能拿到设备锁，所以不存在「判断通过、
    /// 撤回已开始、仍去读」的交错。
    func credentials(admittedBy admit: () -> UInt64?) -> (deviceId: String, installSecret: String)? {
        let usable: DeviceIdentity? = lock.withLock {
            guard let admitted = admit(), lowerBarrierLocked(admitted: admitted) else {
                return nil
            }
            return usableLocked()
        }
        return usable.map { ($0.deviceId, $0.installSecret) }
    }

    /// 撤回同意、切换环境开始：竖起设备凭据的撤回禁读屏障（只取设备锁；ApiClient 在推进作废世代之前、不持网络锁时调用）。
    func withdrawalStarted(networkEpoch: UInt64) {
        lock.withLock {
            withdrawalBarrier = max(withdrawalBarrier ?? networkEpoch, networkEpoch)
        }
    }

    /// 实际读出设备凭据的次数（测试与诊断）。
    var identityReads: Int {
        lock.withLock { identityReadCount }
    }

    /// 撤回禁读屏障此刻是否竖着（测试与诊断）。
    var withdrawalBarrierRaised: Bool {
        lock.withLock { withdrawalBarrier != nil }
    }
}

extension DeviceRegistry {
    /// 放行检查（隐私已同意、凭据可读、环境就绪）。撤回禁读屏障竖着时（APP-08 iOS r3g NEW-05），只有在网络作废之后取得、
    /// 期间网络作废世代未变的放行快照才能放下它；放不下按不放行。
    func allowed() async -> Bool {
        let sender = lock.withLock { client }
        let before = sender?.invalidationTicket
        let state = await context()
        guard state.environmentSettled, state.privacy == PrivacyRaw.full, state.credentialsReadable else {
            return false
        }
        // 设备锁里取网络作废世代（顺序「设备锁 → 网络锁」）。
        return lock.withLock {
            guard withdrawalBarrier != nil else {
                return true
            }
            guard let before, client?.invalidationTicket == before else {
                return false
            }
            return lowerBarrierLocked(admitted: before)
        }
    }

    /// 调用方持有 `lock`：屏障没竖，或准入的网络作废世代大于竖起时的世代（作废之后的可读快照）——后者同时放下屏障。
    func lowerBarrierLocked(admitted: UInt64) -> Bool {
        guard let barrier = withdrawalBarrier else {
            return true
        }
        guard admitted > barrier else {
            return false
        }
        withdrawalBarrier = nil
        return true
    }
}
