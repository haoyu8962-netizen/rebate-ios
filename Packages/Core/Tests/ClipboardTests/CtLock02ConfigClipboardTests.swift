@testable import Clipboard
import Foundation
import XCTest

/// CT-LOCK-02：openapi Config.clipboard 由 FreeForm 改为 ConfigClipboard（只定了 consent_version，其余原样透传）。
/// 本端规则仍不按猜测的键名解析（TODO(N-30) G02）：带 consent_version 的下发值与空对象、缺省得到同一套包内默认规则。
final class CtLock02ConfigClipboardTests: XCTestCase {
    func testTypedClipboardBlockStillYieldsBundledRules() {
        XCTAssertEqual(ClipboardRules.fromConfig(["consent_version": "2026-10-01"]), ClipboardRules.defaults)
        XCTAssertEqual(ClipboardRules.fromConfig([String: Any]()), ClipboardRules.defaults)
        XCTAssertEqual(ClipboardRules.fromConfig(nil), ClipboardRules.defaults)
    }
}
