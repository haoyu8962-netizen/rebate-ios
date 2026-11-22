import BridgeHost
import ClientCore
import CryptoKit
import Foundation
import Generated
import XCTest

/// N-22（D10-2539）：ConfigStore 的「上次可用白名单」（trustedOrigins / trustedOriginsVersion，随 LKG 的
/// `bridge_origins_last_good` 保存）。验签闭包接 BridgeHost 的真验签器（ClientCoreTests 依赖 BridgeHost），钥是测试里现生成的
/// P-256 钥（env test）；闭包同时记下每次收到的 lastGoodVersion。拉取经手动结算的假 fetcher，文件是内存文件。
final class ConfigStoreBridgeOriginsTests: XCTestCase {
    private final class ManualFetcher {
        var calls: [(etag: String?, done: (ConfigReply) -> Void)] = []
    }

    private final class VerifyLog {
        var lastGoodVersions: [Int?] = []
    }

    private struct Harness {
        let store: ConfigStore
        let fetcher: ManualFetcher
        let file: MemoryFile
        let log: VerifyLog

        /// 结算最近发出的那次拉取。
        func respond(_ reply: ConfigReply) throws {
            let call = try XCTUnwrap(fetcher.calls.last, "没有在途拉取")
            call.done(reply)
        }
    }

    private let signer = OriginsSigner()
    private let originA = "https://h5-test.couliapp.cn"
    private let originB = "https://b.example.test:8443"

    private func makeHarness(file: MemoryFile = MemoryFile(), env: String = "test") -> Harness {
        let fetcher = ManualFetcher()
        let log = VerifyLog()
        let keys = signer.keys
        let store = ConfigStore(
            readFile: file.read, writeFile: file.write,
            fetcher: { etag, done in fetcher.calls.append((etag, done)) },
            clock: { 1 }, bundled: DefaultConfig.json,
            verifyBridgeOrigins: { config, lastGood in
                log.lastGoodVersions.append(lastGood)
                let verdict = BridgeOriginsVerifier.verify(
                    config: config, appId: "couli", env: env, lastGoodVersion: lastGood, keys: keys
                )
                guard case let .accepted(allowlist) = verdict else {
                    return nil
                }
                return (allowlist.version, allowlist.origins)
            }
        )
        return Harness(store: store, fetcher: fetcher, file: file, log: log)
    }

    // MARK: - 200 新配置

    func testAcceptedConfigBecomesTrustedAndIsPersisted() throws {
        let harness = makeHarness()
        var seen: [[String]] = []
        let token = harness.store.observe { seen.append($0.trustedOrigins) }
        harness.store.onColdStart()
        XCTAssertEqual(harness.store.trustedOrigins, [], "没有 LKG 时为空")
        try harness.respond(ok(try document("m1", version: 3, origins: [originA]), etag: "e1"))
        XCTAssertEqual(harness.store.trustedOrigins, [originA])
        XCTAssertEqual(harness.store.trustedOriginsVersion, 3)
        XCTAssertNil(try XCTUnwrap(harness.log.lastGoodVersions.last, "验签闭包没被调用"), "首次没有上次可用")
        let saved = try XCTUnwrap(lastGood(in: harness.file), "LKG 文件缺 bridge_origins_last_good")
        XCTAssertEqual(saved["version"] as? Int, 3)
        XCTAssertEqual(saved["origins"] as? [String], [originA])
        XCTAssertEqual(seen.last, [originA], "白名单变化要通知订阅者")
        token.cancel()
    }

