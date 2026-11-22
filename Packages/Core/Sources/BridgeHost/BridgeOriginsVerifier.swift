import CryptoKit
import Foundation

// N-22（D10-2539）：/v1/config 的 bridge_origins 验签（ES256 JWS，契约 components.schemas.ConfigBridgeOrigins）。
// 纯函数，不读任何全局状态：公钥表、本应用 appId、当前运行环境 id、上次可用白名单的 version 都由调用方传入。
// TODO(N-22-ios 第 2 段)：本文件现在是接口桩（parse 返回空表、hasKey 恒 false、verify 一律 rejected("unimplemented")），
// 供写测方先写测试、先红；验签规则（契约 description 顺序）在第 2 段实现。

/// 随包的配置签名公钥表（构建配置 `CouliConfigSignKeys` 经 `parse` 读入；测试经 `init(derKeys:)` 注入）。
/// 按 (env, kid) 取钥：同一 kid 在别的环境下不可用。
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

    /// 一把随包公钥（SPKI DER 原样保存）。
    struct Key: Sendable {
        let env: String
        let kid: String
        let der: Data
    }

    let keys: [Key]

    public static let empty = ConfigSignKeys(keys: [])

    init(keys: [Key]) {
        self.keys = keys
    }

    /// 构建配置串：空白或逗号分隔的若干项 `env:kid:<SPKI DER 十六进制>`；坏项（段数不对、非十六进制、不是 P-256 公钥）跳过，不崩。
    public static func parse(_ spec: String) -> ConfigSignKeys {
        // 桩：一律空表（第 2 段实现）。
        _ = spec
        return .empty
    }

    /// 测试注入用（SPKI DER）。
    public init(derKeys: [(env: String, kid: String, der: Data)]) { // swiftlint:disable:this large_tuple
        keys = derKeys.map { Key(env: $0.env, kid: $0.kid, der: $0.der) }
    }

    /// 全部可用钥的摘要，按 env、kid 排序。
    public var entries: [Entry] {
        // 桩：不算摘要（第 2 段实现）。
        []
    }

    /// 是否有 (env, kid) 这把钥。
    public func hasKey(env: String, kid: String) -> Bool {
        // 桩：恒 false（第 2 段实现）。
        _ = (env, kid)
        return false
    }
}

/// 验签通过的可信 H5 源白名单（origins 每项本身就是规范化 https origin）。
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
    /// reason 取向量里的那套字符串（malformed / bad_alg / no_key_for_kid_env / bad_signature_format / bad_signature / bad_typ /
    /// bad_v / app_id_mismatch / env_mismatch / bad_payload / version_rollback / bad_origin），只供日志定位。
    public static func verify(
        jws: String, appId: String, env: String, lastGoodVersion: Int?, keys: ConfigSignKeys
    ) -> BridgeOriginsVerdict {
        // 桩：一律拒（第 2 段实现）。
        _ = (jws, appId, env, lastGoodVersion, keys)
        return .rejected(reason: "unimplemented")
    }

    /// 从配置文档（/v1/config 的 data 对象）取 `bridge_origins.jws` 再验；字段缺失 / 形状不对（含旧的字符串数组形状）= rejected("malformed")。
    public static func verify(
        config: [String: Any], appId: String, env: String, lastGoodVersion: Int?, keys: ConfigSignKeys
    ) -> BridgeOriginsVerdict {
        // 桩：一律拒（第 2 段实现）。
        _ = (config, appId, env, lastGoodVersion, keys)
        return .rejected(reason: "unimplemented")
    }
}
