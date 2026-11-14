@testable import ClientCore
import Foundation
import Generated
import XCTest

/// LOCK-ios 段 1（D10-1682 ①，03 §4.7「诊断字段」，events.yaml v6）：诊断字段取不到时一律是固定值 `unknown`，不留空。
/// config_version 取生效配置的 config_version；bridge_call 的 schema_version 取打包桥契约顶层 version。
final class LockIosEventDiagnosticsTests: XCTestCase {
    func testUnknownIsTheFixedWord() {
        XCTAssertEqual(EventDiagnostics.unknown, "unknown")
    }

    func testConfigVersionReadsNonEmptyString() {
        XCTAssertEqual(EventDiagnostics.configVersion(configJson: #"{"config_version":"cfg-42","flags":{}}"#), "cfg-42")
    }

    /// 包内默认配置（没有 config_version）、坏 JSON、空串、null、非字符串、数组根：都按 unknown。
    func testConfigVersionFallsBackToUnknown() {
        let cases = [
            "{}", "", "not json", "[]", #"{"config_version":""}"#, #"{"config_version":null}"#,
            #"{"config_version":7}"#, #"{"config_version":true}"#, #"{"flags":{"config_version":"nested"}}"#,
        ]
        for json in cases {
            XCTAssertEqual(EventDiagnostics.configVersion(configJson: json), "unknown", json)
        }
    }

    /// schema_version 等于快照 contracts/bridge.schema.json 的顶层 version（转成字符串），读得到就不是 unknown。
    func testBridgeSchemaVersionMatchesSnapshot() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            XCTAssertNotEqual(parent.path, directory.path, "找不到 contract.lock")
            if parent.path == directory.path {
                return
            }
            directory = parent
        }
        let url = directory.appendingPathComponent("contracts/snapshot/contracts/bridge.schema.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let version = try XCTUnwrap(root["version"] as? Int, "快照桥契约没有整数 version")
        XCTAssertEqual(EventDiagnostics.bridgeSchemaVersion, String(version))
        XCTAssertNotEqual(EventDiagnostics.bridgeSchemaVersion, "unknown")
    }

    /// 生成函数照四项诊断字段原样落事件（字段名按契约）。
    func testGeneratedBuildersCarryFourDiagnosticFields() {
        let bridge = TrackerEvents.bridgeCall(
            page: "WebPage", method: "x.y", code: 40301, schemaVersion: "s", bridgeVersion: "b", configVersion: "c",
            h5Release: "h"
        )
        let card = TrackerEvents.sduiCardError(
            page: "Home", type: "t", reason: "missing_version", schemaVersion: "s", bridgeVersion: "b",
            configVersion: "c", h5Release: "h"
        )
        for event in [bridge, card] {
            XCTAssertEqual(event.fields["schema_version"], .string("s"), event.name)
            XCTAssertEqual(event.fields["bridge_version"], .string("b"), event.name)
            XCTAssertEqual(event.fields["config_version"], .string("c"), event.name)
            XCTAssertEqual(event.fields["h5_release"], .string("h"), event.name)
            XCTAssertTrue(event.missingRequired.isEmpty, "\(event.name)：\(event.missingRequired)")
        }
    }
}
