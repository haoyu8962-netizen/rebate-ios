import BridgeHost
import CryptoKit
import Foundation
import XCTest

/// N-22（D10-2539）：bridge_origins 验签的三端共用向量（couli-runs/NATIVE/N22-VECTORS，原样拷进 Resources/N22）与公钥表解析。
/// 判定只看 accept 与 origins（reason 只写进失败信息供定位）。需要 Package.swift 的 BridgeHostTests 有
/// `resources: [.copy("Resources/N22")]`。现签类用例见 BridgeOriginsFreshSignTests.swift（测试里临时生成钥对，env test）。
final class BridgeOriginsVectorTests: XCTestCase {
    static let vectorSha256Prefix16 = "0b773cfc9a25189d"
    static let stagingKid = "config-staging-2026-11b"
    static let stagingSha256Prefix16 = "07ba14efc5908e5c"
    static let vectorTestKid = "n22-vector-test-key-1"
    /// 构建配置（Debug / Staging.xcconfig 的 COULI_CONFIG_SIGN_KEYS）里的 staging 公钥 SPKI DER 十六进制。
    static let stagingDerHex = "3059301306072a8648ce3d020106082a8648ce3d03010703420004ae883f464888bece2a33c015a42e897e"
        + "07672c37b43a244f556678f595417dbcf359128f1ee420e841b4b286d06e487882b7d4a1a92abd5e7e81db5715462af0"
    static let stagingOrigin = "https://h5-stg.couliapp.cn"

    struct Vector {
        let name: String
        let jws: String
        let appId: String
        let env: String
        let lastGoodVersion: Int?
        let accept: Bool
        let origins: [String]?
        let reason: String
    }

    // MARK: - 向量文件本身

    /// 防止向量文件被截断或换成别的版本而全绿：sha256 前 16 位、33 条、应通过 4 条、名字不重复、公钥摘要与 PEM 一致。
    func testVectorFileIsTheSharedThirtyThreeCases() throws {
        XCTAssertEqual(sha256Prefix16(try resource("n22-bridge-origins-vectors", "json")), Self.vectorSha256Prefix16,
                       "拷入的向量文件与 N22-VECTORS 不一致")
        let all = try vectors()
        XCTAssertEqual(all.count, 33, "向量条数")
        XCTAssertEqual(all.filter(\.accept).count, 4, "应通过的向量条数")
        XCTAssertEqual(Set(all.map(\.name)).count, all.count, "向量名重复")
        for vector in all where vector.accept {
            XCTAssertNotNil(vector.origins, "\(vector.name)：应通过却没给 origins")
        }
        XCTAssertEqual(sha256Prefix16(try pemDER("es256.pub")), Self.stagingSha256Prefix16, "es256.pub.pem 摘要")
        XCTAssertEqual(sha256Prefix16(try pemDER("n22-vector-test-key-1.pub")), "f3494fc5043fc593", "测试钥 PEM 摘要")
        XCTAssertEqual(hexString(try pemDER("es256.pub")), Self.stagingDerHex, "构建配置里的 staging 公钥与 PEM 不一致")
    }

    // MARK: - 逐条跑

    func testEveryVectorCaseMatchesExpectedVerdict() throws {
        let keys = try vectorKeys()
        var checked = 0
        var accepted = 0
        for vector in try vectors() {
            checked += 1
            let verdict = BridgeOriginsVerifier.verify(
                jws: vector.jws, appId: vector.appId, env: vector.env,
                lastGoodVersion: vector.lastGoodVersion, keys: keys
            )
            if try assertVerdict(verdict, matches: vector, entry: "verify(jws:)") {
                accepted += 1
            }
        }
        XCTAssertEqual(checked, 33, "实际跑到的向量条数")
        // 应通过 = 4：stg_live_ok、stg_live_ok_last_good_equal、t_ok、t_ok_two_origins_port。
        XCTAssertEqual(accepted, 4, "实际通过的向量条数")
    }

    /// 同一批向量经配置文档入口（`bridge_origins: {"jws": ...}`，ConfigStore 实际走的那个）再跑一遍，判定必须一致。
    func testEveryVectorCaseViaConfigDocumentMatchesExpectedVerdict() throws {
        let keys = try vectorKeys()
        var accepted = 0
        for vector in try vectors() {
            let verdict = BridgeOriginsVerifier.verify(
                config: ["dict_version": "n22", "bridge_origins": ["jws": vector.jws]], appId: vector.appId,
                env: vector.env, lastGoodVersion: vector.lastGoodVersion, keys: keys
            )
            if try assertVerdict(verdict, matches: vector, entry: "verify(config:)") {
                accepted += 1
            }
        }
        XCTAssertEqual(accepted, 4, "配置文档入口实际通过的向量条数")
    }

    // MARK: - 公钥表

