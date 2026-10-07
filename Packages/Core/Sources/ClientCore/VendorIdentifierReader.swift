import UIKit

/// iOS 的设备标识：identifierForVendor（BR-ID-09）。重启后首次解锁前可能取不到（返回 nil），由退避重试重新读取。
/// 只由 `DeviceRegistry` 在确认已同意隐私政策后、在与清理共用的同步区里调用（BR-ID-11：同意前禁止读取 IDFV）。
/// 不读 IDFA、不调 ATT。
public struct VendorIdentifierReader: DeviceIdentifierReading {
    public init() {}

    @MainActor
    public func readIdentifier() -> String? {
        UIDevice.current.identifierForVendor?.uuidString
    }
}
