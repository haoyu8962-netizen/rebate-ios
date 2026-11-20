@testable import Couli
import CouliNetwork
import Foundation
import Login
import Me
import MeCore
import Router
import XCTest

/// APP-13a-2-ios T1 设置入口 + D10-2203 ⑤（Release 入口用路由可用性 / since 关）+ brief §11 第 11 项（MeCore 号码规整与 Login 等价）。
/// 经真实 Router 打开设置页，点「账号与安全 → 手机号」用设置页渲染时的回调。
@MainActor
final class App13a2EntryTests: App13a2TestCase {
    /// T1（brief §1「入口」、G22）：phone_bound == true → 手机号行可点；点了进第 1 步子页，不压路由（导航栈仍只有 Settings），0 次请求。
    func testBoundRowOpensStep1SubPageWithoutRoute() async throws {
        let fixture = fixture()
        let settings = try await settings(fixture)
        let row = try phoneRow(settings)
        XCTAssertTrue(row.clickable, "已绑定 + 入口打开 → 可点")
        XCTAssertNil(row.route, "子页不注册路由（G22）")
        let pathBefore = fixture.router.path.map(\.route)
        SettingsActions.make(settings, settings.state).row(row)
        let controller = try XCTUnwrap(settings.phoneChange)
        XCTAssertEqual(settings.state.sub, .phoneChange)
        XCTAssertEqual(controller.state.step, .step1)
        await settle()
        XCTAssertEqual(fixture.router.path.map(\.route), pathBefore, "不压路由")
        XCTAssertTrue(stepSms.isEmpty, "进第 1 步不自动发码（【获取验证码】由用户点）")
        XCTAssertTrue(binds.isEmpty)
    }

    /// T1（G22，APP-10 第 24 条）：进入子页即作废设置页的导航许可——进入前取出的设置页回调（如「关于凑狸」）之后执行不导航。
    func testEnteringSubPageInvalidatesSettingsCallbacks() async throws {
        let fixture = fixture()
        let settings = try await settings(fixture)
        let stale = SettingsActions.make(settings, settings.state)
        let about = try XCTUnwrap(settings.model().groups.flatMap(\.rows).first { $0.id == SettingsItems.idAbout })
        SettingsActions.make(settings, settings.state).row(try phoneRow(settings))
        XCTAssertNotNil(settings.phoneChange)
        let depth = fixture.router.path.count
        stale.row(about)
        XCTAssertEqual(fixture.router.path.count, depth, "进子页前取出的设置页回调不再导航")
    }

    /// T1（零变化，G07）：phone_bound == false 仍去 BindPhone（入口打开也一样）。
    func testUnboundRowStillGoesToBindPhone() async throws {
        script.ok(Self.meRead, MeSamples.me(phoneBound: false))
        let fixture = fixture()
        let settings = try await settings(fixture)
        let row = try phoneRow(settings)
        XCTAssertTrue(row.clickable)
        XCTAssertEqual(row.route, "BindPhone")
        SettingsActions.make(settings, settings.state).row(row)
        XCTAssertNil(settings.phoneChange, "未绑定不建换号子页")
        XCTAssertNotEqual(settings.state.sub, .phoneChange)
    }

    /// T1（零变化）：phone_bound 未知（Me 没读到）→ 不可点，点了不建子页。
    func testUnknownPhoneBoundRowNotClickable() async throws {
        script.fail(Self.meRead, 50001)
        let fixture = fixture()
        let settings = try await settings(fixture)
        let row = try phoneRow(settings)
        XCTAssertFalse(row.clickable)
        SettingsActions.make(settings, settings.state).row(row)
        XCTAssertNil(settings.phoneChange)
    }

    /// T1（零变化，G22）：游客、基本模式没有手机号这一行。
    func testGuestAndBasicHaveNoPhoneRow() throws {
        for decision in ["consented", "basic_mode"] {
            let base = make(account: nil, decision: decision)
            base.router.open(RouteRequest(route: "Settings", from: .inApp))
            let top = try XCTUnwrap(base.router.path.last)
            let settings = try XCTUnwrap(base.me.entry(for: top)?.controller() as? SettingsController)
            let ids = settings.model().groups.flatMap(\.rows).map(\.id)
            XCTAssertFalse(ids.contains(SettingsItems.idPhone), "\(decision)：没有手机号行")
            base.router.path = []
        }
    }

