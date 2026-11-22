import BridgeHost
import ClientCore
import Config
@testable import Couli
import CryptoKit
import Foundation
import XCTest

/// N-22（D10-2539）的 App 接线：随包公钥表（构建配置 → Info.plist `CouliConfigSignKeys` → `AppConfig.bundledSignKeys`）、
/// AppConfig 组装的验签闭包（每次现取运行环境 id），以及生产 `AppWeb.productionProtocol()` 只认验签通过的上次可用白名单。
/// 网络是本地假服务（WalletStubProtocol，脚本 `GET /v1/config`）；测试钥在测试里现生成（env test），不进任何构建配置。
@MainActor
final class N22BridgeOriginsWiringTests: MeTestCase {
    static let stagingKid = "config-staging-2026-11b"
    static let testOrigin = "https://h5-test.couliapp.cn"
    static let otherOrigin = "https://other.example.test:8443"
    static let evilOrigin = "https://evil.example.test"
    static let stagingOrigin = "https://h5-stg.couliapp.cn"
    /// 三端共用向量文件在仓库里的位置（与 BridgeHostTests 读的是同一份，不在测试源码里另抄 jws）。
    static let vectorsPath = "Packages/Core/Tests/BridgeHostTests/Resources/N22/n22-bridge-origins-vectors.json"

    // MARK: - 构建配置

    /// 宿主 App 是 Debug 构建：随包公钥表含 staging 钥，不含测试钥 / env test。
    func testBundledSignKeysCarryStagingKeyAndNoTestKey() {
        let entries = AppConfig.bundledSignKeys.entries
        let staging = ConfigSignKeys.Entry(env: "staging", kid: Self.stagingKid, spkiSha256Prefix16: "07ba14efc5908e5c")
        XCTAssertTrue(entries.contains(staging), "随包公钥表缺 staging 钥：\(entries)")
        XCTAssertFalse(entries.contains { $0.env == "test" }, "随包公钥表里有 env test：\(entries)")
        XCTAssertFalse(entries.contains { $0.kid == "n22-vector-test-key-1" }, "测试钥进了构建配置：\(entries)")
        let envs = Set(entries.map(\.env))
        XCTAssertTrue(envs.isSubset(of: ["staging", "prod"]), "Debug 只应有 staging / prod：\(entries)")
        let raw = Bundle.main.object(forInfoDictionaryKey: AppConfig.signKeysInfoKey) as? String
        XCTAssertTrue(raw?.contains("staging:\(Self.stagingKid):") == true, "Info.plist CouliConfigSignKeys 没接构建配置")
    }

