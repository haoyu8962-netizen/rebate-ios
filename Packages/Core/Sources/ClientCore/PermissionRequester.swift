import Foundation

/// 权限申请的统一结果（03 §4.9）。
public enum PermissionResultRaw {
    public static let granted = "granted"
    public static let denied = "denied"
    public static let permanentlyDenied = "permanently_denied"
    public static let throttled = "throttled"
    public static let unavailable = "unavailable"
}

/// 系统权限状态（`status` 注入接口的取值）。
public enum PermissionStatusRaw {
    /// 还没申请过（系统会弹授权框）。
    public static let notAsked = "not_asked"
    public static let granted = "granted"
    /// 拒绝过，系统仍可再弹。
    public static let denied = "denied"
    /// 拒绝且系统不会再弹（iOS 拒绝过即是这种）。
    public static let permanentlyDenied = "permanently_denied"
    /// 本机不能申请（家长控制等受限）。
    public static let unavailable = "unavailable"
}

/// 权限类型 → 文案键（BR-TEXT-14 表 D；03 §4.9 按类型映射，组件不拼键名）。
public struct PermissionTextKeys: Sendable, Equatable {
    /// 用途说明。
    public let purpose: String
    /// 永久拒绝（以及节流期内）引导去设置时的提示。
    public let deniedForever: String

    public static let continueButton = "perm.btn.continue"
    public static let goSettings = "perm.go_settings"

    /// MVP 的两类权限（system-permissions.yaml：push、photos）。相机留到 P1，不登记。
    public static let table: [String: PermissionTextKeys] = [
        "push": PermissionTextKeys(purpose: "perm.push.card_hint", deniedForever: "perm.push.denied_forever"),
        "photos": PermissionTextKeys(purpose: "perm.photos.purpose", deniedForever: "perm.photos.denied_forever"),
    ]
}

/// 一次申请的结果。
public struct PermissionResult: Sendable, Equatable {
    public let permission: String
    /// `PermissionResultRaw`。
    public let resultRaw: String

    public init(permission: String, resultRaw: String) {
        self.permission = permission
        self.resultRaw = resultRaw
    }

    public var granted: Bool {
        resultRaw == PermissionResultRaw.granted
    }
}

/// 系统权限申请的唯一入口（03 §4.9；BR-ID-13）：原生入口与以后的桥方法 `perm.request` 都只调它。
///
/// 流程：查当前状态 → 已授权直接返回；系统已不会再弹（永久拒绝）→ 不调系统接口，引导去设置
/// （`perm.<type>.denied_forever` + `perm.go_settings`）；被拒后 48 小时内（BR-ID-13，时长只在该条维护）再申请 →
/// 不弹用途说明与系统框，返回 throttled 并引导去设置（从设置类入口主动点击的不受此限）；否则先显示用途说明
/// （iOS：一屏说明，用户点【继续】后）再弹系统框，记下结果。被拒（含永久拒绝）时把这一刻持久化为节流起点；
/// 被节流的点击不改动起点。节流记录不随「清除缓存」清除（放在 Application Support，不在缓存目录）。
///
/// 系统调用全部经注入接口（单测用假实现）。不是线程安全的：生产代码只在主线程使用。
/// TODO(N-21): unavailable 的具体映射、说明页取消、并发申请、时钟回拨未规定（rule-gaps 第 7 条）：系统状态或结果不认识的
/// 按 unavailable；说明页只有【继续】；同一权限并发申请不合并；时钟回拨（现在早于记录）按仍在节流期内处理。
public final class PermissionRequester {
    /// BR-ID-13：被拒后 48 小时内不再主动弹申请。
    public static let throttleMillis: Int64 = 48 * 60 * 60 * 1000

    private let readFile: () throws -> String?
    private let writeFile: (String?) throws -> Void
    private let clock: () -> Int64
    private let platform: String
    private let status: (String) async -> String
    private let showRationale: (String, String?) async -> Void
    private let systemRequest: (String) async -> String
    private let showSettingsGuide: (String?, String) -> Void

    /// 本进程内的节流记录（文件写失败时仍在内存里生效）。
    private var memoryRecords: [String: Int64] = [:]

    public init(
        readFile: @escaping () throws -> String?,
        writeFile: @escaping (String?) throws -> Void,
        clock: @escaping () -> Int64,
        platform: String,
        status: @escaping (String) async -> String,
        showRationale: @escaping (String, String?) async -> Void,
        systemRequest: @escaping (String) async -> String,
        showSettingsGuide: @escaping (String?, String) -> Void
    ) {
        self.readFile = readFile
        self.writeFile = writeFile
        self.clock = clock
        self.platform = platform
        self.status = status
        self.showRationale = showRationale
        self.systemRequest = systemRequest
        self.showSettingsGuide = showSettingsGuide
    }

