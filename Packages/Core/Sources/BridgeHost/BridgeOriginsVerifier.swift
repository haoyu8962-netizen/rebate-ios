import CryptoKit
import Foundation

// N-22（D10-2539）：/v1/config 的 bridge_origins 验签（ES256 JWS，契约 components.schemas.ConfigBridgeOrigins；三端共用向量
// couli-runs/NATIVE/N22-VECTORS）。纯函数，不读任何全局状态：公钥表、本应用 appId、当前运行环境 id、上次可用白名单的 version
// 都由调用方传入。判定顺序同契约 description（向量 rules_order），任一条不过即拒，不做任何「先规范化再接受」。

/// 随包的配置签名公钥表（构建配置 `CouliConfigSignKeys` 经 `parse` 读入；测试经 `init(derKeys:)` 注入）。
/// 按 (env, kid) 取钥：同一 kid 在别的环境下不可用。只收 P-256 公钥；坏项跳过。
public struct ConfigSignKeys: Sendable {
    /// 一把钥的可公开摘要（不含公钥本身）：环境、kid 与 SPKI DER 的 sha256 前 16 位十六进制（小写）。
    public struct Entry: Sendable, Equatable {
        public let env: String
        public let kid: String
        public let spkiSha256Prefix16: String

        public init(env: String, kid: String, spkiSha256Prefix16: String) {
            self.env = env
            self.kid = kid
            self.spkiSha256Prefix16 = spkiSha256Prefix16
        }
    }

    /// 一把随包公钥（SPKI DER 原样保存；收入前已确认能解析成 P-256 公钥）。
    struct Key: Sendable {
        let env: String
        let kid: String
        let der: Data

        /// env、kid 非空且 DER 是 P-256 公钥才收；否则 nil。
        init?(env: String, kid: String, der: Data) {
            guard !env.isEmpty, !kid.isEmpty, (try? P256.Signing.PublicKey(derRepresentation: der)) != nil else {
                return nil
            }
            self.env = env
            self.kid = kid
            self.der = der
        }

        var publicKey: P256.Signing.PublicKey? {
            try? P256.Signing.PublicKey(derRepresentation: der)
        }
    }

    let keys: [Key]

    public static let empty = ConfigSignKeys(keys: [])

    init(keys: [Key]) {
        self.keys = keys
    }

    /// 构建配置串：空白或逗号分隔的若干项 `env:kid:<SPKI DER 十六进制>`；坏项（段数不对、env / kid 为空、非十六进制或奇数位、
    /// 不是 P-256 公钥）跳过，不崩。十六进制大小写都收。
    public static func parse(_ spec: String) -> ConfigSignKeys {
        let items = spec.split { $0 == "," || $0.isWhitespace }
        let keys = items.compactMap { item -> Key? in
            let parts = item.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, let der = hexData(parts[2]) else {
                return nil
            }
            return Key(env: String(parts[0]), kid: String(parts[1]), der: der)
        }
        return ConfigSignKeys(keys: keys)
    }

    /// 测试注入用（SPKI DER）；env / kid 为空或不是 P-256 公钥的项跳过。
    public init(derKeys: [(env: String, kid: String, der: Data)]) { // swiftlint:disable:this large_tuple
        keys = derKeys.compactMap { Key(env: $0.env, kid: $0.kid, der: $0.der) }
    }

    /// 全部可用钥的摘要，按 env、kid 排序。
    public var entries: [Entry] {
        keys.map { key in
            let digest = SHA256.hash(data: key.der).map { String(format: "%02x", $0) }.joined()
            return Entry(env: key.env, kid: key.kid, spkiSha256Prefix16: String(digest.prefix(16)))
        }
        .sorted { ($0.env, $0.kid) < ($1.env, $1.kid) }
    }

    /// 是否有 (env, kid) 这把钥。
    public func hasKey(env: String, kid: String) -> Bool {
        key(env: env, kid: kid) != nil
    }

    /// (env, kid) 对应的公钥；重复登记时取第一项（与向量参考实现相同）。
    func key(env: String, kid: String) -> P256.Signing.PublicKey? {
        keys.first { $0.env == env && $0.kid == kid }?.publicKey
    }

