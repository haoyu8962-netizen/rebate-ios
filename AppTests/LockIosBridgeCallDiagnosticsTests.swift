import BridgeHost
import ClientCore
@testable import Couli
import Foundation
import Generated
import XCTest

/// LOCK-ios 段 1（D10-1682 ①，03 §4.7「诊断字段」，D10-1612 ④ (i)）：桥调用被拒的 bridge_call（`AppBridgeServices.rejectedEvent`）
/// 带齐四项诊断字段：schema_version = 打包桥契约顶层 version；bridge_version = app.getEnv 同源的 `BridgeProtocol.contractVersion`；
/// config_version = 生效配置的 config_version，取不到为 unknown；h5_release 原生取不到，固定 unknown。
@MainActor
final class LockIosBridgeCallDiagnosticsTests: XCTestCase {
    private func snapshotBridgeVersion() throws -> Int {
        let url = WalletVisualData.repo().appendingPathComponent("contracts/snapshot/contracts/bridge.schema.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(root["version"] as? Int, "快照桥契约没有整数 version")
    }

    func testRejectedEventCarriesFourDiagnosticFields() throws {
        let event = AppBridgeServices.rejectedEvent(
            method: "share.open", code: 40301, configJson: #"{"config_version":"cfg-9"}"#
        )
        XCTAssertEqual(event.name, "bridge_call")
        XCTAssertEqual(event.page, AppWeb.page)
        XCTAssertTrue(event.missingRequired.isEmpty, "\(event.missingRequired)")
        XCTAssertEqual(event.fields["method"], .string("share.open"))
        XCTAssertEqual(event.fields["code"], .integer(40301))
        let version = String(try snapshotBridgeVersion())
        XCTAssertEqual(event.fields["schema_version"], .string(version), "schema_version 取打包桥契约的 version")
        XCTAssertEqual(event.fields["bridge_version"], .string(String(BridgeProtocol.contractVersion)))
        XCTAssertEqual(event.fields["bridge_version"], .string(version), "bridge_version 与 app.getEnv 同源")
        XCTAssertEqual(event.fields["config_version"], .string("cfg-9"))
        XCTAssertEqual(event.fields["h5_release"], .string("unknown"))
    }

    func testRejectedEventFallsBackToUnknownWhenConfigHasNoVersion() {
        for json in ["{}", "", "broken", #"{"config_version":""}"#, #"{"config_version":3}"#] {
            let event = AppBridgeServices.rejectedEvent(method: "app.getEnv", code: 40301, configJson: json)
            XCTAssertEqual(event.fields["config_version"], .string("unknown"), json)
            XCTAssertEqual(event.fields["h5_release"], .string("unknown"), json)
            for key in ["schema_version", "bridge_version"] {
                guard case let .string(value)? = event.fields[key] else {
                    XCTFail("\(json)：缺 \(key)")
                    continue
                }
                XCTAssertFalse(value.isEmpty, "\(json)：\(key) 不得为空串")
            }
        }
    }

    /// 字段只有 method、code 与四项诊断字段（不带链接、参数等别的东西）。
    func testRejectedEventFieldSetIsExact() {
        let event = AppBridgeServices.rejectedEvent(method: "nav.open", code: 40301, configJson: "{}")
        XCTAssertEqual(
            Set(event.fields.keys),
            ["method", "code", "schema_version", "bridge_version", "config_version", "h5_release"]
        )
    }
}
