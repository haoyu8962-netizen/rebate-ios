import Clipboard
@testable import Couli
import Foundation
import Login
import Router
import XCTest

/// APP-07 iOS 第 2 轮评审 R2-01、R2-02（共性第 2、28 条；所有商品粘贴入口共享在途保护）。
extension ClipboardWiringTests {
    // MARK: - R2-01 登录页粘贴：离页再返回同一实例不恢复旧交付

    /// Login 点了邀请码【粘贴】→ 打开 Settings → 返回同一个 Login 实例 → 旧交付到达：丢弃（.ignored），
    /// 不覆盖返回后填写的邀请码（.code 才写 inviteText），无效内容也不弹迟到的「未识别到邀请码」（.message 才弹）。
    func testR2_01_LoginCoveredBySettingsThenSameInstanceDropsOldDelivery() throws {
        let fixture = make()
        fixture.clipboard.sceneActive()
        let login = RouteDestination(route: "Login")
        fixture.routing.router.path = [login]
        let paste = fixture.clipboard.makeLoginInvitePaste()
        var inviteText = ""
        var toasts: [String] = []
        func apply(_ outcome: LoginInvitePasteOutcome) {
            switch outcome {
            case let .code(code): inviteText = code
            case let .message(message): toasts.append(message)
            case .ignored: break
            }
        }

        let valid = try XCTUnwrap(paste.begin())
        fixture.routing.router.path = [login, RouteDestination(route: "Settings")]
        fixture.routing.router.path = [login]
        inviteText = "HAND01"
        apply(valid("邀请码 K7M2QX"))
        XCTAssertEqual(inviteText, "HAND01", "旧交付不覆盖返回后填写的邀请码")

        let invalid = try XCTUnwrap(paste.begin())
        fixture.routing.router.path = [login, RouteDestination(route: "Settings")]
        fixture.routing.router.path = [login]
        apply(invalid("普通文字，没有码"))
        XCTAssertTrue(toasts.isEmpty, "不弹迟到的「未识别到邀请码」")

        let live = try XCTUnwrap(paste.begin())
        apply(live("邀请码 K7M2QX"))
        XCTAssertEqual(inviteText, "K7M2QX", "对照：没有离页时照常填码")
        XCTAssertEqual(fixture.routing.router.path.last?.id, login.id)
    }

    /// 登录页粘贴的其余票据：会话、环境、隐私变化后迟到的交付同样丢弃；同一次点击只交付一次。
    func testR2_01_LoginDeliveryChecksSessionEnvironmentAndPrivacy() throws {
        let fixture = make()
        fixture.clipboard.sceneActive()
        fixture.routing.router.path = [RouteDestination(route: "Login")]
        let paste = fixture.clipboard.makeLoginInvitePaste()

        let session = try XCTUnwrap(paste.begin())
        fixture.state.session += 1
        XCTAssertEqual(session("邀请码 K7M2QX"), .ignored, "会话变化")
        let environment = try XCTUnwrap(paste.begin())
        fixture.state.epoch += 1
        XCTAssertEqual(environment("邀请码 K7M2QX"), .ignored, "切换环境")
        let privacy = try XCTUnwrap(paste.begin())
        fixture.state.privacy = .basicMode
        XCTAssertEqual(privacy("邀请码 K7M2QX"), .ignored, "撤回 / 基本模式")
        fixture.state.privacy = .consented
        let once = try XCTUnwrap(paste.begin())
        XCTAssertEqual(once("邀请码 K7M2QX"), .code("K7M2QX"))
        XCTAssertEqual(once("邀请码 K7M2QX"), .ignored, "重复交付丢弃")
    }

    // MARK: - R2-02 商品提示条与首页常驻卡共享在途保护

    /// 提示条显示时先点常驻卡：提示条同步收起，读取等待与 parse 在途期间再点提示条都不发起第二次读取或请求。
    func testR2_02_PromptAndHomeCardShareBusyGuard() async throws {
        let fixture = make()
        fixture.system.changeCount = 1
        fixture.system.detectHit = true
        fixture.clipboard.sceneActive()
        let prompt = try XCTUnwrap(fixture.clipboard.prompt)
        fixture.api.hold = true

        let card = click(fixture, entry: ManualPasteAction.entryHome)
        XCTAssertNil(fixture.clipboard.prompt, "手动粘贴开始时收起已有商品提示条")
        XCTAssertFalse(fixture.clipboard.promptPasteEnabled, "读取等待期间提示条控件置灰")
        XCTAssertNil(fixture.clipboard.beginPromptPaste(prompt.id), "读取等待期间点提示条不读")
        XCTAssertEqual(fixture.clipboard.readCount, 1)
        card(link)
        await settle()
        XCTAssertEqual(fixture.api.bodies.count, 1, "第一次交付未被覆盖，照常 parse")

        // parse 在途时又出现一条提示条（探测与点击交错）：界面置灰，执行层也拦
        fixture.clipboard.prompt = ClipboardPrompt(id: 9999)
        XCTAssertFalse(fixture.clipboard.promptPasteEnabled, "parse 在途期间提示条控件置灰")
        XCTAssertNil(fixture.clipboard.beginPromptPaste(9999), "parse 在途期间点提示条不读")
        XCTAssertEqual(fixture.clipboard.readCount, 1, "读取次数仍为 1")
        fixture.api.release()
        await settle()
        XCTAssertEqual(fixture.api.bodies.count, 1, "parse 请求次数仍为 1")
    }

    /// 反向交错：先点提示条，读取 / parse 在途期间点常驻卡与 SearchTyping 入口都不读。
    func testR2_02_PromptFirstThenHomeCardIsBlocked() async throws {
        let fixture = make()
        fixture.system.changeCount = 1
        fixture.system.detectHit = true
        fixture.clipboard.sceneActive()
        let prompt = try XCTUnwrap(fixture.clipboard.prompt)
        fixture.api.hold = true
        let fromPrompt = clickPrompt(fixture, id: prompt.id)
        XCTAssertNil(fixture.clipboard.beginPaste(entry: ManualPasteAction.entryHome), "读取等待期间常驻卡不读")
        fromPrompt(link)
        await settle()
        XCTAssertNil(fixture.clipboard.beginPaste(entry: ManualPasteAction.entryHome), "parse 在途期间常驻卡不读")
        XCTAssertEqual(fixture.clipboard.readCount, 1)
        fixture.api.release()
        await settle()
        XCTAssertEqual(fixture.api.bodies.count, 1)
        XCTAssertTrue(fixture.clipboard.promptPasteEnabled, "请求结束后忙碌解除")
    }
}
