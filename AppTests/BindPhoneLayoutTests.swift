@testable import Couli
import DesignSystem
import Foundation
import Login
import Router
import Session
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-BINDPHONE-LAYOUT（D10-1223，负责人截图指出；D10-1230 判据 1）进程内判据。真实 App 组合（MeAppFixture + 本地假服务）
/// 出绑定手机号页（第三方新号 → 引导【去绑定】）与短信登录页，挂进临时窗口按四档测：
/// ① 手机号输入框只有一行高；② 号码不在中间折行；③ 顶栏与内容区有可见分界（不透字）；⑤ 两页手机号输入是同一组件。
/// ④「获取验证码」放不下时的按钮外观与 44pt 命中区在 UITests/BindPhoneLayoutUITests.swift（要真实按钮框与截图）。
@MainActor
final class BindPhoneLayoutTests: MeTestCase {
    private static let attempt = "{\"attempt_id\":\"att-1\",\"nonce\":\"nonce-for-test-0001\","
        + "\"expire_at\":\"2099-01-01T00:10:00+08:00\"}"
    private static let login = "{\"user_id\":\"user-oauth\",\"is_new_user\":true,\"tokens\":{\"access_token\":\"at-o\","
        + "\"refresh_token\":\"rt-o\",\"session_scope\":\"full\"}}"
    /// 负责人截图里被拆开的号码。
    private static let phone = "13800005678"

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaultsPendingBackend().delete()
        script.ok("POST /v1/auth/oauth-attempts", Self.attempt)
        script.ok("POST /v1/auth/login/wechat", Self.login)
        script.ok("POST /v1/auth/sms-codes", "{\"resend_after_sec\":60,\"expires_in_sec\":300}")
        script.install()
    }

    override func tearDown() {
        UserDefaultsPendingBackend().delete()
        super.tearDown()
    }

    // MARK: - 页面

    /// 第三方新号 → 引导【去绑定】→ 绑手机页的导航实例（与 OAuthBindPhoneWiringTests 同一条真实链路）。
    private func bindEntry(_ fixture: MeAppFixture) async throws -> BindPhoneEntry {
        let wechat = AppFakeAuthorizer(OAuthProvider.wechat)
        fixture.login.oauth.authorizers = [OAuthProvider.wechat: wechat]
        fixture.router.open(RouteRequest(route: "InviteShare", from: .inApp))
        let model = LoginViewModel(config: fixture.login.pageConfig(restricted: false))
        model.toggleAgreement()
        model.startOAuth(OAuthProvider.wechat)
        await waitUntil("没有拉起授权") { wechat.authorizing }
        wechat.complete(.credential(.wechat(code: "code-from-sdk")))
        await waitUntil("没有弹绑手机引导") { fixture.login.bindGuide != nil }
        let guide = try XCTUnwrap(fixture.login.bindGuide)
        fixture.login.goBindPhone(guide.id)
        let top = try XCTUnwrap(fixture.router.path.last)
        XCTAssertEqual(top.route, RoutePolicy.bindPhone)
        return fixture.login.bindEntry(for: top)
    }

    /// 绑手机页按档挂好、号码已填、手机号框未聚焦。
    private func mountBind(_ fixture: MeAppFixture, _ entry: BindPhoneEntry,
                           _ tier: BindPhoneLayoutCanvas.Tier) async -> BindPhoneLayoutCanvas {
        let canvas = BindPhoneLayoutCanvas(
            AnyView(BindPhoneScreen(entry: entry, texts: fixture.login.texts)),
            tier: tier
        )
        await canvas.pump()
        entry.controller.setPhone(Self.phone)
        canvas.window.endEditing(true)
        await canvas.pump()
        return canvas
    }

    /// 短信登录页按档挂好：手机号经系统输入框打进去（页面自己持有 model），再收起键盘。
    private func mountLogin(_ fixture: MeAppFixture, _ tier: BindPhoneLayoutCanvas.Tier) async throws
        -> BindPhoneLayoutCanvas {
        let page = LoginView(config: fixture.login.pageConfig(restricted: false))
        let canvas = BindPhoneLayoutCanvas(AnyView(page), tier: tier)
        await canvas.pump()
        let input = try XCTUnwrap(canvas.phoneInputs().first, "[\(tier)] 短信登录页没有手机号输入框")
        guard let typing = input as? UIResponder & UIKeyInput else {
            XCTFail("[\(tier)] 手机号输入框不能键入：\(type(of: input))")
            return canvas
        }
        _ = typing.becomeFirstResponder()
        typing.insertText(Self.phone)
        await canvas.pump()
        canvas.window.endEditing(true)
        await canvas.pump()
        return canvas
    }

    // MARK: - ① ② 手机号一行

    /// ①②（kick 第 1、2 条）绑手机页四档：号码完整、不折行，输入框高度 < 2 倍单行高（且不超过最小控件高 + 1）。
    func testBindPhoneNumberStaysOnOneLineAllTiers() async throws {
        let fixture = make(account: nil)
        let entry = try await bindEntry(fixture)
        for tier in BindPhoneLayoutCanvas.tiers {
            let canvas = await mountBind(fixture, entry, tier)
            defer { canvas.close() }
            try assertSingleLine(canvas, page: "绑定手机号页")
        }
    }

    /// ①②（kick 第 5、6 条：两页都测）短信登录页四档同一判据（现状已是单行框，钉住不回退）。
    func testLoginPhoneNumberStaysOnOneLineAllTiers() async throws {
        let fixture = make(account: nil)
        for tier in BindPhoneLayoutCanvas.tiers {
            let canvas = try await mountLogin(fixture, tier)
            defer { canvas.close() }
            try assertSingleLine(canvas, page: "短信登录页")
        }
    }

    /// kick 第 2 条「改成单行输入框（不用 axis: .vertical）」：两页的手机号输入背后都是系统单行框 UITextField。
    func testPhoneInputIsSingleLineControlOnBothPages() async throws {
        let fixture = make(account: nil)
        let entry = try await bindEntry(fixture)
        let tier = BindPhoneLayoutCanvas.tiers[2]
        let bind = await mountBind(fixture, entry, tier)
        let bindKinds = bind.phoneInputs().map { String(describing: type(of: $0)) }
        bind.close()
        let login = try await mountLogin(fixture, tier)
        let loginKinds = login.phoneInputs().map { String(describing: type(of: $0)) }
        login.close()
        for (page, kinds) in [("绑定手机号页", bindKinds), ("短信登录页", loginKinds)] {
            XCTAssertEqual(kinds.count, 1, "\(page) 应恰有一个手机号输入框：\(kinds)")
            XCTAssertTrue(kinds.allSatisfy { $0 == "UITextField" || $0.hasSuffix("TextField") },
                          "\(page) 手机号要用单行输入框（UITextField），不用纵向轴 TextField（UITextView）：\(kinds)")
        }
    }

    private func assertSingleLine(_ canvas: BindPhoneLayoutCanvas, page: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let tier = canvas.tier
        let inputs = canvas.phoneInputs()
        XCTAssertEqual(inputs.count, 1, "[\(page) \(tier)] 手机号输入框个数", file: file, line: line)
        let view = try XCTUnwrap(inputs.first, "[\(page) \(tier)] 没有手机号输入框", file: file, line: line)
        let reading = BindPhoneInputReading(view, in: canvas)
        XCTAssertEqual(reading.text, Self.phone, "[\(page) \(tier)] 号码完整显示（不截、不缩成省略号）", file: file, line: line)
        XCTAssertFalse(reading.wrapped, "[\(page) \(tier)] ② 号码不能在数字中间折行：\(reading)", file: file, line: line)
        let font = try XCTUnwrap(reading.font, "[\(page) \(tier)] 读不到输入框字体", file: file, line: line)
        let floor = CouliComponentMetric.controlMinHeight + CouliSpacing.s1 + 1
        let limit = max(2 * font.lineHeight, floor)
        XCTAssertLessThan(reading.frame.height, limit,
                          "[\(page) \(tier)] ① 输入框只有一行高（< max(2×行高, 最小控件高+1) = \(limit)）：\(reading)",
                          file: file, line: line)
        XCTAssertLessThanOrEqual(reading.frame.maxX, canvas.window.bounds.width + 0.5,
                                 "[\(page) \(tier)] 输入框不出屏：\(reading)", file: file, line: line)
    }

    // MARK: - ③ 顶栏不透字

    /// ③（kick 第 3 条）绑手机页：顶栏要有不透明底色或系统材质，和内容区有可见分界——顶栏带（安全区下沿到滚动区上沿 +2pt）里，
    /// 两侧页边（x = 6、宽 − 6，任何内容都不画到这里）至少有一行颜色与页面底色不同（不同底色、材质或分隔线均可）。
    /// 现状顶栏透明、与页面底同色，滚上去的卡片在标题下被裁一半，看上去像从顶栏下透出来。
    func testBindPhoneTopBarIsDelimitedFromContent() async throws {
        let fixture = make(account: nil)
        let entry = try await bindEntry(fixture)
        for tier in [BindPhoneLayoutCanvas.tiers[0], BindPhoneLayoutCanvas.tiers[1]] {
            let canvas = await mountBind(fixture, entry, tier)
            defer { canvas.close() }
            try await assertTopBarDelimited(canvas, page: "绑定手机号页")
        }
    }

    /// ③ 短信登录页同一判据（kick 第 6 条：两页都要确认顶栏下不透字）。
    func testLoginTopBarIsDelimitedFromContent() async throws {
        let fixture = make(account: nil)
        for tier in [BindPhoneLayoutCanvas.tiers[0], BindPhoneLayoutCanvas.tiers[1]] {
            let canvas = try await mountLogin(fixture, tier)
            defer { canvas.close() }
            try await assertTopBarDelimited(canvas, page: "短信登录页")
        }
    }

    private func assertTopBarDelimited(_ canvas: BindPhoneLayoutCanvas, page: String,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let tier = canvas.tier
        let scroll = try XCTUnwrap(canvas.mainScroll(), "[\(page) \(tier)] 没有滚动区", file: file, line: line)
        // 内容往上滚一段，让卡片停在顶栏下沿（负责人截图的状态）
        let room = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        if room > 0 {
            scroll.setContentOffset(CGPoint(x: 0, y: min(60, room) - scroll.adjustedContentInset.top), animated: false)
            await canvas.pump(rounds: 4)
        }
        let frame = canvas.rect(scroll)
        let top = BindPhoneLayoutCanvas.top
        // 滚动区从顶栏下开始时顶栏带 = 安全区下沿…滚动区上沿 +2；滚动区铺到顶栏下面（材质做法）时取安全区下 44pt
        let barBottom = frame.minY > top + 20 ? frame.minY + 2 : top + CouliHitTarget.minimum
        let pixels = try XCTUnwrap(canvas.render(), "[\(page) \(tier)] 渲染失败", file: file, line: line)
        let width = canvas.window.bounds.width
        let reference = pixels.rgb(6, frame.midY)
        var rows: [CGFloat] = []
        var row = top + 0.5
        while row <= barBottom {
            let left = BindPhoneLayoutPixels.distance(pixels.rgb(6, row), reference)
            let right = BindPhoneLayoutPixels.distance(pixels.rgb(width - 6, row), reference)
            if left > 4, right > 4 {
                rows.append(row)
            }
            row += 0.5
        }
        XCTAssertFalse(rows.isEmpty,
                       "[\(page) \(tier)] ③ 顶栏（y \(top)…\(barBottom)）与页面底色 \(reference) 没有任何可见分界："
                           + "顶栏要有不透明底色 / 系统材质 / 分隔线，内容不能看起来从顶栏下透出",
                       file: file, line: line)
    }

    // MARK: - ⑤ 同一组件

    /// ⑤（kick 第 5 条，负责人定的「组件一致」）运行时：同一档下两页手机号输入框是同一种系统控件、同一字号。
    func testBothPagesRenderSamePhoneInput() async throws {
        let fixture = make(account: nil)
        let entry = try await bindEntry(fixture)
        for tier in BindPhoneLayoutCanvas.tiers {
            let bind = await mountBind(fixture, entry, tier)
            let bindReading = bind.phoneInputs().first.map { BindPhoneInputReading($0, in: bind) }
            bind.close()
            let login = try await mountLogin(fixture, tier)
            let loginReading = login.phoneInputs().first.map { BindPhoneInputReading($0, in: login) }
            login.close()
            let pair = try (XCTUnwrap(bindReading, "[\(tier)] 绑手机页没有手机号框"),
                            XCTUnwrap(loginReading, "[\(tier)] 登录页没有手机号框"))
            XCTAssertEqual(pair.0.kind, pair.1.kind, "[\(tier)] 两页手机号输入应是同一组件：\(pair.0) / \(pair.1)")
            XCTAssertEqual(pair.0.font?.pointSize ?? 0, pair.1.font?.pointSize ?? -1, accuracy: 0.5,
                           "[\(tier)] 两页手机号字号一致：\(pair.0) / \(pair.1)")
        }
    }

    /// ⑤ 源码守卫：产品源码里电话键盘的输入框只写一处（共用组件），两页都用它；改一处所有页面一起生效。
    func testPhoneInputDefinedOnceInSource() throws {
        let root = try repositoryRoot()
        var hits: [String] = []
        for sub in [
            "App/Sources",
            "Packages/Core/Sources",
            "Packages/Features/Sources",
            "Packages/DesignSystem/Sources",
        ] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(sub),
                                                              includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                let code = ShellSystemTabBarSourceTests.stripComments(try String(contentsOf: file, encoding: .utf8))
                let count = code.components(separatedBy: ".phonePad").count - 1
                if count > 0 {
                    hits.append(file.path.replacingOccurrences(of: root.path + "/", with: "") + " ×\(count)")
                }
            }
        }
        XCTAssertEqual(hits.count, 1, "电话键盘输入框应只在一个共用组件里写一次（现状两页各写一份）：\(hits)")
        if hits.count == 1 {
            XCTAssertTrue(hits[0].hasSuffix(" ×1"), "共用组件里只写一次：\(hits)")
        }
    }

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { throw XCTSkip("找不到仓库根（contract.lock）") }
            directory = parent
        }
        return directory
    }
}
