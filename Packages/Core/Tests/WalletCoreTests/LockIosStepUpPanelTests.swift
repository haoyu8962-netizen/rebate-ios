import CouliNetwork
import Foundation
@testable import WalletCore
import XCTest

/// LOCK-ios 段 3：二次验证面板（StepUpController）的发码与验证口径，经 `WalletApi` 替身直接看交给网络层的 ApiCall。
/// - 发码 sendSmsCode {purpose: step_up, action}：不带 phone，ApiCall 置 `requiresSession`（B1-02zzz、D10-1658 ①④）；
/// - 槽位键：App 没给号码（Release 的 phoneProvider 为 nil）也照常发码，槽位键用占位 `StepUpController.boundSlot`；倒计时内重开不重发；
/// - phone_bound：只有已知为 false 且 action 不是 withdraw 才进 noPhone、不发码；true / nil 照常发；提现即使 false 也发（D10-1667）；
/// - 验证 stepUp：改收款带 summary、提现不带；拿到的令牌按摘要键缓存（D10-1665 / D10-1667）。
/// 网络层对置了 requiresSession 的调用「没有本人令牌本地 session_unreadable、零发送」在 App 层接线测试里经真实 ApiClient 看
/// （AppTests/LockIosStepUpWiringTests）。
@MainActor
final class LockIosStepUpPanelTests: XCTestCase {
    static let payout = "payout_account_change"
    static let withdraw = "withdraw"
    static let alipay = ["payout_method": "alipay", "alipay_logon_id": "zhangsan@example.com"]

    private var fixtures: [StepUpPanelFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures {
            fixture.close()
        }
        fixtures = []
        try await super.tearDown()
    }

    private func make(phone: String? = "13800005678", bound: Bool? = true) -> StepUpPanelFixture {
        let fixture = StepUpPanelFixture()
        fixture.env.phone = phone
        fixture.env.bound = bound
        fixtures.append(fixture)
        return fixture
    }

    // MARK: - 发码请求

    /// 发码 ApiCall：operationId sendSmsCode、置 requiresSession、请求体只有 purpose=step_up 与 action（即使 App 给了号码也不上送）。
    func testSendCallRequiresSessionAndCarriesOnlyPurposeAndAction() async throws {
        for action in [Self.withdraw, Self.payout] {
            let fixture = make(phone: "13800005678")
            fixture.open(action, summary: action == Self.payout ? Self.alipay : nil)
            await fixture.landed()
            XCTAssertEqual(fixture.smsCalls.count, 1, "\(action)：打开即发码一次")
            let call = try XCTUnwrap(fixture.smsCalls.first)
            XCTAssertTrue(call.requiresSession, "\(action)：发码必须要本人会话（requiresSession）")
            XCTAssertFalse(call.sendsWhenIdentityUnknown, "\(action)：身份未知不匿名发出")
            XCTAssertNil(call.stepUpToken)
            let body = try fixture.body(call)
            XCTAssertEqual(Set(body.keys), ["purpose", "action"], "\(action)：请求体只有 purpose 与 action")
            XCTAssertEqual(body["purpose"] as? String, StepUpController.purpose)
            XCTAssertEqual(body["action"] as? String, action)
            XCTAssertNil(body["phone"], "\(action)：不带 phone")
            XCTAssertNil(body["summary"], "\(action)：发码不带业务摘要")
            XCTAssertEqual(fixture.panel.state?.phase, .ready)
            XCTAssertEqual(fixture.panel.state?.resendLeftSec, 60, "\(action)：按 resend_after_sec 起倒计时")
        }
    }

    // MARK: - 槽位键（phoneProvider 为 nil）

