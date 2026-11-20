@testable import Couli
import CouliNetwork
import Foundation
import Login
import MeCore
import XCTest

/// APP-13a-2-ios T15 首次绑定回归（零变化，桩上绿）：BindPhoneService 的首次绑定路径在接入换号后行为不变——不带 X-Step-Up-Token（即使共享
/// 缓存里有 phone_change 的 token）、提交遇 10003 只提示（不弹面板、不重放、不发码）、确认遇 10003 仍「稍后再试」（G53）、30411 mergeable 仍并号。
/// 依据：brief §2「不改首次绑定的行为」、§9「更换带 token，首次绑定不带」、BindPhoneOutcomes 现状。
@MainActor
final class App13a2RegressionTests: App13a2TestCase {
    private func firstBind(_ fixture: App13a2Fixture) async -> BindPageAction? {
        var action: BindPageAction?
        fixture.bind.submit(fixture.bind.identity(), phone: Self.newPhone, code: "654321") { action = $0 }
        await waitUntil("首次绑定没有落定") { action != nil }
        return action
    }

    /// T15（G53、§9）：首次绑定提交遇 10003 → 只提示 error.10003；1 次写请求、不带 token、0 次发码 / 验证。
    func testFirstBind10003OnlyNotices() async {
        script.on(Self.bindWrite, Self.code(10003))
        let fixture = fixture()
        let tokens = fixture.wallet.deps.tokens
        tokens.put(action: "phone_change", account: Self.account, token: "t-pc", expireAtMs: Int64.max)
        let action = await firstBind(fixture)
        XCTAssertEqual(action, .notice(textKey: "error.10003", trace6: ""))
        await quietWindow(0.6)
        XCTAssertEqual(binds.count, 1, "不重放")
        XCTAssertNil(binds.first?.header("X-Step-Up-Token"), "首次绑定不带 token")
        XCTAssertTrue(stepSms.isEmpty, "不弹面板发码")
        XCTAssertTrue(sent(Self.stepUpVerify).isEmpty)
    }

    /// T15（G07 / G53）：首次绑定待确认的确认遇 10003 → 保持待确认、「稍后再试」，不带 token、不弹面板。
    func testFirstBindConfirm10003RetryLater() async throws {
        try seedUnknown()
        script.on(Self.bindWrite, Self.code(10003))
        let fixture = fixture()
        var action: BindPageAction?
        fixture.bind.confirm(fixture.bind.identity(), key: "pc-seeded-key-0001") { action = $0 }
        await waitUntil("确认没有落定") { action != nil }
        XCTAssertEqual(action, .pending(noticeKey: "pending_confirm.retry_later", trace6: ""))
        XCTAssertEqual(binds.first?.header("Idempotency-Key"), "pc-seeded-key-0001")
        XCTAssertNil(binds.first?.header("X-Step-Up-Token"))
        XCTAssertTrue(stepSms.isEmpty)
        XCTAssertEqual(records().first?.stateRaw, PendingKeyStore.unknown, "记录保留")
    }

    /// T15：首次绑定 30411 mergeable 仍进并号（换号的「不进并号」只作用于更换分支，G08）。
    func testFirstBind30411MergeableStillMerges() async {
        script.on(Self.bindWrite, Self.code(30411, "{\"reason\":\"mergeable\",\"merge_ticket\":\"mt-first-0001\"}"))
        let fixture = fixture()
        let action = await firstBind(fixture)
        XCTAssertEqual(action, .merge(ticket: "mt-first-0001"))
    }

    /// T15：首次绑定成功的共享结算不变（记已绑、清全部 token、重取 getMe）。
    func testFirstBindSuccessSettlementUnchanged() async {
        script.on(Self.bindWrite, Self.code(0, "{}"))
        let fixture = fixture()
        fixture.wallet.deps.tokens.put(action: "withdraw", account: Self.account, token: "t-w", expireAtMs: Int64.max)
        let reads = sent(Self.meRead).count
        let action = await firstBind(fixture)
        XCTAssertEqual(action, .done)
        XCTAssertNil(fixture.wallet.deps.tokens.take(action: "withdraw", account: Self.account, nowMs: 0))
        XCTAssertEqual(fixture.login.phone.bound(generation: fixture.client.sessionGeneration), true)
        await waitUntil("getMe 没有重取") { self.sent(Self.meRead).count > reads }
    }
}