    /// 申请一项权限。
    /// - Parameters:
    ///   - fromSettingsEntry: 用户从设置类入口主动点击（不受 48 小时节流，BR-ID-13）。
    ///   - purposeShown: 入口本身已经展示了用途（如待跟单卡里的通知说明行），跳过单独的说明步骤（03 §4.9）。
    /// 在调用方的执行上下文里运行（`nonisolated(nonsending)`）：App 在主线程调用时说明页与系统框都在主线程，
    /// 不把本对象送到别的执行上下文。
    public nonisolated(nonsending) func request(
        permission: String,
        fromSettingsEntry: Bool = false,
        purposeShown: Bool = false
    ) async -> PermissionResult {
        let current = await status(permission)
        guard let keys = PermissionTextKeys.table[permission] else {
            return result(permission, PermissionResultRaw.unavailable)
        }
        switch current {
        case PermissionStatusRaw.granted:
            return result(permission, PermissionResultRaw.granted)
        case PermissionStatusRaw.permanentlyDenied:
            showSettingsGuide(keys.deniedForever, PermissionTextKeys.goSettings)
            return result(permission, PermissionResultRaw.permanentlyDenied)
        case PermissionStatusRaw.notAsked, PermissionStatusRaw.denied:
            break
        default:
            return result(permission, PermissionResultRaw.unavailable)
        }
        if !fromSettingsEntry, isThrottled(permission, status: current) {
            showSettingsGuide(keys.deniedForever, PermissionTextKeys.goSettings)
            return result(permission, PermissionResultRaw.throttled)
        }
        if !purposeShown {
            await showRationale(keys.purpose, PermissionTextKeys.continueButton)
        }
        return await settle(permission, answer: systemRequest(permission))
    }

    /// 某项权限的节流起点（上次被拒的时刻，毫秒）；没有记录为 nil。
    public func deniedAt(_ permission: String) -> Int64? {
        if let value = memoryRecords[permission] {
            return value
        }
        return (try? readRecords())?[permission]
    }

    // MARK: - 内部

    /// 系统框的结果：允许清掉节流记录；拒绝（含永久拒绝）把这一刻记为节流起点；不认识的按 unavailable。
    private func settle(_ permission: String, answer: String) -> PermissionResult {
        switch answer {
        case PermissionStatusRaw.granted:
            clearDenial(permission)
            return result(permission, PermissionResultRaw.granted)
        case PermissionStatusRaw.denied:
            recordDenial(permission)
            return result(permission, PermissionResultRaw.denied)
        case PermissionStatusRaw.permanentlyDenied:
            recordDenial(permission)
            return result(permission, PermissionResultRaw.permanentlyDenied)
        default:
            return result(permission, PermissionResultRaw.unavailable)
        }
    }

    private func result(_ permission: String, _ raw: String) -> PermissionResult {
        PermissionResult(permission: permission, resultRaw: raw)
    }

    private func isThrottled(_ permission: String, status current: String) -> Bool {
        let stored: Int64?
        do {
            stored = try readRecords()[permission]
        } catch {
            // 记录读不出：系统说拒绝过时按仍在节流期内处理（不主动再弹）；系统说从没申请过时照常申请。
            return current == PermissionStatusRaw.denied
        }
        guard let deniedAt = max(stored, memoryRecords[permission]) else {
            return false
        }
        return clock() - deniedAt < Self.throttleMillis
    }

    private func recordDenial(_ permission: String) {
        let now = clock()
        memoryRecords[permission] = now
        var records = (try? readRecords()) ?? [:]
        records[permission] = now
        try? writeFile(Self.encode(records))
    }

    private func clearDenial(_ permission: String) {
        memoryRecords[permission] = nil
        guard var records = try? readRecords(), records[permission] != nil else {
            return
        }
        records[permission] = nil
        try? writeFile(records.isEmpty ? nil : Self.encode(records))
    }

    /// 读文件：没有文件为空记录；读不了抛错；内容损坏按空记录（下次写入覆盖）。
    private func readRecords() throws -> [String: Int64] {
        guard let text = try readFile() else {
            return [:]
        }
        guard let root = ConfigDocument.parse(text), root.object["v"] as? Int == 1,
              let table = root.object["denied_at"] as? [String: NSNumber]
        else {
            return [:]
        }
        return table.mapValues(\.int64Value)
    }

    private static func encode(_ records: [String: Int64]) -> String? {
        ConfigDocument.encode(["v": 1, "denied_at": records])
    }
}

private func max(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
    switch (lhs, rhs) {
    case let (left?, right?): Swift.max(left, right)
    case let (left?, nil): left
    case let (nil, right?): right
    case (nil, nil): nil
    }
}