    /// 严格十六进制（大小写都收，偶数位、非空）。
    private static func hexData(_ text: Substring) -> Data? {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty, scalars.count.isMultiple(of: 2) else {
            return nil
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(scalars.count / 2)
        var index = 0
        while index < scalars.count {
            guard let high = hexValue(scalars[index]), let low = hexValue(scalars[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        return Data(bytes)
    }

    private static func hexValue(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar.value {
        case 0x30...0x39: UInt8(scalar.value - 0x30)
        case 0x41...0x46: UInt8(scalar.value - 0x41 + 10)
        case 0x61...0x66: UInt8(scalar.value - 0x61 + 10)
        default: nil
        }
    }
}

/// 验签通过的可信 H5 源白名单（origins 每项本身就是规范化 https origin，顺序照签名里的）。
public struct BridgeOriginsAllowlist: Sendable, Equatable {
    public let version: Int
    public let origins: [String]

    public init(version: Int, origins: [String]) {
        self.version = version
        self.origins = origins
    }
}

/// 验签结论。rejected 的 reason 只供日志定位，判定只看 accepted / rejected。
public enum BridgeOriginsVerdict: Sendable, Equatable {
    case accepted(BridgeOriginsAllowlist)
    case rejected(reason: String)
}

/// bridge_origins 验签器（契约 ConfigBridgeOrigins；三端共用向量 N22-VECTORS）。
public enum BridgeOriginsVerifier {
    /// 契约规定的 header.alg / header.typ / payload.v。
    static let algorithm = "ES256"
    static let tokenType = "couli-bridge-origins+jws"
    static let schemaVersion = 1

    /// reason 取向量里的那套字符串（malformed / bad_alg / no_key_for_kid_env / bad_signature_format / bad_signature / bad_typ /
    /// bad_v / app_id_mismatch / env_mismatch / bad_payload / version_rollback / bad_origin），只供日志定位。
    public static func verify(
        jws: String, appId: String, env: String, lastGoodVersion: Int?, keys: ConfigSignKeys
    ) -> BridgeOriginsVerdict {
        // 规则 1：三段 base64url（严格字符集、无填充、每段非空）；header 是 JSON 对象。
        guard let token = BridgeOriginsToken(jws) else {
            return .rejected(reason: "malformed")
        }
        // 规则 2：alg == ES256。
        guard token.header["alg"] as? String == algorithm else {
            return .rejected(reason: "bad_alg")
        }
        // 规则 3：按 header.kid + 当前运行环境取随包公钥。
        guard let kid = token.header["kid"] as? String, let publicKey = keys.key(env: env, kid: kid) else {
            return .rejected(reason: "no_key_for_kid_env")
        }
        // 规则 4：签名正好 64 字节 R‖S（IEEE P1363，不收 DER），ECDSA P-256 / SHA-256 验 ASCII `header.payload`。
        guard token.signature.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: token.signature)
        else {
            return .rejected(reason: "bad_signature_format")
        }
        guard publicKey.isValidSignature(signature, for: Data(token.signingInput.utf8)) else {
            return .rejected(reason: "bad_signature")
        }
        // 规则 5：typ == couli-bridge-origins+jws（缺失也拒）。
        guard token.header["typ"] as? String == tokenType else {
            return .rejected(reason: "bad_typ")
        }
        return verifyPayload(token.payload, appId: appId, env: env, lastGoodVersion: lastGoodVersion)
    }

    /// 从配置文档（/v1/config 的 data 对象）取 `bridge_origins.jws` 再验；字段缺失 / 形状不对（含旧的字符串数组形状）= rejected("malformed")。
    /// bridge_origins 对象里多带的字段一律忽略（只取 jws，不混入任何明文 origins）。
    public static func verify(
        config: [String: Any], appId: String, env: String, lastGoodVersion: Int?, keys: ConfigSignKeys
    ) -> BridgeOriginsVerdict {
        guard let object = config["bridge_origins"] as? [String: Any], let jws = object["jws"] as? String else {
            return .rejected(reason: "malformed")
        }
        return verify(jws: jws, appId: appId, env: env, lastGoodVersion: lastGoodVersion, keys: keys)
    }

    /// 只解 header 取 kid（给日志定位用，不验任何东西）；header 段不是严格 base64url、不是 JSON 对象或没有字符串 kid 时为 nil。
    public static func headerKid(jws: String) -> String? {
        let first = jws.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard let data = BridgeBase64URL.decode(first), let header = jsonObject(data) else {
            return nil
        }
        return header["kid"] as? String
    }

    // MARK: - 验签之后的 payload

    /// 规则 6–8（签名已验过；payload 解不开或不是对象 = bad_payload）。
    static func verifyPayload(_ data: Data, appId: String, env: String, lastGoodVersion: Int?) -> BridgeOriginsVerdict {
        guard let payload = jsonObject(data) else {
            return .rejected(reason: "bad_payload")
        }
        // 规则 6：v 是整数 1（布尔、小数、字符串都不算）；app_id、env 与调用方逐字相等。
        guard integer(payload["v"]) == schemaVersion else {
            return .rejected(reason: "bad_v")
        }
        guard payload["app_id"] as? String == appId else {
            return .rejected(reason: "app_id_mismatch")
        }
        guard payload["env"] as? String == env else {
            return .rejected(reason: "env_mismatch")
        }
        // 规则 7：version 整数且 ≥ 0；有上次可用时 ≥ 它（等于不算回退）。
        guard let version = integer(payload["version"]), version >= 0 else {
            return .rejected(reason: "bad_payload")
        }
        if let lastGoodVersion, version < lastGoodVersion {
            return .rejected(reason: "version_rollback")
        }
        // 规则 8：origins 非空字符串数组，每项本身就是规范化 https origin；任一项不合格整份拒。
        guard let items = payload["origins"] as? [Any], !items.isEmpty else {
            return .rejected(reason: "bad_payload")
        }
        let origins = items.compactMap { $0 as? String }
        guard origins.count == items.count else {
            return .rejected(reason: "bad_payload")
        }
        guard origins.allSatisfy(isCanonicalOrigin) else {
            return .rejected(reason: "bad_origin")
        }
        return .accepted(BridgeOriginsAllowlist(version: version, origins: origins))
    }

    /// 字符串本身就是规范化 https origin：`https://` + 小写主机（点分标签，标签为 [a-z0-9-]、不以 - 开头或结尾）+ 可选端口
    /// （十进制、无前导 0、1–65535 且不是 443）；不得有凭据、路径（含末尾 /）、查询、片段、通配、空白或大写。
    static func isCanonicalOrigin(_ origin: String) -> Bool {
        let prefix = "https://"
        guard origin.hasPrefix(prefix) else {
            return false
        }
        let rest = origin.dropFirst(prefix.count)
        let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let host = parts.first, isCanonicalHost(host) else {
            return false
        }
        guard parts.count == 2 else {
            return true
        }
        return isCanonicalPort(parts[1])
    }

    private static func isCanonicalHost(_ host: Substring) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            let scalars = Array(label.unicodeScalars)
            guard let first = scalars.first, let last = scalars.last, first != "-", last != "-" else {
                return false
            }
            return scalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }
    }

    private static func isCanonicalPort(_ port: Substring) -> Bool {
        let scalars = Array(port.unicodeScalars)
        guard (1...5).contains(scalars.count), scalars.first != "0",
              scalars.allSatisfy({ ("0"..."9").contains($0) }), let value = Int(String(port))
        else {
            return false
        }
        return (1...65535).contains(value) && value != 443
    }

    // MARK: - JSON

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
    }

