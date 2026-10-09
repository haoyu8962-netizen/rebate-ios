import BridgeHost
@testable import Couli
import Foundation
import XCTest

/// APP-07 brief §2.9：桥事件不带剪贴板内容（现状保持，补断言）。可信容器回前台 / 进后台下发的 app.resume / app.pause 用默认的空 data
/// （TrustedWebController.observeAppLifecycle → sendEvent(name:)）；事件信封里没有任何剪贴板字段。
@MainActor
final class ClipboardBridgeEventTests: XCTestCase {
    func testLifecycleEventsCarryEmptyData() throws {
        for name in ["app.resume", "app.pause"] {
            let body = try XCTUnwrap(BridgeProtocol.event(name: name), name)
            let envelope = try XCTUnwrap(AppWeb.object(body), body)
            let data = try XCTUnwrap(envelope["data"] as? [String: Any], body)
            XCTAssertTrue(data.isEmpty, "\(name) 的 data 是空对象：\(body)")
            XCTAssertFalse(body.lowercased().contains("clipboard"), body)
            XCTAssertFalse(body.contains("text"), body)
        }
    }
}