    func testEmptyKeyTableRejectsStagingLive() throws {
        let live = try vector(named: "stg_live_ok")
        let verdict = BridgeOriginsVerifier.verify(
            jws: live.jws, appId: "couli", env: "staging", lastGoodVersion: nil, keys: .empty
        )
        XCTAssertFalse(isAccepted(verdict), "空公钥表也通过了 staging 实测 jws：\(verdict)")
        XCTAssertEqual(ConfigSignKeys.empty.entries, [])
    }

    /// 取钥按 (kid, 当前运行环境) 两项：同一把钥登记在别的环境、或 kid 不同，都不能拿来验（防「只按 kid 取钥」）。
    func testKeyIsBoundToItsEnvAndKid() throws {
        let live = try vector(named: "stg_live_ok")
        let der = try pemDER("es256.pub")
        let tables: [(String, ConfigSignKeys)] = [
            ("同钥登记在 prod", ConfigSignKeys(derKeys: [(env: "prod", kid: Self.stagingKid, der: der)])),
            ("同钥登记在 test", ConfigSignKeys(derKeys: [(env: "test", kid: Self.stagingKid, der: der)])),
            ("同钥换了 kid", ConfigSignKeys(derKeys: [(env: "staging", kid: "config-staging-other", der: der)])),
        ]
        for (label, keys) in tables {
            let verdict = BridgeOriginsVerifier.verify(
                jws: live.jws, appId: "couli", env: "staging", lastGoodVersion: nil, keys: keys
            )
            XCTAssertFalse(isAccepted(verdict), "\(label)：staging 运行环境不该取到这把钥，实得 \(verdict)")
        }
    }

    func testParseBuildConfigSpecYieldsStagingKey() throws {
        let keys = ConfigSignKeys.parse("staging:\(Self.stagingKid):\(Self.stagingDerHex)")
        XCTAssertEqual(keys.entries, [stagingEntry])
        XCTAssertTrue(keys.hasKey(env: "staging", kid: Self.stagingKid))
        XCTAssertFalse(keys.hasKey(env: "prod", kid: Self.stagingKid), "kid 只在登记的 env 下可用")
        XCTAssertFalse(keys.hasKey(env: "staging", kid: "config-staging-unknown"))
        // 解析出的是能验签的真钥，不只是摘要。
        let live = try vector(named: "stg_live_ok")
        let verdict = BridgeOriginsVerifier.verify(
            jws: live.jws, appId: "couli", env: "staging", lastGoodVersion: nil, keys: keys
        )
        XCTAssertEqual(verdict, .accepted(BridgeOriginsWhitelist(version: 0, origins: [Self.stagingOrigin])))
    }

    /// 坏项（段数不对、非十六进制、奇数位、不是公钥、不是 P-256）一律跳过、不崩；空串 / 只有分隔符 = 空表。
    func testParseSkipsBadItems() {
        for item in badSpecItems() {
            XCTAssertEqual(ConfigSignKeys.parse(item).entries, [], "坏项应跳过：\(item.prefix(60))")
        }
        XCTAssertEqual(ConfigSignKeys.parse("").entries, [])
        XCTAssertEqual(ConfigSignKeys.parse("  ,\n\t , ").entries, [])
    }

    func testParseKeepsGoodItemAmongBadOnes() {
        let good = "staging:\(Self.stagingKid):\(Self.stagingDerHex)"
        let spec = (badSpecItems() + [good]).joined(separator: " ,\n")
        let keys = ConfigSignKeys.parse(spec)
        XCTAssertEqual(keys.entries, [stagingEntry], "坏项跳过、好项保留")
        XCTAssertTrue(keys.hasKey(env: "staging", kid: Self.stagingKid))
    }

    func testEntriesAreSortedByEnvThenKid() {
        let keyA = P256.Signing.PrivateKey().publicKey.derRepresentation
        let keyB = P256.Signing.PrivateKey().publicKey.derRepresentation
        let keyC = P256.Signing.PrivateKey().publicKey.derRepresentation
        let expected = [
            ConfigSignKeys.Entry(env: "staging", kid: "k-a", spkiSha256Prefix16: sha256Prefix16(keyC)),
            ConfigSignKeys.Entry(env: "staging", kid: "k-z", spkiSha256Prefix16: sha256Prefix16(keyB)),
            ConfigSignKeys.Entry(env: "test", kid: "k-b", spkiSha256Prefix16: sha256Prefix16(keyA)),
        ]
        let injected = ConfigSignKeys(derKeys: [
            (env: "test", kid: "k-b", der: keyA), (env: "staging", kid: "k-z", der: keyB),
            (env: "staging", kid: "k-a", der: keyC),
        ])
        XCTAssertEqual(injected.entries, expected, "init(derKeys:) 的 entries")
        let parsed = ConfigSignKeys.parse(
            "test:k-b:\(hexString(keyA)) staging:k-z:\(hexString(keyB)),staging:k-a:\(hexString(keyC))"
        )
        XCTAssertEqual(parsed.entries, expected, "parse 的 entries")
    }

}