    /// Release（及它 include 的 Base）只放生产钥：去掉注释后不得出现 staging / test 的 kid 与公钥；Release 的值只引用生产槽位。
    func testReleaseConfigCarriesNoNonProdKey() throws {
        let root = try repositoryRoot()
        let forbidden = [
            "staging", "config-staging", "test:", "n22-vector-test-key", "ae883f464888bece", try testKeyHex(),
        ]
        for name in ["Release", "Base"] {
            let code = stripComments(try String(contentsOf: root.appendingPathComponent("App/Config/\(name).xcconfig"),
                                                encoding: .utf8))
            for needle in forbidden {
                XCTAssertFalse(code.contains(needle), "\(name).xcconfig 出现了非生产的钥：\(needle)")
            }
        }
        let release = stripComments(try String(contentsOf: root.appendingPathComponent("App/Config/Release.xcconfig"),
                                               encoding: .utf8))
        XCTAssertEqual(settingValue("COULI_CONFIG_SIGN_KEYS", in: release), "$(COULI_CONFIG_SIGN_KEYS_PROD)")
        let base = stripComments(try String(contentsOf: root.appendingPathComponent("App/Config/Base.xcconfig"),
                                            encoding: .utf8))
        let prod = try XCTUnwrap(settingValue("COULI_CONFIG_SIGN_KEYS_PROD", in: base), "Base 缺生产槽位")
        for item in prod.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }) {
            XCTAssertTrue(item.hasPrefix("prod:"), "生产槽位里有非 prod 项：\(item)")
        }
    }

    /// 测试钥不得进任何构建配置；Info.plist 的键取 $(COULI_CONFIG_SIGN_KEYS)。
    func testTestKeyInNoBuildConfigAndPlistWired() throws {
        let root = try repositoryRoot()
        let testKeyHex = try testKeyHex()
        for path in ["App/Config/Base.xcconfig", "App/Config/Debug.xcconfig", "App/Config/Staging.xcconfig",
                     "App/Config/Release.xcconfig", "App/Info.plist"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(text.contains("n22-vector-test-key"), "\(path) 出现测试钥 kid")
            XCTAssertFalse(text.contains(testKeyHex), "\(path) 出现测试钥公钥")
        }
        let plist = try String(contentsOf: root.appendingPathComponent("App/Info.plist"), encoding: .utf8)
        let compact = plist.components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertTrue(compact.contains("<key>CouliConfigSignKeys</key><string>$(COULI_CONFIG_SIGN_KEYS)</string>"))
    }

    // MARK: - 验签闭包

    /// AppConfig 组装的闭包：appId 与 X-App-Id 同源；运行环境每次调用现取（切换环境后用新环境）；上次可用 version 原样传入。
    func testVerifierClosureReadsEnvironmentOnEveryCall() throws {
        XCTAssertEqual(AppNetwork.identity.appId, "couli")
        let signer = N22OriginsSigner()
        var env = "test"
        let verify = AppConfig.bridgeOriginsVerifier(
            appId: AppNetwork.identity.appId, signKeys: signer.keys, environmentId: { env }
        )
        let config = try signer.configObject(marker: "closure", version: 2, origins: [Self.testOrigin])
        let accepted = verify(config, nil)
        XCTAssertEqual(accepted?.origins, [Self.testOrigin])
        XCTAssertEqual(accepted?.version, 2)
        XCTAssertNotNil(verify(config, 2), "等于上次可用应通过")
        XCTAssertNil(verify(config, 3), "回退应拒")
        env = "staging"
        XCTAssertNil(verify(config, nil), "切到 staging 后仍按 test 验")
    }

    func testRuntimeEnvironmentIdFollowsExplicitSelection() {
        XCTAssertEqual(EnvironmentStore.runtimeEnvironmentId(defaults: defaults), "test", "Debug 构建默认 test")
        defaults.set("staging", forKey: AppNamespace.environmentSelectionKey)
        XCTAssertEqual(EnvironmentStore.runtimeEnvironmentId(defaults: defaults), "staging")
    }

    // MARK: - 端到端（生产 AppWeb 判定）

    func testProductionProtocolTrustsVerifiedOriginsAndKeepsLastGood() async throws {
        let app = make()
        let signer = N22OriginsSigner()
        let config = makeConfig(app, name: "e2e", keys: signer.keys, env: "test")
        let web = makeWeb(app, config: config)
        try await load(config, start: true, try signer.configText(marker: "m1", version: 4, origins: [Self.testOrigin]))
        XCTAssertTrue(web.productionProtocol().isTrustedOrigin(Self.testOrigin), "验签通过的源不可信")
        XCTAssertFalse(web.productionProtocol().isTrustedOrigin(Self.evilOrigin))

        // 同版本、签名坏：保留上次可用。
        let tampered = try signer.configText(marker: "m2", version: 4, origins: [Self.evilOrigin], tamper: true)
        try await load(config, tampered)
        XCTAssertTrue(web.productionProtocol().isTrustedOrigin(Self.testOrigin), "签名坏的文档冲掉了上次可用")
        XCTAssertFalse(web.productionProtocol().isTrustedOrigin(Self.evilOrigin), "签名坏的源进了白名单")

        // 阳性对照：新版本签名有效 → 换成新白名单（刷新链路确实在验签、在更新）。
        try await load(config, try signer.configText(marker: "m3", version: 5, origins: [Self.otherOrigin]))
        XCTAssertFalse(web.productionProtocol().isTrustedOrigin(Self.testOrigin))
        XCTAssertTrue(web.productionProtocol().isTrustedOrigin(Self.otherOrigin))
        XCTAssertEqual(config.store.trustedOriginsVersion, 5)
        withExtendedLifetime(web) {}
    }

    /// 新装机、服务端只回旧的字符串数组形状（没有签名）：不可信。
    func testFreshInstallWithLegacyArrayShapeTrustsNothing() async throws {
        let app = make()
        let config = makeConfig(app, name: "legacy", keys: N22OriginsSigner().keys, env: "test")
        let web = makeWeb(app, config: config)
        let legacy = try N22OriginsSigner.text([
            "dict_version": "legacy", "h5_base_url": Self.testOrigin + "/app", "bridge_origins": [Self.testOrigin],
        ])
        try await load(config, start: true, legacy)
        XCTAssertEqual(config.store.trustedOrigins, [])
        XCTAssertFalse(web.productionProtocol().isTrustedOrigin(Self.testOrigin), "未签名的数组形状被当成白名单")
        withExtendedLifetime(web) {}
    }

    /// 随包公钥表里没有测试钥：测试钥签的文档在真实构建配置下不可信。
    func testTestKeySignedConfigIsUntrustedWithBundledKeys() async throws {
        let app = make()
        let config = makeConfig(app, name: "bundled", keys: AppConfig.bundledSignKeys, env: "test")
        let text = try N22OriginsSigner().configText(marker: "bundled", version: 1, origins: [Self.testOrigin])
        try await load(config, start: true, text)
        XCTAssertEqual(config.store.trustedOrigins, [], "随包公钥表接受了测试钥")
    }

    // MARK: - staging 实测

    func testStagingLiveConfigTrustedWithBundledKeys() async throws {
        let app = make()
        let config = makeConfig(app, name: "stg", keys: AppConfig.bundledSignKeys, env: "staging")
        let web = makeWeb(app, config: config)
        try await load(config, start: true, try stagingLiveText())
        XCTAssertEqual(config.store.trustedOrigins, [Self.stagingOrigin])
        XCTAssertEqual(config.store.trustedOriginsVersion, 0)
        XCTAssertTrue(web.productionProtocol().isTrustedOrigin(Self.stagingOrigin))
        withExtendedLifetime(web) {}
    }

    /// 同一份 staging 文档在 test / prod 运行环境下不可用（钥与 env 都对不上）。
    func testStagingLiveConfigUntrustedOutsideStaging() async throws {
        let app = make()
        for env in ["test", "prod"] {
            let config = makeConfig(app, name: "stg-\(env)", keys: AppConfig.bundledSignKeys, env: env)
            try await load(config, start: true, try stagingLiveText())
            XCTAssertEqual(config.store.trustedOrigins, [], "staging 文档在 \(env) 运行环境被接受")
        }
    }
}

