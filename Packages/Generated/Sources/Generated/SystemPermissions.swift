// 生成物，禁止手改；来源 contract.lock
// 快照：specs/system-permissions.json 的 permissions（03 §4.9；APP-12 G26 隐私中心「系统权限」一节）

/// 系统权限清单的一项（类型、端、用途文案键）。
public struct SystemPermissionEntry: Sendable, Equatable {
    public let type: Swift.String
    public let platform: Swift.String
    public let purposeKey: Swift.String?
}

/// 锁定契约的系统权限清单（全部端；调用方按本端过滤）。
public enum SystemPermissions {
    public static let entries: [SystemPermissionEntry] = [
        SystemPermissionEntry(type: "photos", platform: "ios", purposeKey: "perm.photos.system_purpose"),
        SystemPermissionEntry(type: "push", platform: "ios", purposeKey: "perm.push.card_hint"),
    ]
}
