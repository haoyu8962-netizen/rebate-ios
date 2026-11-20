import Foundation
import Generated
@testable import MeCore
import XCTest

/// APP-13a-2-ios（MeCore 层）：号码规整与脱敏（brief §11 第 11 项，BR-ID-05 细则「手机号规范化」）、本单的两个草稿键（brief §3）、Release 入口闸
/// （D10-2203 ⑤）的缺省、SettingsItems 输出零变化（brief §2：me-vectors.json:41 / :45 不动，手机号行在上层覆盖）。
final class App13a2PhoneChangeCoreTests: XCTestCase {
    /// brief §11 第 11 项：MeCore 的规整（与 Login PhoneNumber 同一规格；App 层另有逐字对照）。
    func testNormalizeFollowsBrIdSpec() {
        let ok = [
            "13900001234", "+86 139 0000 1234", "+8613900001234", "0086 13900001234", "86 13900001234",
            "139-0000-1234", "\u{FF11}\u{FF13}\u{FF19}\u{FF10}\u{FF10}\u{FF10}\u{FF10}1234",
            "139\u{200B}0000\u{00A0}1234",
        ]
        for raw in ok {
            XCTAssertEqual(MePhone.normalize(raw), "13900001234", raw)
        }
        for bad in ["", "1390000123", "139000012345", "12900001234", "abcdefghijk", "+852 13900001234"] {
            XCTAssertNil(MePhone.normalize(bad), bad)
        }
    }

    /// BR-ID-33：11 位 → 前 3 后 4；其余原样。
    func testMasked() {
        XCTAssertEqual(MePhone.masked("13900001234"), "139****1234")
        XCTAssertEqual(MePhone.masked("1390000"), "1390000")
    }

    /// brief §3：本单新草稿键（与安卓 / 鸿蒙同句），放在 AccountDraftTexts、契约字典里没有（TODO(N-37)）。
    func testDraftKeys() {
        let texts = AccountDraftTexts()
        XCTAssertEqual(texts.text("step_up.title.phone_change"), "为保障账号安全，请先验证当前手机号")
        XCTAssertEqual(texts.text("phone_change.current_hint"), "验证码将发送至你绑定的手机号")
        for key in ["step_up.title.phone_change", "phone_change.current_hint"] {
            XCTAssertNil(DefaultTexts.text(key), "\(key) 是草稿键，不是契约键")
            XCTAssertNotNil(AccountDraftTexts.drafts[key], key)
        }
    }

    /// D10-2203 ⑤（守卫）：Release 闸 since 为 nil；没接的环境缺省不可用。
    @MainActor
    func testEntryClosedByDefault() {
        XCTAssertNil(PhoneChangeEntry.sinceIOS)
        XCTAssertFalse(DetachedMeEnv.shared.phoneChangeAvailable())
    }

    /// brief §2（零变化）：SettingsItems.model 的手机号行照旧——已绑定不可点、未绑定 → BindPhone、未知不可点（换号入口在上层覆盖）。
    func testSettingsItemsPhoneRowUnchanged() {
        func row(_ bound: Bool?) -> SettingsRow? {
            SettingsItems.model(
                level: MeLevel.member, platform: MePlatform.ios, phoneBound: bound, nicknameEditable: true,
                serviceSwitchAvailable: true, deleteAccountAvailable: false
            ).groups.flatMap(\.rows).first { $0.id == SettingsItems.idPhone }
        }
        XCTAssertEqual(row(true)?.clickable, false)
        XCTAssertNil(row(true)?.route)
        XCTAssertEqual(row(false)?.clickable, true)
        XCTAssertEqual(row(false)?.route, "BindPhone")
        XCTAssertEqual(row(nil)?.clickable, false)
    }
}