    /// JSON 整数（JSONSerialization 的 NSNumber：布尔、小数（含 1.0）、超出 Int 范围的都不算）。
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !(number is NSDecimalNumber), !JSONKind.isBool(number),
              !CFNumberIsFloatType(number)
        else {
            return nil
        }
        let int = number.intValue
        return number.compare(NSNumber(value: int)) == .orderedSame ? int : nil
    }
}

/// 一个三段 JWS 的拆解结果（只做结构检查：三段严格 base64url，header 是 JSON 对象）。
struct BridgeOriginsToken {
    let header: [String: Any]
    let payload: Data
    let signature: Data
    /// 签名输入：原样的 `header.payload` 两段（ASCII）。
    let signingInput: String

    init?(_ jws: String) {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = BridgeBase64URL.decode(parts[0]),
              let payload = BridgeBase64URL.decode(parts[1]),
              let signature = BridgeBase64URL.decode(parts[2]),
              let header = BridgeOriginsVerifier.jsonObject(headerData)
        else {
            return nil
        }
        self.header = header
        self.payload = payload
        self.signature = signature
        signingInput = String(parts[0]) + "." + String(parts[1])
    }
}

/// 严格 base64url（RFC 4648 §5）：字符集 [A-Za-z0-9_-]、无填充、非空；长度模 4 余 1 的不是合法编码。
enum BridgeBase64URL {
    static func decode(_ text: Substring) -> Data? {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty, scalars.count % 4 != 1, scalars.allSatisfy(isAlphabet) else {
            return nil
        }
        var base = String(text).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        return Data(base64Encoded: base)
    }

    private static func isAlphabet(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
            || scalar == "-" || scalar == "_"
    }
}