// MARK: - 工具

extension BridgeOriginsVectorTests {
    private var stagingEntry: ConfigSignKeys.Entry {
        ConfigSignKeys.Entry(env: "staging", kid: Self.stagingKid, spkiSha256Prefix16: Self.stagingSha256Prefix16)
    }

    private func badSpecItems() -> [String] {
        let hex = Self.stagingDerHex
        return [
            "staging:only-two-parts",
            "staging:\(hex)",
            "staging:non-hex:zz\(hex.dropFirst(2))",
            "staging:odd-length:\(hex.dropLast())",
            "staging:not-a-key:deadbeef",
            "staging:p384:\(hexString(P384.Signing.PrivateKey().publicKey.derRepresentation))",
        ]
    }

    /// 返回是否通过；判定与向量不符时记失败（带向量名、入口与实得 reason）。
    private func assertVerdict(_ verdict: BridgeOriginsVerdict, matches vector: Vector, entry: String) throws -> Bool {
        switch verdict {
        case let .accepted(whitelist):
            XCTAssertTrue(vector.accept, "\(vector.name)（\(entry)）：应拒（向量 reason=\(vector.reason)），实得通过 \(whitelist)")
            XCTAssertEqual(whitelist.origins, vector.origins, "\(vector.name)（\(entry)）：origins 不一致")
            XCTAssertEqual(whitelist.version, try payloadVersion(vector.jws),
                           "\(vector.name)（\(entry)）：version 不是签名里的值")
            return true
        case let .rejected(reason):
            XCTAssertFalse(vector.accept, "\(vector.name)（\(entry)）：应通过，实得拒绝 reason=\(reason)")
            return false
        }
    }

    private func payloadVersion(_ jws: String) throws -> Int? {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let data = base64URLDecode(String(parts[1])) else {
            return nil
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? Int
    }

    func vectorKeys() throws -> ConfigSignKeys {
        ConfigSignKeys(derKeys: [
            (env: "staging", kid: Self.stagingKid, der: try pemDER("es256.pub")),
            (env: "test", kid: Self.vectorTestKid, der: try pemDER("n22-vector-test-key-1.pub")),
        ])
    }

    func vector(named name: String) throws -> Vector {
        try XCTUnwrap(try vectors().first(where: { $0.name == name }), "向量文件里没有 \(name)")
    }

    func vectors() throws -> [Vector] {
        let data = try resource("n22-bridge-origins-vectors", "json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], "向量文件不是 JSON 对象")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]], "向量文件没有 cases 数组")
        return try cases.enumerated().map { index, row in
            let name = try XCTUnwrap(row["name"] as? String, "第 \(index) 条没有 name")
            let client = try XCTUnwrap(row["client"] as? [String: Any], "\(name)：没有 client")
            let expect = try XCTUnwrap(row["expect"] as? [String: Any], "\(name)：没有 expect")
            let lastGood = client["last_good_version"]
            if let lastGood, !(lastGood is NSNull) {
                XCTAssertNotNil(lastGood as? Int, "\(name)：last_good_version 不是整数")
            }
            return Vector(
                name: name, jws: try XCTUnwrap(row["jws"] as? String, "\(name)：没有 jws"),
                appId: try XCTUnwrap(client["app_id"] as? String, "\(name)：没有 client.app_id"),
                env: try XCTUnwrap(client["env"] as? String, "\(name)：没有 client.env"),
                lastGoodVersion: lastGood as? Int,
                accept: try XCTUnwrap(expect["accept"] as? Bool, "\(name)：没有 expect.accept"),
                origins: expect["origins"] as? [String], reason: expect["reason"] as? String ?? ""
            )
        }
    }

    func resource(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "N22"),
            "测试资源缺失：N22/\(name).\(ext)（Package.swift 的 BridgeHostTests 需要 resources: [.copy(\"Resources/N22\")]）"
        )
        return try Data(contentsOf: url)
    }

    func pemDER(_ name: String) throws -> Data {
        let text = try XCTUnwrap(String(data: try resource(name, "pem"), encoding: .utf8), "\(name).pem 不是文本")
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return try XCTUnwrap(Data(base64Encoded: body), "\(name).pem 不是 base64")
    }

    private func isAccepted(_ verdict: BridgeOriginsVerdict) -> Bool {
        if case .accepted = verdict {
            return true
        }
        return false
    }
}

// MARK: - 共用小工具（本测试目标内）

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func base64URLDecode(_ text: String) -> Data? {
    var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base += String(repeating: "=", count: (4 - base.count % 4) % 4)
    return Data(base64Encoded: base)
}

func hexString(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func sha256Prefix16(_ data: Data) -> String {
    String(hexString(Data(SHA256.hash(data: data))).prefix(16))
}
