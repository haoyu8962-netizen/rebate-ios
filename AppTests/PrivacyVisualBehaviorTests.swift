@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import Router
import XCTest

/// 行为（brief §4 第 4、5 条）：每个入口恰好一次、目标与改前一致、取消 / 关闭零动作、旧回调零动作、请求不变。底版就该绿（红线逐条在 `PrivacyVisualRedLineTests`）。
@MainActor
final class PrivacyVisualBehaviorTests: PrivacyVisualTestCase {
    private var nonConfigRequests: [String] {
        WalletStubProtocol.requests.map { "\($0.method) \($0.path)" }.filter { $0 != "GET /v1/config" }
    }

    /// 四行去向：收集清单、隐私政策同开 privacy（G-P19），共享清单 sdk_list，用户协议 agreement；每点一次恰好一条。
    func testDocumentRowsOpenAgreementOnce() async throws {
        try await openPrivacy()
        let router = try XCTUnwrap(page).fixture.router
        for type in ["privacy", "sdk_list", "privacy", "agreement"] {
            let before = router.path.count
            try centerActions.document(type)
            XCTAssertEqual(router.path.count, before + 1, type)
            XCTAssertEqual(router.path.last?.route, "Agreement", type)
            XCTAssertEqual(router.path.last?.params["type"], JSONValue.string(type), type)
            // 栈顶同名路由 Router 不重复压栈（`showOpened`）：用户实际是返回后再点下一行
            router.path.removeLast()
        }
    }

    /// 个性化：本机先保存 + recordConsent 一次（字段不变）；同值不再发。
    func testPersonalizationSavesThenRecordsOnce() async throws {
        try await openPrivacy()
        let local = try XCTUnwrap(page).fixture.local
        let actions = try centerActions
        actions.personalization(false)
        XCTAssertFalse(local.personalizationOn, "本机先保存")
        await waitUntil("同意记录没发") { self.consentRecords == 1 }
        actions.personalization(false)
        await settle()
        XCTAssertEqual(consentRecords, 1, "同一版本回调不重发")
        let body = try XCTUnwrap(WalletStubProtocol.requests("POST", "/v1/consents").first).json
        XCTAssertEqual(body["type"] as? String, "personalization")
        XCTAssertEqual(body["accepted"] as? Bool, false)
        XCTAssertEqual(body["channel"] as? String, "privacy_center")
    }

    /// 游客（设备未注册）：只记本地，不发。
    func testUnregisteredGuestStaysLocal() async throws {
        try await openPrivacy(Scene(session: "privacy_guest"))
        try centerActions.personalization(false)
        await settle()
        XCTAssertFalse(try XCTUnwrap(page).fixture.local.personalizationOn)
        XCTAssertEqual(consentRecords, 0)
    }

    /// 进入隐私中心零请求（配置另计；Settings 底页的 getMe 已在进入前发生）；关于、客服零请求。
    func testEnteringPagesAddsNoRequest() async throws {
        let host = try await prepare(Scene())
        await quietWindow(0.3)
        let before = nonConfigRequests
        let privacy = try XCTUnwrap(host.fixture.open("PrivacyCenter"))
        privacy.appeared()
        let aboutPage = try XCTUnwrap(host.fixture.open("About"))
        aboutPage.appeared()
        host.fixture.me.cs.open(from: "Me")
        await quietWindow(0.5)
        XCTAssertEqual(nonConfigRequests, before, "本组页面新增零请求")
    }

    /// 回前台重查权限（只查不申请）。
    func testRefreshRequeriesOnly() async throws {
        try await openPrivacy()
        let system = try XCTUnwrap(page).fixture.system
        system.status["push"] = "granted"
        try center.refresh()
        await waitUntil("状态没跟随") { (try? self.center.state.permissionStatus["push"]) == "granted" }
        XCTAssertEqual(system.permissionRequests, 0)
    }