// MARK: - 工具

extension N22BridgeOriginsWiringTests {
    /// 测试钥（向量目录 n22-vector-test-key-1.pub.pem）SPKI DER 里公钥点 X 坐标的前 16 字节十六进制（现读 PEM 算，不抄常量）。
    func testKeyHex() throws -> String {
        let url = try repositoryRoot()
            .appendingPathComponent("Packages/Core/Tests/BridgeHostTests/Resources/N22/n22-vector-test-key-1.pub.pem")
        let body = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }.joined()
        let der = try XCTUnwrap(Data(base64Encoded: body), "测试钥 PEM 解不开")
        XCTAssertEqual(der.count, 91, "测试钥不是 P-256 SPKI")
        return der.dropFirst(27).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 生产 AppConfig（真实 ConfigStore、ConfigFetcher、验签闭包），只把公钥表、运行环境与 LKG 文件位置换成测试取值。
    func makeConfig(_ app: MeAppFixture, name: String, keys: ConfigSignKeys, env: String) -> AppConfig {
        AppConfig(
            client: app.network.client,
            file: ClientFile(name: "n22-\(name).json", baseDirectory: MeAppFixture.localDirectory(suiteName)),
            environmentRegistry: app.environmentSwitch, signKeys: keys, environmentId: { env }
        )
    }

    func makeWeb(_ app: MeAppFixture, config: AppConfig) -> AppWeb {
        let directory = MeAppFixture.localDirectory(suiteName)
        let tracker = AppTracker(
            privacy: app.routing.privacy, update: app.update, network: app.network,
            environmentReady: { true }, credentialsReadable: { app.runner.credentialsReadable },
            file: ClientFile(name: "n22-tracker.json", baseDirectory: directory),
            withdrawalRegistry: app.withdrawal, environmentRegistry: app.environmentSwitch
        )
        return AppWeb(
            config: config, network: app.network, routing: app.routing, privacy: app.routing.privacy,
            update: app.update, tracker: tracker,
            permissions: AppPermissions(file: ClientFile(name: "n22-permissions.json", baseDirectory: directory)),
            withdrawalRegistry: app.withdrawal, environmentRegistry: app.environmentSwitch
        )
    }