    /// 签名坏的新文档：配置照常生效，但白名单保留上次可用，LKG 文件里也仍是旧的上次可用；重启后读到的也是旧的。
    func testBadSignatureKeepsLastGoodInMemoryAndFile() throws {
        let harness = try acceptedHarness(version: 3, origins: [originA])
        harness.store.onForeground()
        try harness.respond(ok(try document("m2", version: 4, origins: [originB], tamper: true)))
        XCTAssertTrue(harness.store.snapshotJson.contains("m2"), "新文档本身应生效（只有白名单不换）")
        XCTAssertEqual(harness.store.trustedOrigins, [originA], "验不过的值进了白名单")
        XCTAssertEqual(harness.store.trustedOriginsVersion, 3)
        XCTAssertTrue(harness.file.value?.contains("m2") == true, "LKG 文件应已写入新文档")
        let saved = try XCTUnwrap(lastGood(in: harness.file), "LKG 文件丢了上次可用")
        XCTAssertEqual(saved["version"] as? Int, 3, "失败值写成了上次可用")
        XCTAssertEqual(saved["origins"] as? [String], [originA], "失败值写成了上次可用")

        let restarted = makeHarness(file: harness.file)
        restarted.store.onColdStart()
        XCTAssertEqual(restarted.store.trustedOrigins, [originA], "重启后应读回旧的上次可用")
        XCTAssertEqual(restarted.store.trustedOriginsVersion, 3)
    }

    /// 回退（签名有效但 version 小于上次可用）：拒，闭包收到的 lastGoodVersion 是当前上次可用的 version。
    func testRollbackKeepsLastGood() throws {
        let harness = try acceptedHarness(version: 3, origins: [originA])
        harness.store.onForeground()
        try harness.respond(ok(try document("m2", version: 2, origins: [originB])))
        XCTAssertEqual(try XCTUnwrap(harness.log.lastGoodVersions.last), 3, "验新文档要带当前上次可用的 version")
        XCTAssertEqual(harness.store.trustedOrigins, [originA], "回退的值进了白名单")
        XCTAssertEqual(harness.store.trustedOriginsVersion, 3)
        XCTAssertEqual(try XCTUnwrap(lastGood(in: harness.file))["version"] as? Int, 3)
    }

    func testEqualVersionAcceptedAndHigherVersionReplaces() throws {
        let harness = try acceptedHarness(version: 3, origins: [originA])
        harness.store.onForeground()
        try harness.respond(ok(try document("m2", version: 3, origins: [originA, originB])))
        XCTAssertEqual(harness.store.trustedOrigins, [originA, originB], "版本相等算通过")
        harness.store.onForeground()
        try harness.respond(ok(try document("m3", version: 5, origins: [originB])))
        XCTAssertEqual(harness.store.trustedOrigins, [originB])
        XCTAssertEqual(harness.store.trustedOriginsVersion, 5)
        XCTAssertEqual(try XCTUnwrap(lastGood(in: harness.file))["origins"] as? [String], [originB])
    }

    /// 从来没有上次可用时验不过：白名单为空，LKG 文件里不得出现失败值；重启后现验仍不过，仍为空。
    func testFirstFailureWritesNoLastGood() throws {
        let harness = makeHarness()
        harness.store.onColdStart()
        try harness.respond(ok(try document("m1", version: 3, origins: [originA], tamper: true)))
        XCTAssertTrue(harness.store.snapshotJson.contains("m1"))
        XCTAssertEqual(harness.store.trustedOrigins, [])
        XCTAssertNil(harness.store.trustedOriginsVersion)
        if let saved = lastGood(in: harness.file) {
            XCTAssertNotEqual(saved["origins"] as? [String], [originA], "失败值写成了上次可用")
        }
        let restarted = makeHarness(file: harness.file)
        restarted.store.onColdStart()
        XCTAssertEqual(restarted.store.trustedOrigins, [], "重启后把没验过的文档当成了白名单")
    }

    // MARK: - 冷启动读 LKG

    func testColdStartUsesPersistedLastGood() throws {
        let file = MemoryFile()
        file.value = try lkgText(data: placeholderData, lastGood: ["version": 7, "origins": [originA]])
        let harness = makeHarness(file: file)
        harness.store.onColdStart()
        XCTAssertEqual(harness.store.trustedOrigins, [originA], "带字段的 LKG 应直接可用")
        XCTAssertEqual(harness.store.trustedOriginsVersion, 7)
        try harness.respond(ok(try document("m1", version: 6, origins: [originB])))
        XCTAssertEqual(try XCTUnwrap(harness.log.lastGoodVersions.last), 7, "回退基准应是 LKG 里的 version")
        XCTAssertEqual(harness.store.trustedOrigins, [originA], "低于 LKG 上次可用的版本被接受")
        harness.store.onForeground()
        try harness.respond(ok(try document("m2", version: 7, origins: [originB])))
        XCTAssertEqual(harness.store.trustedOrigins, [originB])
    }

