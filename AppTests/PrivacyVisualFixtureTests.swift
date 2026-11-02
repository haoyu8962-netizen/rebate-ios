@testable import Couli
import CryptoKit
import Foundation
import MeCore
import XCTest

/// fixture 自身：三端同一份（与 Android e9fdd94 逐字节）、过生产规则、判据先正后反。底版就绿。
@MainActor
final class PrivacyVisualFixtureTests: XCTestCase {
    func testSameBytesAsAndroid() throws {
        let url = WalletVisualData.repo().appendingPathComponent("specs/privacy-visual-vectors.json")
        let digest = try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "9306dfda11365c910dce4829dd7fb7b7e7bb8ee10779093048f7a63826936605")
    }

    func testClockAndBoards() throws {
        let root = try PrivacyVisualData.root()
        XCTAssertEqual(root["clock"] as? String, "2026-10-12T10:30:00+08:00")
        let boards = try XCTUnwrap(root["boards"] as? [String: [String: Any]])
        XCTAssertEqual(boards.count, 13, "13 张画板（G-P01 两张标不对照）")
        XCTAssertEqual(boards.values.filter { $0["compare"] as? Bool == false }.count, 2)
    }

    /// 六种客服情形过生产 `CsEntryDecision`：半屏与按钮序列 = fixture。
    func testCsCasesMatchDecision() throws {
        let group = try XCTUnwrap(PrivacyVisualData.root()["cs"] as? [String: Any])
        let cases = try XCTUnwrap(group["cases"] as? [String: [String: Any]])
        XCTAssertEqual(cases.count, 6)
        for (name, setup) in cases {
            let kf: String? = switch setup["kf"] as? String {
            case "https": group["kf"] as? String
            case "http": group["kfInsecure"] as? String
            default: nil
            }
            let result = (setup["sheet"] as? String) == CsEntryDecision.openFailed ? "failed" : nil
            let decision = CsEntryDecision.model(kfUrl: kf, wechat: setup["wechat"] as? String ?? "unknown",
                                                 openResult: result)
            XCTAssertEqual(decision.sheetRaw, setup["sheet"] as? String, name)
            XCTAssertEqual(decision.buttons, setup["buttons"] as? [String], name)
        }
    }

    /// 判据先正后反。
    func testJudges() {
        let panel = CGRect(x: 0, y: 0, width: 390, height: 400)
        XCTAssertTrue(PrivacyVisualJudge.centered(CGRect(x: 145, y: 0, width: 100, height: 20), in: panel), "居中判过")
        XCTAssertFalse(PrivacyVisualJudge.centered(CGRect(x: 16, y: 0, width: 100, height: 20), in: panel), "靠左判不过")
        let title = CGRect(x: 100, y: 100, width: 100, height: 26)
        XCTAssertTrue(PrivacyVisualJudge.sameRow(title, CGRect(x: 340, y: 91, width: 44, height: 44)), "标题行判过")
        XCTAssertFalse(PrivacyVisualJudge.sameRow(title, CGRect(x: 340, y: 20, width: 44, height: 44)), "右上角判不过")
    }
}
