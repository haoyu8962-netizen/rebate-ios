import CouliNetwork
import Foundation
import Generated
@testable import HomeCore
import XCTest

/// LOCK-ios 段 1（D10-1682 ①，03 §4.7「诊断字段」，events.yaml v6）：sdui_card_error 带齐 schema_version、bridge_version、
/// config_version、h5_release 四项；首页是原生页，bridge_version / h5_release 为 unknown；schema_version 取卡片自带 version，
/// 缺 version 时为 unknown；config_version 取 `HomeDeps.configVersion`，没注入（默认）为 unknown。
@MainActor
final class LockIosCardErrorDiagnosticsTests: HomeRigTestCase {
    private let diagnostics = ["schema_version", "bridge_version", "config_version", "h5_release"]

    private func reason(_ event: TrackEvent) -> String? {
        if case let .string(value)? = event.fields["reason"] {
            return value
        }
        return nil
    }

    func testCardErrorsCarryFourDiagnosticFieldsWithUnknownDefaults() async throws {
        _ = await show(try HomeVectors.golden("mixed_bad"))
        let errors = rig.cardErrors
        XCTAssertEqual(errors.count, 5, "前提：mixed_bad 发 5 条 sdui_card_error")
        for event in errors {
            let label = reason(event) ?? "?"
            for key in diagnostics {
                guard case let .string(value)? = event.fields[key] else {
                    XCTFail("\(label) 缺 \(key) 或不是字符串")
                    continue
                }
                XCTAssertFalse(value.isEmpty, "\(label).\(key) 不得为空串")
            }
            XCTAssertEqual(event.fields["bridge_version"], .string("unknown"), label)
            XCTAssertEqual(event.fields["h5_release"], .string("unknown"), label)
            XCTAssertEqual(event.fields["config_version"], .string("unknown"), "\(label)：没注入生效配置时为 unknown")
            if case let .integer(version)? = event.fields["version"] {
                XCTAssertEqual(
                    event.fields["schema_version"],
                    .string(String(version)),
                    "\(label)：schema_version 取卡片 version"
                )
            } else {
                XCTAssertEqual(
                    event.fields["schema_version"],
                    .string("unknown"),
                    "\(label)：缺 version 时 schema_version 为 unknown"
                )
            }
            XCTAssertTrue(event.missingRequired.isEmpty, "\(label)：\(event.missingRequired)")
        }
        let missingVersion = try XCTUnwrap(errors.first { reason($0) == "missing_version" })
        XCTAssertNil(missingVersion.fields["version"])
        XCTAssertEqual(missingVersion.fields["schema_version"], .string("unknown"))
        let unsupported = try XCTUnwrap(errors.first { reason($0) == "unsupported_version" })
        XCTAssertEqual(unsupported.fields["schema_version"], .string("2"))
    }

    func testConfigVersionComesFromInjectedEffectiveConfig() async throws {
        let mixed = try HomeVectors.golden("mixed_bad")
        try? rig.lkg.clearAll()
        rig.port?.setPage(HomeKit.ok(mixed))
        let base = rig.deps()
        let deps = HomeDeps(
            port: base.port, articles: base.articles, lkg: base.lkg, prefs: base.prefs, signals: base.signals,
            timers: base.timers, clock: base.clock, images: base.images, bundled: base.bundled,
            appVersion: base.appVersion, gate: base.gate, dedupe: base.dedupe, track: base.track,
            open: base.open, forceUpdate: base.forceUpdate, text: base.text, configVersion: { "cfg-42" }
        )
        let controller = HomeController(identity: HomeKit.memberA, deps: deps, preview: false)
        await rig.start(controller)
        let errors = rig.cardErrors
        XCTAssertEqual(errors.count, 5)
        for event in errors {
            XCTAssertEqual(event.fields["config_version"], .string("cfg-42"), reason(event) ?? "?")
        }
    }
}