    /// 复制诊断：统一写入口一次，内容逐字等于白名单输出；不含账号、完整设备号。
    func testCopyDiagnosticsOnce() async throws {
        try await openAbout()
        let clipboard = try XCTUnwrap(page).fixture.clipboard
        try about.copyDiagnostics()
        XCTAssertEqual(clipboard.last, try about.diagnostics().joined(separator: "\n"), "逐字")
        let text = try XCTUnwrap(clipboard.last)
        for word in ["device-fixture-0001", "settings-visual-a", "at-settings"] {
            XCTAssertFalse(text.contains(word), word)
        }
    }

    /// 白名单规则：fixture 的压力字段经生产 `Diagnostics.lines`，禁词都被滤掉（Android 同一份数据）。
    func testDiagnosticsAllowListOnFixture() throws {
        let fields = try XCTUnwrap(PrivacyVisualData.about("diagnostics") as? [String: Any])
        let forbidden = try XCTUnwrap(PrivacyVisualData.about("diagnosticsMustNotContain") as? [String])
        let text = Diagnostics.lines(fields: fields).joined(separator: "\n")
        for word in forbidden {
            XCTAssertFalse(text.contains(word), word)
        }
    }

    /// 【重试】：打开一次；拉不起换编号，旧半屏回调零动作。
    func testRetryOpensOnceAndOldSerialIsVoid() async throws {
        try await openCs("cs_open_failed", waitFor: nil)
        let system = try XCTUnwrap(page).fixture.system
        XCTAssertEqual(system.opened.count, 1)
        let old = try csActions
        let serial = try cs.sheet?.serial
        system.openResult = false
        old.openWechat()
        await waitUntil("重试没有发生") { system.opened.count == 2 }
        await waitUntil("没换新编号") { (try? self.cs.sheet?.serial) != serial }
        old.openWechat()
        old.copyLink()
        old.goHelp()
        old.close()
        await settle()
        XCTAssertEqual(system.opened.count, 2, "旧回调零动作")
        XCTAssertNotNil(try cs.sheet, "旧回调不关半屏")
        XCTAssertNil(try XCTUnwrap(page).fixture.clipboard.last, "旧回调不复制")
    }

    /// 拉起成功：半屏关闭。
    func testHandoffOpenClosesSheet() async throws {
        try await openCs("cs_handoff", waitFor: nil)
        try csActions.openWechat()
        await waitUntil("半屏没关") { (try? self.cs.sheet) == nil }
        XCTAssertEqual(try XCTUnwrap(page).fixture.system.opened.count, 1)
    }

    /// 「去帮助中心」（按钮换成链接后）：先关半屏再经 Router 开 Help，一次；再点零动作。
    func testGoHelpClosesThenOpensHelpOnce() async throws {
        try await openCs("cs_open_failed", waitFor: nil)
        let router = try XCTUnwrap(page).fixture.router
        let actions = try csActions
        actions.goHelp()
        XCTAssertNil(try cs.sheet, "先关半屏")
        XCTAssertEqual(router.path.last?.route, "Help")
        let count = router.path.count
        actions.goHelp()
        XCTAssertEqual(router.path.count, count, "再点零动作")
    }

    /// 关闭零动作；invalidate（撤回、换代）后旧回调零动作。
    func testCloseAndInvalidate() async throws {
        try await openCs("cs_wechat_missing", waitFor: nil)
        let fixture = try XCTUnwrap(page).fixture
        let actions = try csActions
        let routes = fixture.router.path.count
        actions.close()
        XCTAssertNil(try cs.sheet)
        actions.copyLink()
        XCTAssertNil(fixture.clipboard.last, "关闭后复制零动作")
        XCTAssertEqual(fixture.router.path.count, routes, "关闭零动作")
        fixture.me.cs.open(from: "Me")
        let fresh = try csActions
        fixture.me.cs.invalidate()
        fresh.copyLink()
        XCTAssertNil(fixture.clipboard.last, "作废后零动作")
    }

    /// 未装微信不直接打开链接。
    func testWechatMissingNeverOpens() async throws {
        try await openCs("cs_wechat_missing", waitFor: nil)
        try csActions.openWechat()
        await settle()
        XCTAssertTrue(try XCTUnwrap(page).fixture.system.opened.isEmpty)
    }
}