    /// T1（G07、brief §1「入口」）：本账号有 bindPhone 的未决记录（首次绑定或换号留下的都算）→ 进入直接显示待确认，跳过第 1 步，0 次请求。
    func testPendingRecordShowsPendingDirectlyWithoutRequests() async throws {
        try seedUnknown(at: 1_763_600_000_000)
        let fixture = fixture()
        let (_, controller) = try await enter(fixture)
        await waitUntil("没有直接显示待确认") { controller.state.step == .pending }
        let card = try XCTUnwrap(controller.state.pending)
        XCTAssertEqual(card.key, "pc-seeded-key-0001")
        XCTAssertEqual(card.maskedPhone, Self.newMasked, "摘要只放本机脱敏的新号（G24）")
        XCTAssertEqual(card.submittedAtMillis, 1_763_600_000_000, "提交时间取记录的创建时刻")
        XCTAssertFalse(controller.submitEnabled, "表单置灰")
        XCTAssertTrue(stepSms.isEmpty, "跳过第 1 步：不发码")
        XCTAssertTrue(binds.isEmpty, "不自动确认")
        XCTAssertTrue(sent(Self.abandonWrite).isEmpty)
    }

    // MARK: - D10-2203 ⑤ Release 入口

    /// ⑤（守卫，桩上绿）：Release 判据——PhoneChangeEntry.sinceIOS 为 nil（B1-20b 部署 staging 前），任何版本都不可用（与 since 同一道闸）。
    func testReleaseGateClosedUntilSinceFilled() {
        XCTAssertNil(PhoneChangeEntry.sinceIOS, "B1-20b 上线前 since 为 nil（开门另开小单）")
        for version in ["1.0.0", "99.0.0", AppRouting.appVersion] {
            XCTAssertFalse(AppMe.phoneChangeReleaseAvailable(appVersion: version), version)
        }
    }

    /// ⑤（守卫，桩上绿）：没有 Debug 覆盖（= Release 判据）→ AppMe 报不可用；已绑定的手机号行保持不可点（与 me-vectors 现状一致），点了不建子页。
    func testWithoutOverrideBoundRowStaysClosed() async throws {
        let fixture = fixture(phoneChange: nil)
        XCTAssertFalse(fixture.me.phoneChangeAvailable())
        let settings = try await settings(fixture)
        let row = try phoneRow(settings)
        XCTAssertFalse(row.clickable, "Release：已绑定仍不可点")
        SettingsActions.make(settings, settings.state).row(row)
        XCTAssertNil(settings.phoneChange)
        XCTAssertNotEqual(settings.state.sub, .phoneChange)
    }

    /// ⑤：Debug 覆盖开关打开 → AppMe 报可用，行可点（照现有 Debug 启动参数开关写法；覆盖关闭 = false 时同 Release）。
    func testDebugOverrideOpensAndClosesEntry() async throws {
        let open = fixture(phoneChange: true)
        XCTAssertTrue(open.me.phoneChangeAvailable())
        let settings = try await settings(open)
        XCTAssertTrue(try phoneRow(settings).clickable)
        open.me.phoneChangeOverride = false
        XCTAssertFalse(open.me.phoneChangeAvailable())
        XCTAssertFalse(try phoneRow(settings).clickable, "覆盖关闭后按 Release 判据")
    }

    // MARK: - brief §11 第 11 项

    /// MeCore 的号码规整与脱敏与 Login 的 PhoneNumber 逐字一致（发码限流键、摘要、Done 都靠它，共性第 30 条）。
    func testMePhoneMatchesLoginPhoneNumber() {
        let inputs = [
            "13900001234", "+86 139 0000 1234", "+8613900001234", "0086 13900001234", "86 139-0000-1234",
            "139\u{2010}0000\u{2011}1234", "\u{FF11}\u{FF13}\u{FF19}00001234", " 139 0000 1234\u{3000}",
            "139\u{200B}00001234",
            "12900001234", "1390000123", "139000012345", "", "abc", "+85213900001234",
        ]
        for input in inputs {
            let login = PhoneNumber.normalize(input).normalized
            XCTAssertEqual(MePhone.normalize(input), login, "规整：\(input)")
            if let login {
                XCTAssertEqual(MePhone.masked(login), PhoneNumber.masked(login), "脱敏：\(input)")
            }
        }
        XCTAssertEqual(MePhone.masked("13900001234"), Self.newMasked)
    }
}
