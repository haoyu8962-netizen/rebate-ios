import Foundation
@testable import MeCore
import XCTest

/// LOCK-ios（D10-1682 ①）：契约 d47f660e5 起 Me 带 masked_phone（服务端给的「前 3 后 4」），本端只认整串合规的值，其余一律为 nil。
final class LockIosMaskedPhoneTests: XCTestCase {
    private func masked(_ value: Any?, bound: Bool = true) -> String? {
        MeJson.maskedPhone(value.map { ["masked_phone": $0] as [String: Any] } ?? [:], phoneBound: bound)
    }

    func testWellFormedValueIsKept() {
        XCTAssertEqual(masked("138****8000"), "138****8000")
    }

    func testNotBoundIsNil() {
        XCTAssertNil(masked("138****8000", bound: false), "phone_bound=false 不显示任何号码")
    }

    func testMissingNullOrWrongTypeIsNil() {
        XCTAssertNil(masked(nil), "字段缺失（旧服务端）")
        XCTAssertNil(masked(NSNull()))
        XCTAssertNil(masked(13_800_008_000))
    }

    func testMalformedValuesAreNil() {
        for bad in [
            "13800008000", "138***8000", "138*****8000", "1380****8000", "138****800", "abc****8000",
            "138****8000\n", "\n138****8000", "138****8000\r", "138****8000\r\n", "138****8000\u{2028}",
            " 138****8000", "138****8000 ", "",
        ] {
            XCTAssertNil(masked(bad), "不合规：\(bad.debugDescription)")
        }
    }
}
