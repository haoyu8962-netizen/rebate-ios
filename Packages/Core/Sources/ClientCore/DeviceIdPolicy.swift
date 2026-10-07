import CryptoKit
import Foundation
import Generated

/// 设备标识判定的结果（BR-ID-09、BR-ID-11）。
public struct DeviceIdDecision: Sendable, Equatable {
    /// 可以注册（求哈希并上报）。
    public let register: Bool
    /// 原因（`DeviceIdPolicy.Reason`；向量不断言具体取值，rule-gaps 第 1 条）。
    public let reasonRaw: String
    /// register 为 true 时的 device_hash。
    public let deviceHash: String?
    /// register 为 true 时的 id_source（idfv / android_id / odid）。
    public let idSource: String?
}

/// 设备标识的有效性与哈希（BR-ID-09 细则「设备标识的无效值」；specs/device-hash.vectors.json）。纯函数，三端同一规则。
///
/// 判定顺序：隐私不是「已同意」→ 不注册（真实入口在此之前连标识都不读，`DeviceRegistry`）；端别不认识 → 不注册；
/// 取不到或去首尾空白后为空 → 无效；去掉 `0` 与 `-` 后为空（全零、只有连字符）→ 无效；按哈希输入规则求出的哈希命中
/// 无效设备哈希种子（`DeviceHashSeeds`，含已知公共固定值）→ 无效。无效值一律视为取不到，不得求哈希上报，也不用固定值、
/// 随机值或其他标识代替。
/// TODO(N-21): BR-ID-09 没有给出各标识的长度与字符集规则（向量也不覆盖），不自造正则；服务端 20001 兜底。
public enum DeviceIdPolicy {
    /// 原因取值（实现自定，向量不断言）。
    public enum Reason {
        public static let valid = "valid"
        public static let privacyNotConsented = "privacy_not_consented"
        public static let unknownPlatform = "unknown_platform"
        public static let missing = "identifier_missing"
        public static let allZero = "identifier_all_zero"
        public static let knownInvalid = "identifier_known_invalid"
    }

    /// 隐私结论里「已同意」的取值（与 `PrivacyDecision.consented` 同名）。
    public static let consented = "consented"

    /// 各端的标识来源（openapi RegisterDeviceRequest.id_source）。MVP 不采集 OAID（BR-ID-09，Android 只用 ANDROID_ID）。
    public static func idSource(platform: String) -> String? {
        switch platform {
        case "ios": "idfv"
        case "android": "android_id"
        case "harmony": "odid"
        default: nil
        }
    }

    public static func evaluate(platform: String, rawId: String?, privacy: String) -> DeviceIdDecision {
        guard privacy == consented else {
            return reject(Reason.privacyNotConsented)
        }
        guard let source = idSource(platform: platform) else {
            return reject(Reason.unknownPlatform)
        }
        guard let rawId else {
            return reject(Reason.missing)
        }
        let normalized = normalize(rawId)
        guard !normalized.isEmpty else {
            return reject(Reason.missing)
        }
        guard normalized.contains(where: { $0 != "0" && $0 != "-" }) else {
            return reject(Reason.allZero)
        }
        let hash = hashNormalized(normalized)
        guard !DeviceHashSeeds.invalidHashes.contains(hash) else {
            return reject(Reason.knownInvalid)
        }
        return DeviceIdDecision(register: true, reasonRaw: Reason.valid, deviceHash: hash, idSource: source)
    }

    /// 哈希输入：去掉首尾 ASCII 空白并转小写。
    public static func normalize(_ raw: String) -> String {
        let whitespace: Set<Character> = [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}", "\r\n"]
        var text = Substring(raw)
        while let first = text.first, whitespace.contains(first) {
            text = text.dropFirst()
        }
        while let last = text.last, whitespace.contains(last) {
            text = text.dropLast()
        }
        return String(text).lowercased()
    }

    /// device_hash = lowercase_hex(SHA-256(UTF-8(normalize(raw))))。只对已判定有效的标识调用（求哈希前先判定）。
    public static func deviceHash(_ raw: String) -> String {
        hashNormalized(normalize(raw))
    }

    private static func hashNormalized(_ normalized: String) -> String {
        SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func reject(_ reason: String) -> DeviceIdDecision {
        DeviceIdDecision(register: false, reasonRaw: reason, deviceHash: nil, idSource: nil)
    }
}
