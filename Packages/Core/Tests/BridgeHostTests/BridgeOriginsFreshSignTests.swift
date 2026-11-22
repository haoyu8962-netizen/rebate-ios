import BridgeHost
import CryptoKit
import Foundation
import XCTest

/// N-22（D10-2539）：向量之外的验签规则，用测试里现生成的 P-256 钥对现签（公钥经 `ConfigSignKeys(derKeys:)` 注入，env test）。
/// 拒绝类用例都以 `testFreshSignedBaselineAccepts` 为对照：只改一个字段，其余与通过的基线相同，签名有效。
final class BridgeOriginsFreshSignTests: XCTestCase {
    private let signer = FreshSigner()

    // MARK: - 对照（应通过）

    func testFreshSignedBaselineAccepts() throws {
        let verdict = verify(try signer.jws(payload: FreshSigner.payload()))
        XCTAssertEqual(verdict, .accepted(BridgeOriginsWhitelist(version: 3, origins: ["https://h5-test.couliapp.cn"])))
        let origins = ["https://h5-test.couliapp.cn", "https://a.example:8443"]
        let two = try signer.jws(payload: FreshSigner.payload(origins: json(origins)))
        XCTAssertEqual(verify(two), .accepted(BridgeOriginsWhitelist(version: 3, origins: origins)), "多个源原样保留顺序")
    }

    /// version ≥ 上次可用即通过（等于不算回退）；小于即拒；没有上次可用时不比。
    func testVersionBoundaryAgainstLastGood() throws {
        let jws = try signer.jws(payload: FreshSigner.payload(version: "3"))
        XCTAssertTrue(isAccepted(verify(jws, lastGoodVersion: nil)), "无上次可用")
        XCTAssertTrue(isAccepted(verify(jws, lastGoodVersion: 2)), "高于上次可用")
        XCTAssertTrue(isAccepted(verify(jws, lastGoodVersion: 3)), "等于上次可用不算回退")
        XCTAssertFalse(isAccepted(verify(jws, lastGoodVersion: 4)), "低于上次可用 = 回退")
        let zero = try signer.jws(payload: FreshSigner.payload(version: "0"))
        XCTAssertTrue(isAccepted(verify(zero, lastGoodVersion: 0)), "version 0 等于上次可用 0")
    }

    /// 配置文档入口只用签名里的 origins：bridge_origins 里另带明文 origins 时不得混入。
    func testConfigDocumentUsesOnlySignedOrigins() throws {
        let jws = try signer.jws(payload: FreshSigner.payload())
        let plain = verifyConfig(["bridge_origins": ["jws": jws]])
        XCTAssertEqual(plain, .accepted(BridgeOriginsWhitelist(version: 3, origins: ["https://h5-test.couliapp.cn"])))
        let extra = verifyConfig(["bridge_origins": ["jws": jws, "origins": ["https://evil.example.test"]]])
        if case let .accepted(whitelist) = extra {
            XCTAssertEqual(whitelist.origins, ["https://h5-test.couliapp.cn"], "明文 origins 混进了白名单")
        }
    }

    // MARK: - payload 类型与字段

