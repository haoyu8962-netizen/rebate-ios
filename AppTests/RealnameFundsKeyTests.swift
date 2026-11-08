@testable import Couli
import CouliNetwork
import Foundation
import Wallet
import WalletCore
import XCTest

/// 实名提交的幂等键（契约 IdempotencyKey：同键处理中 40901、同键不同体 20901、超时后沿用原键拿第一次的结果；编排裁定 F-AND-48：
/// 40901 不是终态，实名在列——保持在途、原键查结果 / 重放、不换新键）与结果归属（共性第 52、65 条）。
final class RealnameFundsKeyTests: RealnameFundsTestCase {
    /// 40901：保持加载态（按钮锁住、不显示完成、不出栈），稍后自动用原键、原请求体再查；得到成功后照常完成。同意不重新记。
    func test40901KeepsLoadingAndResendsSameKey() async throws {
        scriptUnverifiedThenVerified()
        script.on("POST \(Self.path)", .envelope(code: 40901, data: "null", headers: [:]), Self.success)
        let fixture = make()
        let page = try await openFromWithdraw(fixture)
        fill(page)
        submitWithConsent(page)
        await awaitPosts(1)
        await settle()
        // 首次退避约 1 秒，settle 约 40 毫秒：此刻只应有 1 次提交（无条件断言，不许空过）
        XCTAssertEqual(realnamePosts.count, 1, "40901 后立刻重发（没有退避）")
        XCTAssertFalse(page.submitEnabled, "40901 不是终态：保持在途、按钮锁住")
        XCTAssertNil(page.state.done)
        XCTAssertTrue(page.state.error == nil || page.state.error?.key == "error.40901", "不当成失败")
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.realName)
        await awaitPosts(2, timeout: 10)
        let posts = realnamePosts
        guard posts.count >= 2 else { return }
        XCTAssertEqual(key(posts[0]), key(posts[1]), "40901 后沿用原键（F-AND-48）")
        XCTAssertTrue(posts[0].body == posts[1].body, "40901 后原请求体（不打印）")
        XCTAssertEqual(consentPosts.count, 1, "查结果不重新记同意")
        await waitUntil("原键拿到成功后没有完成") { fixture.wallet.realnameVerified() }
        XCTAssertNotEqual(fixture.router.path.last?.route, WalletRoutes.realName, "完成后出栈")
    }

    /// 一直 40901：不热循环（6 秒内至多 4 次），每次都是同一个键；期间不显示完成。
    func test40901DoesNotHotLoop() async throws {
        scriptUnverifiedThenVerified()
        script.on("POST \(Self.path)", .envelope(code: 40901, data: "null", headers: [:]))
        let fixture = make()
        let page = try await openFromWithdraw(fixture)
        fill(page)
        submitWithConsent(page)
        await awaitPosts(1)
        await quietWindow(6)
        let posts = realnamePosts
        XCTAssertLessThanOrEqual(posts.count, 4, "40901 不热循环")
        XCTAssertEqual(Set(posts.compactMap { key($0) }).count, 1, "始终同一个键")
        XCTAssertNil(page.state.done)
        XCTAssertFalse(fixture.wallet.realnameVerified())
    }

    /// 结果未知（断连）后表单不变再提交：沿用原键、原请求体（契约：超时后的重试沿用原键拿第一次的结果）。
    func testUnknownResultResubmitReusesKey() async throws {
        scriptUnverifiedThenVerified()
        script.on("POST \(Self.path)", .disconnect, Self.success)
        let fixture = make()
        let page = try await submitOnce(fixture)
        XCTAssertFalse(fixture.wallet.realnameVerified(), "结果未知不当成功")
        XCTAssertNil(page.state.done)
        await waitUntil("结果未知后没有恢复可提交") { page.submitEnabled }
        submitWithConsent(page)
        await awaitPosts(2)
        let posts = realnamePosts
        guard posts.count >= 2 else { return }
        XCTAssertEqual(key(posts[0]), key(posts[1]), "结果未知后沿用原键")
        XCTAssertTrue(posts[0].body == posts[1].body, "原请求体（不打印）")
        await waitUntil("原键拿到成功后没有完成") { fixture.wallet.realnameVerified() }
    }

    /// D10-887 ③：断连 → 用户改表单 → 换新幂等键（旧键作废）→ 新键回 200（已实名类结果）→ 按成功处理、刷新实名状态、出栈。
    /// 同一个键绝不配不同的请求体（否则 20901）。前提（按钮可用）不成立就红，不许空过。
    func testUnknownThenEditedFormUsesNewKeyAndSucceeds() async throws {
        scriptUnverifiedThenVerified()
        script.on("POST \(Self.path)", .disconnect, Self.success)
        let fixture = make()
        let page = try await submitOnce(fixture)
        await waitUntil("结果未知后没有恢复可提交") { page.submitEnabled }
        fill(page, name: "测试实名乙", idNo: "110105194912310011")
        XCTAssertTrue(page.submitEnabled, "改表单后应可再次提交（D10-887 ③）")
        submitWithConsent(page)
        await awaitPosts(2)
        let posts = realnamePosts
        guard posts.count >= 2 else { return }
        XCTAssertNotEqual(key(posts[0]), key(posts[1]), "改了表单：旧键作废、换新键（D10-887 ③）")
        XCTAssertFalse(posts[0].body == posts[1].body, "第二次是改过的表单（不打印）")
        for later in posts.dropFirst() where key(later) == key(posts[0]) {
            XCTAssertTrue(later.body == posts[0].body, "同一个幂等键配了不同的请求体")
        }
        let second = posts[1].id
        await waitUntil("新键回 200 没有按成功") { fixture.wallet.realnameVerified() }
        await waitUntil("成功后没有复查 GET /v1/me") { self.meGets.contains { $0.id > second } }
        await waitUntil("成功后没有出栈") { fixture.router.path.last?.route != WalletRoutes.realName }
    }

    /// 写入幂等结果的业务错误（30406）后改表单再提交：用新键（原键会拿回同一个 30406 或 20901）。
    func testBusinessErrorThenCorrectedFormUsesNewKey() async throws {
        scriptUnverifiedThenVerified()
        script.on("POST \(Self.path)", .envelope(code: 30406, data: "null", headers: [:]), Self.success)
        let fixture = make()
        let page = try await submitOnce(fixture)
        XCTAssertEqual(page.state.error?.key, "error.30406")
        fill(page, name: "测试实名乙", idNo: "110105194912310011")
        XCTAssertNil(page.state.error, "改输入后错误条消失")
        submitWithConsent(page)
        await awaitPosts(2)
        let posts = realnamePosts
        guard posts.count >= 2 else { return }
        XCTAssertNotEqual(key(posts[0]), key(posts[1]), "更正后用新键")
        await waitUntil("新键成功后没有完成") { fixture.wallet.realnameVerified() }
    }

    /// 提交在途时换账号：A 的成功结果不让 B 按已实名放行，B 进提现仍被送进实名页（结果归属，共性第 52、65 条）。
    func testResultOfOldAccountDoesNotVerifyNewAccount() async throws {
        scriptAlwaysUnverified()
        script.on("POST \(Self.path)", .hold)
        let fixture = make()
        let page = try await openFromWithdraw(fixture)
        fill(page)
        submitWithConsent(page)
        await awaitPosts(1)
        fixture.router.path.removeAll()
        try fixture.switchAccount(to: "user-b")
        for held in WalletStubProtocol.heldIds {
            WalletStubProtocol.release(held, with: Self.success)
        }
        await quietWindow(1.0)
        XCTAssertFalse(fixture.wallet.realnameVerified(), "A 的实名结果记到了 B 名下")
        _ = try await openFromWithdraw(fixture)
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.realName, "B 未实名仍先实名")
    }
}
