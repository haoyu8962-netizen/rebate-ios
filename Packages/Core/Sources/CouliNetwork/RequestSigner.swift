import CryptoKit
import Foundation
import Security

/// 请求签名（BR-ID-09 细则；specs/request-sign.vectors.json 为服务端与三端共用的向量）：
///
/// 签名串 = 大写方法 + "\n" + 不含协议与主机的路径（含 "?" 后原样的查询串）+ "\n" + X-Timestamp + "\n" + X-Nonce + "\n"
/// + lowercase_hex(sha256(原始请求体字节))；X-Sign = lowercase_hex(HMAC-SHA256(install_secret 的 UTF-8 字节, 签名串))。
/// 请求体按发出的原始字节计算，不做 JSON 解析或重新序列化；空请求体对零字节求哈希。
public enum RequestSigner {
    /// 签名串。method、pathWithQuery 原样参与（调用方负责传大写方法与发出的路径）。
    public static func signingString(
        method: String,
        pathWithQuery: String,
        timestamp: String,
        nonce: String,
        body: Data
    ) -> String {
        [method, pathWithQuery, timestamp, nonce, sha256Hex(body)].joined(separator: "\n")
    }

    /// X-Sign。
    public static func sign(installSecret: String, signingString: String) -> String {
        let key = SymmetricKey(data: Data(installSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signingString.utf8), using: key)
        return hex(Data(mac))
    }

    /// 一组签名头（签名串由 `signingString` 算好）。
    public static func headers(
        installSecret: String,
        signingString: String,
        timestamp: String,
        nonce: String
    ) -> [String: String] {
        [
            HeaderNames.timestamp: timestamp,
            HeaderNames.nonce: nonce,
            HeaderNames.sign: sign(installSecret: installSecret, signingString: signingString),
        ]
    }

    /// X-Timestamp：Unix 秒。
    public static func timestamp(nowMillis: Int64) -> String {
        String(nowMillis / 1000)
    }

    /// X-Nonce：32 位小写十六进制（16 字节安全随机数）。
    public static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return hex(Data(bytes))
    }

    public static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