    func testPayloadTypeConfusionRejected() throws {
        let cases: [(String, String)] = [
            ("v 为 true（布尔不算整数）", FreshSigner.payload(schema: "true")),
            ("v 为字符串", FreshSigner.payload(schema: #""1""#)),
            ("v 缺失", #"{"app_id":"couli","env":"test","version":3,"origins":["https://h5-test.couliapp.cn"]}"#),
            ("version 为 1.5", FreshSigner.payload(version: "1.5")),
            ("version 为字符串", FreshSigner.payload(version: #""3""#)),
            ("version 为 true", FreshSigner.payload(version: "true")),
            ("version 为 null", FreshSigner.payload(version: "null")),
            ("version 缺失", #"{"v":1,"app_id":"couli","env":"test","origins":["https://h5-test.couliapp.cn"]}"#),
            ("origins 缺失", #"{"v":1,"app_id":"couli","env":"test","version":3}"#),
            ("origins 为字符串", FreshSigner.payload(origins: #""https://h5-test.couliapp.cn""#)),
            ("origins 含非字符串", FreshSigner.payload(origins: #"["https://h5-test.couliapp.cn",123]"#)),
            ("origins 含 null", FreshSigner.payload(origins: #"["https://h5-test.couliapp.cn",null]"#)),
            ("app_id 缺失", #"{"v":1,"env":"test","version":3,"origins":["https://h5-test.couliapp.cn"]}"#),
            ("app_id 大小写不同", FreshSigner.payload(appId: #""Couli""#)),
            ("env 缺失", #"{"v":1,"app_id":"couli","version":3,"origins":["https://h5-test.couliapp.cn"]}"#),
            ("payload 是数组", #"[1]"#),
            ("payload 是 null", "null"),
        ]
        for (label, payload) in cases {
            let verdict = verify(try signer.jws(payload: payload))
            XCTAssertFalse(isAccepted(verdict), "\(label)：应拒，实得 \(verdict)")
        }
    }

    /// 每项本身必须是规范化 https origin；任一项不合格整份拒（不得过滤掉坏项后接受其余）。
    func testNonCanonicalOriginsRejected() throws {
        let bad = [
            "https://h5-test.couliapp.cn/", "https://h5-test.couliapp.cn?a=1", "https://h5-test.couliapp.cn#f",
            "https://h5-test.couliapp.cn:", "https://h5-test.couliapp.cn:0", "https://h5-test.couliapp.cn:65536",
            "https://h5-test.couliapp.cn:8443/", "HTTPS://h5-test.couliapp.cn", " https://h5-test.couliapp.cn",
            "https://h5-test.couliapp.cn ", "https://", "h5-test.couliapp.cn",
        ]
        for origin in bad {
            let single = try signer.jws(payload: FreshSigner.payload(origins: json([origin])))
            XCTAssertFalse(isAccepted(verify(single)), "单项 \(origin.debugDescription)：应拒")
            let pair = json(["https://h5-test.couliapp.cn", origin])
            let mixed = try signer.jws(payload: FreshSigner.payload(origins: pair))
            XCTAssertFalse(isAccepted(verify(mixed)), "好项 + \(origin.debugDescription)：整份应拒，不得只留好项")
        }
    }

    /// 运行环境与 app_id 要和调用方一致：同一把钥在 test 与 staging 都登记时，env=test 的文档在 staging 下也不能用。
    func testEnvAndAppIdMustEqualCaller() throws {
        let both = ConfigSignKeys(derKeys: [
            (env: "test", kid: signer.kid, der: signer.publicDER),
            (env: "staging", kid: signer.kid, der: signer.publicDER),
        ])
        let jws = try signer.jws(payload: FreshSigner.payload())
        let onStaging = BridgeOriginsVerifier.verify(
            jws: jws, appId: "couli", env: "staging", lastGoodVersion: nil, keys: both
        )
        XCTAssertFalse(isAccepted(onStaging), "env=test 的文档在 staging 运行环境被接受：\(onStaging)")
        let otherApp = BridgeOriginsVerifier.verify(
            jws: jws, appId: "couli-other", env: "test", lastGoodVersion: nil, keys: both
        )
        XCTAssertFalse(isAccepted(otherApp), "app_id=couli 的文档被别的应用接受：\(otherApp)")
    }

    // MARK: - 签名与结构

    func testSignatureAndStructureTamperingRejected() throws {
        let good = try signer.jws(payload: FreshSigner.payload())
        let parts = good.split(separator: ".").map(String.init)
        let input = parts[0] + "." + parts[1]
        let stranger = FreshSigner(kid: signer.kid)
        let der = try signer.key.signature(for: Data(input.utf8)).derRepresentation
        let cases: [(String, String)] = [
            ("同 kid 的另一把钥签的", try stranger.jws(payload: FreshSigner.payload())),
            ("DER 编码签名", input + "." + base64URL(der)),
            ("签名全零 64 字节", input + "." + base64URL(Data(count: 64))),
            ("签名段为空", input + "."),
            ("四段", good + ".AAAA"),
            ("末尾换行", good + "\n"),
            ("开头空格", " " + good),
            ("alg 小写", try signer.jws(header: header(alg: "es256"), payload: FreshSigner.payload())),
            ("header 缺 kid", try signer.jws(header: #"{"alg":"ES256","typ":"couli-bridge-origins+jws"}"#,
                                             payload: FreshSigner.payload())),
            ("header 不是对象", try signer.jws(header: #"["ES256"]"#, payload: FreshSigner.payload())),
            ("typ 大小写不同", try signer.jws(header: header(typ: "Couli-Bridge-Origins+JWS"),
                                             payload: FreshSigner.payload())),
        ]
        for (label, jws) in cases {
            let verdict = verify(jws)
            XCTAssertFalse(isAccepted(verdict), "\(label)：应拒，实得 \(verdict)")
        }
    }

    /// 配置文档形状不对（缺字段、旧的字符串数组形状、jws 非字符串等）一律拒；jws 本身是有效签名，拒绝只因形状。
    func testConfigDocumentShapesRejected() throws {
        let jws = try signer.jws(payload: FreshSigner.payload())
        let shapes: [(String, [String: Any])] = [
            ("缺 bridge_origins", ["dict_version": "1"]),
            ("旧的字符串数组形状", ["bridge_origins": ["https://h5-test.couliapp.cn"]]),
            ("bridge_origins 直接是 jws 字符串", ["bridge_origins": jws]),
            ("缺 jws", ["bridge_origins": [String: Any]()]),
            ("jws 非字符串", ["bridge_origins": ["jws": 123]]),
            ("jws 键名大小写不同", ["bridge_origins": ["JWS": jws]]),
            ("bridge_origins 为 null", ["bridge_origins": NSNull()]),
            ("bridge_origins 是对象数组", ["bridge_origins": [["jws": jws]]]),
        ]
        for (label, config) in shapes {
            let verdict = verifyConfig(config)
            XCTAssertFalse(isAccepted(verdict), "\(label)：应拒，实得 \(verdict)")
        }
    }

    // MARK: - 工具

    private func verify(_ jws: String, lastGoodVersion: Int? = nil) -> BridgeOriginsVerdict {
        BridgeOriginsVerifier.verify(
            jws: jws, appId: "couli", env: "test", lastGoodVersion: lastGoodVersion, keys: signer.keys
        )
    }

    private func verifyConfig(_ config: [String: Any]) -> BridgeOriginsVerdict {
        BridgeOriginsVerifier.verify(
            config: config, appId: "couli", env: "test", lastGoodVersion: nil, keys: signer.keys
        )
    }

    private func header(alg: String = "ES256", typ: String = "couli-bridge-origins+jws") -> String {
        #"{"alg":"\#(alg)","kid":"\#(signer.kid)","typ":"\#(typ)"}"#
    }

    private func json(_ origins: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: origins, options: [.withoutEscapingSlashes])) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? "[]"
    }

    private func isAccepted(_ verdict: BridgeOriginsVerdict) -> Bool {
        if case .accepted = verdict {
            return true
        }
        return false
    }
}

/// 测试里现生成的签名钥（私钥只在内存里，不落盘）：header / payload 原样 UTF-8 文本经 base64url，签名为 64 字节 R‖S。
struct FreshSigner {
    let key = P256.Signing.PrivateKey()
    let kid: String

    init(kid: String = "n22-unit-fresh-key") {
        self.kid = kid
    }

    var publicDER: Data {
        key.publicKey.derRepresentation
    }

    /// 只装这一把钥（env test）。
    var keys: ConfigSignKeys {
        ConfigSignKeys(derKeys: [(env: "test", kid: kid, der: publicDER)])
    }

    /// 各参数是 JSON 片段原文（便于造类型不对的取值）。
    static func payload(
        schema: String = "1", appId: String = #""couli""#, env: String = #""test""#, version: String = "3",
        origins: String = #"["https://h5-test.couliapp.cn"]"#
    ) -> String {
        #"{"v":\#(schema),"app_id":\#(appId),"env":\#(env),"version":\#(version),"origins":\#(origins)}"#
    }

    func jws(header: String? = nil, payload: String) throws -> String {
        let head = header ?? #"{"alg":"ES256","kid":"\#(kid)","typ":"couli-bridge-origins+jws"}"#
        let input = base64URL(Data(head.utf8)) + "." + base64URL(Data(payload.utf8))
        let signature = try key.signature(for: Data(input.utf8))
        return input + "." + base64URL(signature.rawRepresentation)
    }
}