    /// App 没给号码（Release）：照常发码，不进 noPhone；倒计时记在占位槽位 `boundSlot` 下；倒计时内关闭再打开不重复发，按原截止恢复。
    func testNilPhoneStillSendsAndReopenInCountdownDoesNotResend() async {
        let fixture = make(phone: nil, bound: nil)
        fixture.open(Self.payout, summary: Self.alipay)
        await fixture.landed()
        XCTAssertEqual(fixture.smsCalls.count, 1, "号码为 nil 也发码")
        XCTAssertEqual(fixture.panel.state?.phase, .ready, "不进 noPhone")
        XCTAssertEqual(StepUpController.boundSlot, "bound")
        let slot = SmsDeadlines.Slot(account: "user-a", phone: StepUpController.boundSlot, action: Self.payout)
        XCTAssertEqual(fixture.deps.sms.remaining(slot, now: fixture.env.now), 60000, "截止时间记在占位槽位下")

        fixture.close()
        fixture.env.now += 15000
        fixture.open(Self.payout, summary: Self.alipay)
        await fixture.landed()
        XCTAssertEqual(fixture.smsCalls.count, 1, "倒计时内重开不重复发码")
        XCTAssertEqual(fixture.panel.state?.phase, .ready)
        XCTAssertEqual(fixture.panel.state?.resendLeftSec, 45, "按原截止恢复倒计时")

        fixture.close()
        fixture.env.now += 46000
        fixture.open(Self.payout, summary: Self.alipay)
        await fixture.landed()
        XCTAssertEqual(fixture.smsCalls.count, 2, "倒计时结束后重开照常发码")
    }

    // MARK: - phone_bound

    /// phone_bound=false：改收款进 noPhone、不发码、不起倒计时；读绑定状态用的是打开面板时固定的身份。
    func testUnboundPayoutEntersNoPhoneWithoutSending() async throws {
        let fixture = make(bound: false)
        fixture.open(Self.payout, summary: Self.alipay)
        await fixture.landed()
        let state = try XCTUnwrap(fixture.panel.state)
        XCTAssertEqual(state.phase, .noPhone)
        XCTAssertEqual(state.resendLeftSec, 0)
        XCTAssertTrue(fixture.smsCalls.isEmpty, "没绑手机：改收款不发码")
        XCTAssertEqual(fixture.env.boundQueries.last, fixture.env.owner, "按面板身份读绑定状态")
        // noPhone 时【重新获取】也不发
        fixture.panel.resend(instance: state.instance)
        await fixture.idle()
        XCTAssertTrue(fixture.smsCalls.isEmpty)
    }

    /// phone_bound=false：提现照常发码（D10-1667：本地拦不碰提现，交给服务端判）。
    func testUnboundWithdrawStillSends() async {
        let fixture = make(bound: false)
        fixture.open(Self.withdraw)
        await fixture.landed()
        XCTAssertEqual(fixture.smsCalls.count, 1, "提现不按 phone_bound 本地拦")
        XCTAssertEqual(fixture.panel.state?.phase, .ready)
        XCTAssertEqual(fixture.panel.state?.resendLeftSec, 60)
    }

    /// phone_bound=true / nil（未知）：两种 action 都照常发码。
    func testBoundOrUnknownSendsForBothActions() async {
        for bound in [true, nil] as [Bool?] {
            for action in [Self.withdraw, Self.payout] {
                let fixture = make(bound: bound)
                fixture.open(action, summary: action == Self.payout ? Self.alipay : nil)
                await fixture.landed()
                let tag = "\(action)/phone_bound=\(bound.map { "\($0)" } ?? "nil")"
                XCTAssertEqual(fixture.smsCalls.count, 1, "\(tag)：照常发码")
                XCTAssertEqual(fixture.panel.state?.phase, .ready, tag)
            }
        }
    }

    // MARK: - 验证请求与令牌缓存

