import ClientCore
import Photos
import UserNotifications

/// iOS 的系统权限接口（03 §4.9）：本文件是唯一调用系统授权申请接口的地方（swiftlint 规则
/// system_permission_request_only_in_requester），只由 PermissionRequester 经注入调用。
///
/// 状态映射：没决定过 → not_asked；拒绝过 → permanently_denied（iOS 拒绝后系统不会再弹授权框）；
/// 允许（含临时、受限的相册写入）→ granted；家长控制等受限 → unavailable。
/// TODO(N-21): unavailable 的具体映射未规定（rule-gaps 第 7 条）；不认识的状态按 unavailable。
enum PermissionSystem {
    static func status(_ permission: String) async -> String {
        switch permission {
        case "push":
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return pushStatus(settings.authorizationStatus)
        case "photos":
            return photosStatus(PHPhotoLibrary.authorizationStatus(for: .addOnly))
        default:
            return PermissionStatusRaw.unavailable
        }
    }

    static func request(_ permission: String) async -> String {
        switch permission {
        case "push":
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            return await status(permission)
        case "photos":
            return await photosStatus(PHPhotoLibrary.requestAuthorization(for: .addOnly))
        default:
            return PermissionStatusRaw.unavailable
        }
    }

    static func pushStatus(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: PermissionStatusRaw.notAsked
        case .denied: PermissionStatusRaw.permanentlyDenied
        case .authorized, .provisional, .ephemeral: PermissionStatusRaw.granted
        @unknown default: PermissionStatusRaw.unavailable
        }
    }

    static func photosStatus(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: PermissionStatusRaw.notAsked
        case .denied: PermissionStatusRaw.permanentlyDenied
        case .authorized, .limited: PermissionStatusRaw.granted
        case .restricted: PermissionStatusRaw.unavailable
        @unknown default: PermissionStatusRaw.unavailable
        }
    }
}