    /// 升级前的旧 LKG（没有 bridge_origins_last_good）：用 LKG 文档现验一次（lastGoodVersion = nil），通过才用。
    func testLegacyLKGIsVerifiedBeforeUse() throws {
        let file = MemoryFile()
        file.value = try lkgText(data: try object(try document("lkg", version: 2, origins: [originA])))
        let harness = makeHarness(file: file)
        harness.store.onColdStart()
        XCTAssertEqual(harness.store.trustedOrigins, [originA])
        XCTAssertEqual(harness.store.trustedOriginsVersion, 2)
        XCTAssertTrue(harness.log.lastGoodVersions.contains(nil), "旧 LKG 现验应不带上次可用")
    }

    func testLegacyLKGThatFailsVerificationIsUntrusted() throws {
        let valid = try object(try document("lkg", version: 2, origins: [originA]))
        let legacies: [(label: String, data: [String: Any])] = [
            ("签名坏", try object(try document("lkg", version: 2, origins: [originA], tamper: true))),
            ("旧的字符串数组形状", ["dict_version": "lkg", "bridge_origins": [originA]]),
            ("包内占位 jws", placeholderData),
            // 签名有效、env=test 的文档，在 staging 运行环境下读到（见下面 env 的取法）。
            ("环境不符", valid),
        ]
        for (label, data) in legacies {
            let file = MemoryFile()
            file.value = try lkgText(data: data)
            let harness = makeHarness(file: file, env: label == "环境不符" ? "staging" : "test")
            harness.store.onColdStart()
            XCTAssertEqual(harness.store.sourceRaw, ConfigStore.sourceLKG, "\(label)：LKG 应被读到")
            XCTAssertEqual(harness.store.trustedOrigins, [], "\(label)：没验过的旧 LKG 被当成白名单")
            XCTAssertNil(harness.store.trustedOriginsVersion, label)
        }
    }

    /// 字段存在但形状不完整：不当作上次可用（文档本身是包内占位 jws，现验也不过 → 空）。
    func testIncompletePersistedFieldIsNotTrusted() throws {
        let fields: [[String: Any]] = [
            ["version": "7", "origins": [originA]], ["version": 7], ["origins": [originA]],
            ["version": 7, "origins": originA], ["version": 7, "origins": [7]],
        ]
        for field in fields {
            let file = MemoryFile()
            file.value = try lkgText(data: placeholderData, lastGood: field)
            let harness = makeHarness(file: file)
            harness.store.onColdStart()
            XCTAssertEqual(harness.store.trustedOrigins, [], "形状不完整的上次可用被采用：\(field)")
        }
    }

    // MARK: - 环境切换、包内默认、304

    func testEnvironmentSwitchClearsTrustAndRollbackBaseline() throws {
        let harness = try acceptedHarness(version: 3, origins: [originA])
        try harness.store.clearForEnvironmentSwitch()
        XCTAssertEqual(harness.store.trustedOrigins, [])
        XCTAssertNil(harness.store.trustedOriginsVersion)
        XCTAssertNil(harness.file.value, "LKG 文件应已删除")
        harness.store.onColdStart()
        XCTAssertEqual(harness.store.trustedOrigins, [], "切换后不得复活旧白名单")
        try harness.respond(ok(try document("m2", version: 1, origins: [originB])))
        XCTAssertNil(try XCTUnwrap(harness.log.lastGoodVersions.last), "切换后回退基准应清空")
        XCTAssertEqual(harness.store.trustedOrigins, [originB], "新环境里低版本也应可用")
    }

    func testBundledDefaultIsUntrusted() throws {
        let harness = makeHarness()
        XCTAssertEqual(harness.store.trustedOrigins, [])
        harness.store.onColdStart()
        try harness.respond(ConfigReply(kindRaw: ConfigReply.failure, bodyJson: nil, etag: nil))
        XCTAssertEqual(harness.store.sourceRaw, ConfigStore.sourceBundled)
        XCTAssertTrue(harness.store.snapshotJson.contains("bridge_origins"), "包内默认应带占位 bridge_origins")
        XCTAssertEqual(harness.store.trustedOrigins, [], "包内占位 jws 被当成了白名单")
        XCTAssertNil(harness.store.trustedOriginsVersion)
    }

