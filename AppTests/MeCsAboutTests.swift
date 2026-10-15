import Clipboard
@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import Router
import XCTest

/// 统一客服出口（AC-S1-88 ④、AC-S1-134 ④，G20）与关于页（AC-S1-136，G22、G23）。
@MainActor
final class MeCsAboutTests: MeTestCase {
    /// 未装微信 → CsWechatMissing，【复制客服链接】复制 kf.url 原串（统一写入口、台账有记录），【去帮助中心】→ Help；不直接打开链接。
    func testWechatMissingCopyAndHelp() async throws {
        let fixture = make()
        await fixture.loadConfig()
        fixture.system.wechat = "no"
        let controller = await fixture.enterMeTab()
        let cell = try XCTUnwrap(controller.view(fixture.me.deps.repo.state, masked: false).grid.first { $0.cs })
        MeTabActions.make(controller, fixture.me.deps.repo.state).tap(cell)
        let sheet = try XCTUnwrap(fixture.me.cs.sheet)
        XCTAssertEqual(sheet.decision.sheetRaw, CsEntryDecision.wechatMissing)
        CsActions.make(fixture.me.cs, sheet).copyLink()
        XCTAssertEqual(fixture.clipboard.last, MeSamples.kf, "复制的是 kf.url 原串")
        XCTAssertTrue(ClipboardWriteLedger(store: fixture.ledgerStore).contains(MeSamples.kf))
        XCTAssertEqual(fixture.me.cs.toast?.key, "cs.copy_link.done")
        XCTAssertTrue(fixture.system.opened.isEmpty, "不直接打开链接")
        CsActions.make(fixture.me.cs, sheet).goHelp()
        XCTAssertNil(fixture.me.cs.sheet)
        XCTAssertEqual(fixture.router.path.last?.route, "Help")
    }

    /// 检测未知 → CsHandoff，拉不起 → CsOpenFailed（【重试】【复制客服链接】【去帮助中心】）；kf 缺失 → 只有帮助中心。
    func testUnknownHandoffOpenFailedAndMissingKf() async throws {
        let fixture = make()
        await fixture.loadConfig()
        fixture.system.openResult = false
        fixture.me.cs.open(from: "Me")
        let sheet = try XCTUnwrap(fixture.me.cs.sheet)
        XCTAssertEqual(sheet.decision.sheetRaw, CsEntryDecision.handoff)
        CsActions.make(fixture.me.cs, sheet).openWechat()
        await waitUntil("没换成打不开") { fixture.me.cs.sheet?.decision.sheetRaw == CsEntryDecision.openFailed }
        XCTAssertEqual(fixture.system.opened, [MeSamples.kf])
        XCTAssertEqual(fixture.me.cs.sheet?.decision.buttons, ["retry", "copy_link", "go_help"])
        // 旧半屏的回调不再生效
        CsActions.make(fixture.me.cs, sheet).goHelp()
        XCTAssertNotNil(fixture.me.cs.sheet)

        let bare = make()
        bare.me.cs.open(from: "Me")
        XCTAssertEqual(bare.me.cs.sheet?.decision.sheetRaw, CsEntryDecision.helpOnly, "kf 缺失")
    }

    /// 两个账号从同一页打开的链接逐字相同，不含 uid、手机号、device_id、邀请码、令牌。
    func testLinkSameForTwoAccounts() async throws {
        let fixture = make()
        await fixture.loadConfig()
        fixture.system.wechat = "no"
        fixture.me.cs.open(from: "Me")
        let first = fixture.me.cs.sheet?.decision.copyText
        try fixture.switchAccount(to: "user-b")
        await waitUntil("没换代") { fixture.me.currentIdentity.account == "user-b" }
        fixture.me.cs.open(from: "Me")
        XCTAssertEqual(fixture.me.cs.sheet?.decision.copyText, first)
        let link = try XCTUnwrap(first)
        for forbidden in ["user-a", "user-b", "device-fixture", "K7M3QX", "at-", "Me"] where forbidden != "Me" {
            XCTAssertFalse(link.contains(forbidden), forbidden)
        }
    }

    /// 已有「联系客服 → Help」占位改走统一出口：登录页、授权管理、钱包、订单详情。
    func testPlaceholdersReplaced() {
        let fixture = make()
        fixture.login.pageConfig(restricted: false).onCustomerService()
        XCTAssertEqual(fixture.me.cs.sheet?.fromRoute, "Login")
        XCTAssertNotEqual(fixture.router.path.last?.route, "Help")
    }

    /// AC-S1-136：复制诊断信息只含白名单字段（device_id 只留后 6 位），不含任何令牌、完整 device_id、手机号、uid；走统一写入口。
    func testDiagnosticsAllowedFieldsOnly() async throws {
        let fixture = make(pushToken: "secret-token")
        await fixture.loadConfig()
        let entry = try XCTUnwrap(fixture.open("About"))
        let controller = try XCTUnwrap(entry.controller() as? AboutController)
        XCTAssertEqual(controller.filing, "测试模型名称\n测试登记编号：TEST-001")
        controller.copyDiagnostics()
        let text = try XCTUnwrap(fixture.clipboard.last)
        XCTAssertTrue(text.contains("device_id_tail: e-0001"))
        for forbidden in ["device-fixture-0001", "user-a", "at-user-a", "rt-user-a", "secret-token", "install"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertTrue(ClipboardWriteLedger(store: fixture.ledgerStore).contains(text), "台账有记录：回前台不识别")
        XCTAssertEqual(controller.toast?.key, "about.copy_diagnostics.done")
    }
}
