@testable import Couli
import CouliNetwork
import Foundation
import Wallet
import WalletCore
import XCTest

/// 实名提交的请求（契约 submitRealname / recordConsent；BR-ID-25 先弹实名单独同意）：生产接线发 POST /v1/me/realname，请求体只有
/// name、id_no（规范化后），带签名与幂等键；同意记录在前、成功后才提交；防抖。
final class RealnameFundsRequestTests: RealnameFundsTestCase {
    /// 生产接线（不装 Debug 假服务）：实名页可用，输入框与【提交认证】不再置灰（staging 联调 P2，N-32 空实现去掉）。
    func testProductionWiringIsAvailable() async throws {
        scriptUnverifiedThenVerified()
        let fixture = make()
        let page = try await openFromWithdraw(fixture)
        XCTAssertTrue(page.available, "生产接线下实名页仍是「暂未开放」（N-32 空实现）")
        XCTAssertFalse(page.submitEnabled, "未填写时不可提交")
        fill(page)
        XCTAssertTrue(page.submitEnabled, "填好后【提交认证】可用")
    }

    /// 请求体与头：POST /v1/me/realname，请求体恰好 {name, id_no}（姓名去首尾空白、x 转大写），带幂等键、签名与登录态。
    func testSubmitBodyAndHeaders() async throws {
        scriptUnverifiedThenVerified()
        let fixture = make()
        _ = try await submitOnce(fixture)
        XCTAssertEqual(realnamePosts.count, 1, "只发一次")
        let post = try XCTUnwrap(realnamePosts.first)
        let json = body(post)
        XCTAssertEqual(Set(json.keys), ["name", "id_no"], "请求体只有 name、id_no（additionalProperties false）")
        XCTAssertTrue(json["name"] as? String == Self.name, "姓名去首尾空白（不打印值）")
        XCTAssertTrue(json["id_no"] as? String == Self.idNo, "身份证号 x 转大写（不打印值）")
        let idem = try XCTUnwrap(key(post), "缺 Idempotency-Key（契约 x-idempotent）")
        XCTAssertNotNil(idem.range(of: "^[A-Za-z0-9_-]{8,64}$", options: .regularExpression), "幂等键格式")
        for name in ["X-Sign", "X-Timestamp", "X-Nonce"] {
            XCTAssertFalse((post.header(name) ?? "").isEmpty, "缺签名头 \(name)（契约 x-signed）")
        }
        XCTAssertTrue(post.header("Authorization")?.hasPrefix("Bearer ") == true, "缺登录态")
        XCTAssertTrue(post.query.isEmpty, "不带查询串")
    }

    /// BR-ID-25：实名单独同意记 POST /v1/consents
    /// {type: id_verification, accepted: true, channel: realname_sheet, version, client_at}，在实名提交之前。
    func testConsentRecordedBeforeSubmit() async throws {
        scriptUnverifiedThenVerified()
        let fixture = make()
        _ = try await submitOnce(fixture)
        XCTAssertEqual(consentPosts.count, 1, "同意记录发一次")
        let consent = try XCTUnwrap(consentPosts.first)
        let json = body(consent)
        XCTAssertEqual(Set(json.keys), ["type", "version", "accepted", "channel", "client_at"])
        XCTAssertEqual(json["type"] as? String, "id_verification")
        XCTAssertEqual(json["accepted"] as? Bool, true)
        XCTAssertEqual(json["channel"] as? String, "realname_sheet")
        let version = json["version"] as? Int
        XCTAssertTrue((version ?? 0) >= 1, "version 是正整数")
        XCTAssertFalse((json["client_at"] as? String ?? "").isEmpty, "client_at 是点击时刻")
        XCTAssertFalse(leaks(consent.body), "同意记录不带姓名 / 身份证号")
        let post = try XCTUnwrap(realnamePosts.first)
        XCTAssertLessThan(consent.id, post.id, "同意记录在实名提交之前")
    }

