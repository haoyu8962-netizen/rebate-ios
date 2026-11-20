@testable import Couli
import CouliNetwork
import Foundation
import Login
import Me
import MeCore
import XCTest

/// APP-13a-2-ios T10 与 BindPhone 页共用的状态（共性第 8、9、18、24、39、47 条，M6、M7）：phoneGate 同一份、共享未决通知携带结局、
/// 别处绑定成功让第 1 步 token 失效。BindPhone 一侧只走 BindPhoneService 的公开入口与 BindPhoneController 的公开状态（首次绑定代码不动）。
@MainActor
final class App13a2SharedTests: App13a2TestCase {
    private func bindPage(_ fixture: App13a2Fixture) -> BindPhoneController {
        BindPhoneController(owner: fixture.bind.identity(), entryId: UUID(), service: fixture.bind,
                            texts: fixture.login.texts, hooks: BindPhoneHooks())
    }

    /// T10（共性第 8 条，M7）：换号页提交遇 42901 → 写进 BindPhoneService 的 phoneGate；BindPhone 页的【绑定】【确认】【放弃】随之置灰。
    func testPhoneChange42901DisablesBindPage() async throws {
        script.on(Self.bindWrite, Self.retryAfter(30))
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        await submit(controller)
        await waitUntil("42901 没有写进 phoneGate（M7）") { fixture.bind.writeGated(fixture.bind.identity()) }
        let page = bindPage(fixture)
        page.setPhone("13700001111")
        page.setCode("111111")
        XCTAssertTrue(page.writeGated)
        XCTAssertFalse(page.canSubmit, "【绑定】置灰")
        XCTAssertFalse(page.pendingActionsEnabled, "【确认】【放弃】置灰")
        XCTAssertFalse(controller.submitEnabled, "换号页自己也置灰")
        page.invalidate()
    }

    /// T10 反向：BindPhone 页（同一服务）提交遇 42901 → 换号页【提交】与待确认两个按钮置灰。
    func testBindPage42901DisablesPhoneChange() async throws {
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        script.on(Self.bindWrite, Self.retryAfter(30))
        var settled = false
        fixture.bind.submit(fixture.bind.identity(), phone: "13700001111", code: "111111") { _ in settled = true }
        await waitUntil("BindPhone 提交没有落定") { settled }
        XCTAssertFalse(controller.submitEnabled, "换号【提交】置灰")
        XCTAssertFalse(controller.pendingActionsEnabled)
        let count = binds.count
        act(controller).submit()
        await quietWindow(0.6)
        XCTAssertEqual(binds.count, count, "禁用期内 0 次发送")
    }

    /// T10（共性第 18、24、47 条）：BindPhone 一侧结算了同一个键（确认成功）→ 换号页按结局落到 Done。
    func testOtherPageConfirmDoneLandsDone() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        let key = try XCTUnwrap(records().first?.key)
        script.on(Self.bindWrite, Self.code(0, "{}"))
        fixture.bind.confirm(fixture.bind.identity(), key: key) { _ in }
        await waitUntil("共享通知 done 没有落到 Done") { controller.state.step == .done }
        XCTAssertTrue(records().isEmpty)
    }

    /// T10（共性第 24 条）：BindPhone 一侧放弃得到 abandoned → 换号页回第 1 步、清空、重新验证（不能仅凭记录消失切到第 2 步）。
    func testOtherPageAbandonedLandsStep1() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        let key = try XCTUnwrap(records().first?.key)
        script.ok(Self.abandonWrite, "{\"outcome\":\"abandoned\",\"original\":null}")
        fixture.bind.abandon(fixture.bind.identity(), key: key) { _ in }
        await waitUntil("共享通知 abandoned 没有落到第 1 步") { controller.state.step == .step1 }
        XCTAssertFalse(controller.hasStepToken)
        XCTAssertEqual(controller.state.newPhone, "")
    }

    /// T10（共性第 44、47 条）：BindPhone 一侧确认得到 3xxxx（ended）→ 换号页回第 2 步并显示错误。
    func testOtherPageEndedLandsStep2() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        let key = try XCTUnwrap(records().first?.key)
        script.on(Self.bindWrite, Self.code(30411))
        fixture.bind.confirm(fixture.bind.identity(), key: key) { _ in }
        await waitUntil("共享通知 ended 没有落到第 2 步") { controller.state.step == .step2 }
        XCTAssertFalse(keys(controller.state).isEmpty, "显示错误")
    }

    /// T10（共性第 9、39 条，M6）：第 1 步拿到 token 后，别处（BindPhoneService）绑定成功 → 共享结算让流程私有 token 失效、
    /// StepUpTokenCache 全清。
    func testBindSuccessElsewhereInvalidatesStepToken() async throws {
        let fixture = fixture()
        let (_, controller) = try await enter(fixture)
        await passStep1(controller)
        XCTAssertTrue(controller.hasStepToken, "前提")
        script.on(Self.bindWrite, Self.code(0, "{}"))
        var settled = false
        fixture.bind.submit(fixture.bind.identity(), phone: "13700001111", code: "111111") { _ in settled = true }
        await waitUntil("别处绑定没有落定") { settled }
        await settle()
        XCTAssertFalse(controller.hasStepToken, "别处绑定成功 → 流程 token 失效（M6）")
        XCTAssertNil(fixture.wallet.deps.tokens.take(action: "phone_change", account: Self.account, nowMs: 0))
    }

    /// 共性第 43 条反向时序：第 1 步验证在途时别处绑定成功（先清 token），旧验证成功迟到 → 丢弃，不进第 2 步、不留 token。
    func testLateVerifyAfterInvalidationIsDropped() async throws {
        script.on(Self.stepUpVerify, .hold)
        let fixture = fixture()
        let (_, controller) = try await enter(fixture)
        act(controller).requestOldCode()
        await waitUntil("没有发码") { !self.stepSms.isEmpty && !controller.state.oldSending }
        act(controller).oldCode("123456")
        act(controller).next()
        await waitUntil("验证没有挂起") { self.heldId(Self.stepUpVerify) != nil }
        script.on(Self.bindWrite, Self.code(0, "{}"))
        var settled = false
        fixture.bind.submit(fixture.bind.identity(), phone: "13700001111", code: "111111") { _ in settled = true }
        await waitUntil("别处绑定没有落定") { settled }
        WalletStubProtocol.release(try XCTUnwrap(heldId(Self.stepUpVerify)), with: Self.token(Self.stepToken))
        await quietWindow(0.8)
        XCTAssertFalse(controller.hasStepToken, "失效世代已变：迟到的 token 丢弃")
        XCTAssertNotEqual(controller.state.step, .step2)
        XCTAssertNil(fixture.wallet.deps.tokens.take(action: "phone_change", account: Self.account, nowMs: 0))
    }
}