    /// 改收款：验证请求体带打开面板时给的摘要（支付宝、借记卡两种），令牌按摘要键缓存——同摘要可取、不同摘要 / 不带摘要取不到。
    func testPayoutVerifyCarriesSummaryAndCachesTokenBySummary() async throws {
        let bank = ["payout_method": "bank_card", "card_no": "6222 0000 0000 0009"]
        for summary in [Self.alipay, bank] {
            let fixture = make()
            fixture.open(Self.payout, summary: summary)
            await fixture.landed()
            try await fixture.verify()
            let body = try fixture.body(fixture.verifyCalls.last)
            XCTAssertEqual(Set(body.keys), ["action", "code", "summary"])
            XCTAssertEqual(body["action"] as? String, Self.payout)
            XCTAssertEqual(body["code"] as? String, "123456")
            XCTAssertEqual(body["summary"] as? [String: String], summary, "验证请求体带业务摘要")
            XCTAssertEqual(fixture.delivered, [StepUpPanelApi.token], "令牌交给发起方")
            XCTAssertNil(fixture.panel.state, "拿到令牌收起面板")
            let tokens = fixture.deps.tokens
            let now = fixture.env.now
            XCTAssertEqual(tokens.take(action: Self.payout, account: "user-a", nowMs: now,
                                       summary: StepUpSummary.key(summary)), StepUpPanelApi.token, "同摘要复用")
            let other = ["payout_method": "alipay", "alipay_logon_id": "lisi@example.com"]
            XCTAssertNil(tokens.take(action: Self.payout, account: "user-a", nowMs: now,
                                     summary: StepUpSummary.key(other)), "不同摘要不复用")
            XCTAssertNil(tokens.take(action: Self.payout, account: "user-a", nowMs: now), "不带摘要不复用")
        }
    }

    /// 提现：验证请求体没有 summary 键；令牌不带摘要缓存，按同 action 复用。
    func testWithdrawVerifyHasNoSummaryAndCachesByAction() async throws {
        let fixture = make()
        fixture.open(Self.withdraw)
        await fixture.landed()
        try await fixture.verify()
        let body = try fixture.body(fixture.verifyCalls.last)
        XCTAssertEqual(Set(body.keys), ["action", "code"], "提现验证不带 summary")
        XCTAssertEqual(fixture.delivered, [StepUpPanelApi.token])
        XCTAssertEqual(
            fixture.deps.tokens.take(action: Self.withdraw, account: "user-a", nowMs: fixture.env.now),
            StepUpPanelApi.token, "提现按同 action 复用"
        )
        XCTAssertNil(fixture.deps.tokens.take(
            action: Self.withdraw, account: "user-a", nowMs: fixture.env.now,
            summary: StepUpSummary.key(Self.alipay)
        ))
    }

    /// 摘要只随本面板实例：上一个改收款面板关闭后，同一执行器再打开提现面板，验证体不残留上一次的摘要。
    /// D10-1722 (a)：摘要里是完整收款账号（支付宝登录号 / 卡号），收起面板（用户关闭、拿到令牌）就要从执行器内存里清掉，不等下一次 open 覆盖。
    /// 面板只有 open() 能从「无」到「有」、验证在发请求时已取走摘要，所以清摘要那一行没有请求层面的可观察差异，这里直接看执行器保存的摘要。
    func testSummaryDoesNotLeakIntoNextPanel() async throws {
        let fixture = make()
        fixture.open(Self.payout, summary: Self.alipay)
        await fixture.landed()
        XCTAssertEqual(fixture.panel.summary, Self.alipay, "前提：打开时记下摘要")
        fixture.close()
        XCTAssertNil(fixture.panel.summary, "用户关闭面板即从内存清掉摘要（不留完整账号）")
        fixture.open(Self.withdraw)
        await fixture.landed()
        try await fixture.verify()
        let body = try fixture.body(fixture.verifyCalls.last)
        XCTAssertNil(body["summary"], "关闭面板即清摘要")
        XCTAssertEqual(body["action"] as? String, Self.withdraw)

        // 拿到令牌收起面板（dismiss 的另一条入口）同样清掉
        fixture.open(Self.payout, summary: Self.alipay)
        await fixture.landed()
        try await fixture.verify()
        XCTAssertNil(fixture.panel.state, "前提：拿到令牌收起面板")
        XCTAssertNil(fixture.panel.summary, "拿到令牌收起面板即从内存清掉摘要")
    }
}
