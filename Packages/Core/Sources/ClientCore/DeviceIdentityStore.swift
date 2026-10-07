import Foundation
import Privacy
import SecureStore

/// 服务端签发的设备凭据（BR-ID-09）：device_id、install_secret，以及注册时用的 id_source。
/// install_secret 不可打印（`description` 只给 device_id），只经安全存储保存（CSB-05）。
public struct DeviceIdentity: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let deviceId: String
    let installSecret: String
    public let idSource: String

    public var description: String {
        "DeviceIdentity(\(deviceId), \(idSource))"
    }

    public var debugDescription: String {
        description
    }
}

/// Keychain 条目的内容（JSON）。
private struct StoredDeviceIdentity: Codable {
    let deviceId: String
    let installSecret: String
    let idSource: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case installSecret = "install_secret"
        case idSource = "id_source"
    }
}

/// 设备凭据读取失败（与「不存在」区分开：存储读失败不等于没有记录）。
public enum DeviceIdentityReadError: Error, Equatable, Sendable {
    /// 安全存储暂时读不了（设备锁定、Keychain 不可用）：可能已经注册过，不得当成没有而重新注册。
    case readFailed
    /// 条目存在但内容损坏：不能当凭据用。
    case corrupted
}

/// 设备凭据的安全存储：device_id 与 install_secret 合成一个 Keychain 条目（`CredentialAccount.deviceIdentityAccount`），
/// 一次写入、一次读出，不会只写一半（03 §3.3 安全存储行；CSB-05、CSB-06：条目仅本设备可用、不随备份迁移）。
public final class DeviceIdentityStore: @unchecked Sendable {
    public static let account = CredentialAccount.deviceIdentityAccount

    private let store: any SecureKeyValueStore

    public init(store: any SecureKeyValueStore) {
        self.store = store
    }

    /// nil = 确认没有；抛 `DeviceIdentityReadError` = 读取失败或内容损坏。
    func read() throws -> DeviceIdentity? {
        let data: Data?
        do {
            data = try store.data(forAccount: Self.account)
        } catch {
            throw DeviceIdentityReadError.readFailed
        }
        guard let data else {
            return nil
        }
        guard let stored = try? JSONDecoder().decode(StoredDeviceIdentity.self, from: data),
              !stored.deviceId.isEmpty, !stored.installSecret.isEmpty
        else {
            throw DeviceIdentityReadError.corrupted
        }
        return DeviceIdentity(deviceId: stored.deviceId, installSecret: stored.installSecret, idSource: stored.idSource)
    }

    func save(_ identity: DeviceIdentity) throws {
        let stored = StoredDeviceIdentity(
            deviceId: identity.deviceId, installSecret: identity.installSecret, idSource: identity.idSource
        )
        try store.set(JSONEncoder().encode(stored), forAccount: Self.account)
    }

    func clear() throws {
        try store.remove(account: Self.account)
    }
}