    func test304AndFailureKeepTrust() throws {
        let harness = try acceptedHarness(version: 3, origins: [originA])
        harness.store.onForeground()
        try harness.respond(ConfigReply(kindRaw: ConfigReply.notModified, bodyJson: nil, etag: "e1"))
        XCTAssertEqual(harness.store.trustedOrigins, [originA], "304 改了白名单")
        XCTAssertEqual(harness.store.trustedOriginsVersion, 3)
        harness.store.onForeground()
        try harness.respond(ConfigReply(kindRaw: ConfigReply.failure, bodyJson: nil, etag: nil))
        XCTAssertEqual(harness.store.trustedOrigins, [originA], "拉取失败改了白名单")
    }
}

// MARK: - 工具

extension ConfigStoreBridgeOriginsTests {
    /// 冷启动并收下一份签名有效的配置（ETag e1）；断言它已成为上次可用（前置条件，桩上会在这里红）。
    private func acceptedHarness(version: Int, origins: [String]) throws -> Harness {
        let harness = makeHarness()
        harness.store.onColdStart()
        try harness.respond(ok(try document("m1", version: version, origins: origins), etag: "e1"))
        XCTAssertEqual(harness.store.trustedOrigins, origins, "前置：签名有效的配置没有成为上次可用")
        return harness
    }

    private var placeholderData: [String: Any] {
        ["dict_version": "lkg", "bridge_origins": ["jws": "aGVhZGVy.cGF5bG9hZA.c2lnbmF0dXJl"]]
    }

    private func ok(_ body: String, etag: String? = nil) -> ConfigReply {
        ConfigReply(kindRaw: ConfigReply.ok, bodyJson: body, etag: etag)
    }

    /// 一份配置 data：dict_version = marker，bridge_origins = {"jws": 现签}；tamper 时改坏签名段首字符。
    private func document(_ marker: String, version: Int, origins: [String], tamper: Bool = false) throws -> String {
        var jws = try signer.jws(version: version, origins: origins)
        if tamper, let dot = jws.lastIndex(of: ".") {
            let first = jws.index(after: dot)
            let swapped: String = jws[first] == "A" ? "B" : "A"
            jws.replaceSubrange(first...first, with: swapped)
        }
        return try text(["dict_version": marker, "bridge_origins": ["jws": jws]])
    }

    private func lkgText(data: [String: Any], lastGood: [String: Any]? = nil) throws -> String {
        var root: [String: Any] = ["v": 1, "etag": "lkg-etag", "saved_at": 1, "data": data]
        if let lastGood {
            root["bridge_origins_last_good"] = lastGood
        }
        return try text(root)
    }

    private func lastGood(in file: MemoryFile) -> [String: Any]? {
        guard let value = file.value, let root = try? object(value) else {
            return nil
        }
        return root["bridge_origins_last_good"] as? [String: Any]
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], "不是 JSON 对象")
    }

    private func text(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(bytes: data, encoding: .utf8))
    }
}

/// 测试里现生成的 bridge_origins 签名钥（env test；私钥只在内存）。
private struct OriginsSigner {
    let key = P256.Signing.PrivateKey()
    let kid = "n22-clientcore-fresh-key"

    var keys: ConfigSignKeys {
        ConfigSignKeys(derKeys: [(env: "test", kid: kid, der: key.publicKey.derRepresentation)])
    }

    func jws(version: Int, origins: [String], env: String = "test") throws -> String {
        let header = #"{"alg":"ES256","kid":"\#(kid)","typ":"couli-bridge-origins+jws"}"#
        let payload: [String: Any] = ["v": 1, "app_id": "couli", "env": env, "version": version, "origins": origins]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        let input = Self.base64URL(Data(header.utf8)) + "." + Self.base64URL(body)
        let signature = try key.signature(for: Data(input.utf8))
        return input + "." + Self.base64URL(signature.rawRepresentation)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