    /// 假服务回这一份配置 data，经生产入口拉取（start = 冷启动，否则回前台），等它成为生效配置。
    func load(_ config: AppConfig, start: Bool = false, _ data: String) async throws {
        let marker = try XCTUnwrap(N22OriginsSigner.object(data)["dict_version"] as? String, "配置缺 dict_version")
        script.ok("GET /v1/config", data)
        if start {
            config.startIfSettled(.settled)
        } else {
            config.store.onForeground()
        }
        await waitUntil("配置 \(marker) 没有成为生效配置") {
            (N22OriginsSigner.object(config.snapshotJson)["dict_version"] as? String) == marker
        }
    }

    func stagingLiveText() throws -> String {
        try N22OriginsSigner.text([
            "dict_version": "stg-live", "h5_base_url": Self.stagingOrigin,
            "bridge_origins": ["jws": try stagingLiveJws()],
        ])
    }

    /// 2026-11-22 staging 实测 /v1/config 的 bridge_origins.jws（向量 stg_live_ok，= N22-VECTORS/stg-live.jws）。
    func stagingLiveJws() throws -> String {
        let url = try repositoryRoot().appendingPathComponent(Self.vectorsPath)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "向量文件不是 JSON 对象"
        )
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]], "向量文件缺 cases")
        let live = try XCTUnwrap(cases.first { $0["name"] as? String == "stg_live_ok" }, "向量里没有 stg_live_ok")
        return try XCTUnwrap(live["jws"] as? String, "stg_live_ok 缺 jws")
    }

    func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { throw XCTSkip("找不到仓库根（contract.lock）") }
            directory = parent
        }
        return directory
    }

    /// 去掉 xcconfig 的 // 行注释。
    func stripComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let range = line.range(of: "//") else { return line }
            return line[..<range.lowerBound]
        }.joined(separator: "\n")
    }

    /// `NAME = value` 的值（去首尾空白）；没有为 nil。
    func settingValue(_ name: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

/// N-22 测试用 bridge_origins 签名钥（env test；私钥只在内存，不落盘、不进任何构建配置）。
/// BridgeDisabledMethodsWebTests 的 setConfig 也用它现签（#24 补丁）。
struct N22OriginsSigner {
    static let kid = "n22-apptests-fresh-key"
    let key = P256.Signing.PrivateKey()

    /// 只装这一把钥（env test）。
    var keys: ConfigSignKeys {
        ConfigSignKeys(derKeys: [(env: "test", kid: Self.kid, der: key.publicKey.derRepresentation)])
    }

    /// 现签 jws：header / payload 为 JSON 文本经 base64url，签名为 64 字节 R‖S；tamper 时改坏签名段首字符。
    func jws(version: Int, origins: [String], env: String = "test", tamper: Bool = false) throws -> String {
        let header = #"{"alg":"ES256","kid":"\#(Self.kid)","typ":"couli-bridge-origins+jws"}"#
        let payload = try Self.text(["v": 1, "app_id": "couli", "env": env, "version": version, "origins": origins])
        let input = Self.base64URL(Data(header.utf8)) + "." + Self.base64URL(Data(payload.utf8))
        var signature = Self.base64URL(try key.signature(for: Data(input.utf8)).rawRepresentation)
        if tamper {
            let swapped = signature.hasPrefix("A") ? "B" : "A"
            signature = swapped + signature.dropFirst()
        }
        return input + "." + signature
    }

    /// 配置 data（dict_version = marker，bridge_origins = {"jws": 现签}）的对象与文本。
    func configObject(marker: String, version: Int, origins: [String], tamper: Bool = false) throws -> [String: Any] {
        ["dict_version": marker, "bridge_origins": ["jws": try jws(version: version, origins: origins, tamper: tamper)]]
    }

    func configText(marker: String, version: Int, origins: [String], tamper: Bool = false) throws -> String {
        try Self.text(try configObject(marker: marker, version: version, origins: origins, tamper: tamper))
    }

    static func text(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return try XCTUnwrap(String(bytes: data, encoding: .utf8))
    }

    static func object(_ text: String) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]) ?? [:]
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
