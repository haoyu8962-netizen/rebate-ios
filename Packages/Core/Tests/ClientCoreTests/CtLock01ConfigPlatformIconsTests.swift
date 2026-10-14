import ClientCore
import Foundation
import Generated
import XCTest

/// CT-LOCK-01：`/v1/config` 新增可选 `platform_icons`（CT-17f）。ConfigStore 原样保存、不读取（不报坏数据、不显示替换图，
/// 下发接入归 F-X-05）；包内默认配置没有这个键（示例里是测试域名）。
final class CtLock01ConfigPlatformIconsTests: XCTestCase {
    private func makeStore(_ calls: Box, file: MemoryFile) -> ConfigStore {
        ConfigStore(
            readFile: file.read, writeFile: file.write,
            fetcher: { _, done in calls.done.append(done) },
            clock: { 1 }, bundled: DefaultConfig.json
        )
    }

    private final class Box {
        var done: [(ConfigReply) -> Void] = []
    }

    /// 快照里 GET /v1/config 的 200 响应示例 data（含 platform_icons）。
    private func exampleData() throws -> [String: Any] {
        let openapi = try ClientCoreFixtures.snapshotJSON("contracts/openapi.json")
        let paths = try XCTUnwrap(openapi["paths"] as? [String: Any])
        let get = try XCTUnwrap((paths["/v1/config"] as? [String: Any])?["get"] as? [String: Any])
        let ok = try XCTUnwrap((get["responses"] as? [String: Any])?["200"] as? [String: Any])
        let json = try XCTUnwrap((ok["content"] as? [String: Any])?["application/json"] as? [String: Any])
        let example = try XCTUnwrap(json["example"] as? [String: Any])
        return try XCTUnwrap(example["data"] as? [String: Any])
    }

    private func text(_ object: [String: Any]) throws -> String {
        try String(decoding: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func apply(_ data: [String: Any]) throws -> (ConfigStore, MemoryFile) {
        let calls = Box()
        let file = MemoryFile()
        let store = makeStore(calls, file: file)
        store.onColdStart()
        calls.done[0](ConfigReply(kindRaw: ConfigReply.ok, bodyJson: try text(data), etag: "e1"))
        return (store, file)
    }

    func testConfigWithPlatformIconsIsAppliedAndReadsTheSameAsWithout() throws {
        let data = try exampleData()
        XCTAssertNotNil(data["platform_icons"] as? [String: Any], "前提：快照示例带 platform_icons")
        var without = data
        without.removeValue(forKey: "platform_icons")

        let (store, file) = try apply(data)
        let (reference, _) = try apply(without)
        XCTAssertEqual(store.sourceRaw, ConfigStore.sourceCurrent, "带新字段的配置照常成为当前配置（不当坏数据丢弃）")
        XCTAssertNotNil(file.value, "照常写 LKG")
        XCTAssertTrue(file.value?.contains("platform_icons") ?? false, "不认识的键原样保存")
        for platform in ["taobao", "jd", "pdd"] {
            XCTAssertEqual(store.searchStatus(platform: platform), reference.searchStatus(platform: platform), platform)
            XCTAssertEqual(
                store.platformStatus(platform: platform),
                reference.platformStatus(platform: platform),
                platform
            )
        }
        XCTAssertEqual(store.linkPatternsJson, reference.linkPatternsJson)
        for key in ["features", "agent", "legal", "invite"] {
            XCTAssertEqual(store.value(key: key), reference.value(key: key), key)
        }
    }

    func testBundledDefaultConfigHasNoPlatformIcons() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(DefaultConfig.json.utf8)) as? [String: Any]
        )
        XCTAssertNil(object["platform_icons"])
        XCTAssertFalse(DefaultConfig.json.contains("example.test"))
    }
}