    /// 同意记录没有结果之前不发实名提交；成功后才发。
    func testSubmitWaitsForConsentResult() async throws {
        scriptUnverifiedThenVerified()
        script.on("POST /v1/consents", .hold)
        let fixture = make()
        let page = try await openFromWithdraw(fixture)
        fill(page)
        submitWithConsent(page)
        await waitUntil("同意记录没有发出") { !self.consentPosts.isEmpty }
        await quietWindow(1.0)
        XCTAssertTrue(realnamePosts.isEmpty, "同意记录在途时不发实名提交")
        XCTAssertFalse(page.submitEnabled, "同意记录在途时按钮锁住")
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: "{}", headers: [:]))
        await awaitPosts(1)
    }

    /// 同意记录失败（服务端错误 / 断连）：不发实名提交，给出错误，可以再点。
    func testConsentFailureSendsNoSubmit() async throws {
        for reply in [WalletStubProtocol.Reply.envelope(code: 50001, data: "null", headers: [:]), .disconnect] {
            WalletStubProtocol.reset()
            script.install()
            scriptUnverifiedThenVerified()
            script.on("POST /v1/consents", reply)
            let fixture = make()
            let page = try await openFromWithdraw(fixture)
            fill(page)
            submitWithConsent(page)
            await waitUntil("同意记录没有发出") { !self.consentPosts.isEmpty }
            await quietWindow(1.0)
            XCTAssertTrue(realnamePosts.isEmpty, "同意没记上不发实名提交")
            XCTAssertNotNil(page.state.error, "同意记录失败要提示")
            XCTAssertTrue(page.submitEnabled, "同意记录失败后可以再点")
            XCTAssertFalse(fixture.wallet.realnameVerified())
        }
    }

    /// 【暂不认证】：同意与提交都不发；勾选之前点【同意并继续】也不发。
    func testDeclineOrUncheckedSendsNothing() async throws {
        scriptUnverifiedThenVerified()
        let fixture = make()
        let page = try await openFromWithdraw(fixture)
        fill(page)
        RealNameActions.make(page, page.state).submit()
        XCTAssertNotNil(page.state.consentId, "先弹单独同意")
        RealNameActions.make(page, page.state).agree()
        RealNameActions.make(page, page.state).decline()
        XCTAssertNil(page.state.consentId)
        await quietWindow(1.0)
        XCTAssertTrue(consentPosts.isEmpty, "没勾选 / 暂不认证：不记同意")
        XCTAssertTrue(realnamePosts.isEmpty, "没勾选 / 暂不认证：不提交")
    }

    /// 防抖：【同意并继续】连点、提交在途时再点【提交认证】→ 同意与提交各只发一次，在途时不再弹半屏。
    func testRepeatedTapsSendOnce() async throws {
        scriptUnverifiedThenVerified()
        script.on("POST \(Self.path)", .hold)
        let fixture = make()
        let page = try await openFromWithdraw(fixture)
        fill(page)
        RealNameActions.make(page, page.state).submit()
        RealNameActions.make(page, page.state).toggleConsent()
        let rendered = RealNameActions.make(page, page.state)
        rendered.agree()
        rendered.agree()
        await awaitPosts(1)
        RealNameActions.make(page, page.state).submit()
        XCTAssertNil(page.state.consentId, "提交在途不再弹单独同意")
        XCTAssertFalse(page.submitEnabled, "提交在途按钮锁住")
        await quietWindow(1.0)
        XCTAssertEqual(consentPosts.count, 1, "同意只记一次")
        XCTAssertEqual(realnamePosts.count, 1, "实名只提交一次")
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: Self.success)
        await waitUntil("成功后没有出栈") { fixture.router.path.last?.route != WalletRoutes.realName }
    }

    /// 格式不对（17 位）：不可提交，点了不弹半屏、不发请求（格式最终由服务端判，客户端只挡明显不全的）。
    func testIncompleteFormSendsNothing() async throws {
        scriptUnverifiedThenVerified()
        let fixture = make()
        let page = try await openFromWithdraw(fixture)
        fill(page, idNo: "11010519491231002")
        XCTAssertFalse(page.submitEnabled)
        RealNameActions.make(page, page.state).submit()
        XCTAssertNil(page.state.consentId)
        await quietWindow(0.5)
        XCTAssertTrue(consentPosts.isEmpty)
        XCTAssertTrue(realnamePosts.isEmpty)
    }
}
