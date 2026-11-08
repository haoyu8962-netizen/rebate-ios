@testable import Couli
import CouliNetwork
import Foundation
import Wallet
import WalletCore
import XCTest

/// 实名提交的结果分流（specs/realname-submit-vectors.json，三端共用；判读规则见向量文件 harness）：成功、字段错误下到字段、3xxxx 业务错误、
/// 限流、5xxxx（50301 不显示「{platform_name}维护中」）、前置条件（10004 / 10005 / 10010 / 10001 / 10405）、传输失败。
final class RealnameFundsOutcomeTests: RealnameFundsTestCase {
    /// 本类覆盖的向量（加向量必须加用例；e40901_busy 在 RealnameFundsKeyTests）。
    static let covered = [
        "ok_verified", "e20001_field_id_no", "e20001_field_name", "e20001_no_fields", "e30405_taken", "e30406_mismatch",
        "e30407_age", "e30410_daily_limit", "e42901_rate_limited", "e50401_vendor_timeout",
        "e50301_service_unavailable", "e50001_server", "e10004_id_verification", "e10005_bind_phone",
        "e10010_reverify", "e10001_login", "e10405_force_update", "transport_lost",
    ]

    func testEveryVectorHasACase() throws {
        let names = try RealnameVectors.cases().compactMap { $0["name"] as? String }
        let dedicated = try RealnameVectors.cases().filter { $0["dedicated"] != nil }
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), Set(Self.covered + dedicated), "向量与用例不对应")
        XCTAssertEqual(names.count, Set(names).count, "向量重名")
    }

    func testOkVerified() async throws {
        try await runVector("ok_verified")
    }

    func testFieldErrorIdNo() async throws {
        try await runVector("e20001_field_id_no")
    }

    func testFieldErrorName() async throws {
        try await runVector("e20001_field_name")
    }

    func testFormatErrorWithoutFields() async throws {
        try await runVector("e20001_no_fields")
    }

    func testIdTaken() async throws {
        try await runVector("e30405_taken")
    }

    func testMismatch() async throws {
        try await runVector("e30406_mismatch")
    }

    func testAge() async throws {
        try await runVector("e30407_age")
    }

    func testDailyLimit() async throws {
        try await runVector("e30410_daily_limit")
    }

    func testRateLimited() async throws {
        try await runVector("e42901_rate_limited")
    }

    func testVendorTimeout() async throws {
        try await runVector("e50401_vendor_timeout")
    }

    func testServiceUnavailable() async throws {
        try await runVector("e50301_service_unavailable")
    }

    func testServerError() async throws {
        try await runVector("e50001_server")
    }

    func testConsentRequired() async throws {
        try await runVector("e10004_id_verification")
    }

    func testBindPhoneRequired() async throws {
        try await runVector("e10005_bind_phone")
    }

    func testReverifyRequired() async throws {
        try await runVector("e10010_reverify")
    }

    func testLoginRequired() async throws {
        try await runVector("e10001_login")
    }

    func testForceUpdate() async throws {
        try await runVector("e10405_force_update")
    }

    func testTransportLost() async throws {
        try await runVector("transport_lost")
    }

    // MARK: - 判读

    /// 断言定位（向量名 + 调用处）。
    private struct Site {
        let name: String
        let file: StaticString
        let line: UInt
    }

    private func runVector(_ name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let vector = try RealnameVectors.named(name)
        let expect = try XCTUnwrap(vector["expect"] as? [String: Any])
        let first = try RealnameVectors.reply(XCTUnwrap(vector["reply"] as? [String: Any]))
        scriptUnverifiedThenVerified()
        script.on("POST \(Self.path)", first, Self.success)
        let fixture = make()
        let page = try await submitOnce(fixture)
        let site = Site(name: name, file: file, line: line)
        checkDone(expect, page, fixture, site)
        checkBanner(expect, page, site)
        checkPage(expect, page, site)
        if expect["autoResend"] as? Bool == false {
            XCTAssertEqual(realnamePosts.count, 1, "\(name)：不自动重发", file: file, line: line)
        }
        if let next = expect["nextSubmit"] as? String {
            try await checkNext(next, reopen: expect["consentReopen"] as? Bool == true, page, site)
        }
    }

    private func checkDone(_ expect: [String: Any], _ page: RealNameController, _ fixture: WalletAppFixture,
                           _ site: Site) {
        let (name, file, line) = (site.name, site.file, site.line)
        guard let done = expect["done"] as? Bool else { return }
        XCTAssertEqual(fixture.wallet.realnameVerified(), done, "\(name)：本会话是否按已实名", file: file, line: line)
        let onPage = fixture.router.path.last?.route == WalletRoutes.realName
        if done {
            XCTAssertFalse(onPage, "\(name)：成功后出栈回发起页", file: file, line: line)
        } else {
            XCTAssertNil(page.state.done, "\(name)：不显示完成", file: file, line: line)
        }
        if expect["refreshMe"] as? Bool == true {
            let post = realnamePosts.first?.id ?? Int.max
            XCTAssertTrue(meGets.contains { $0.id > post }, "\(name)：成功后复查 GET /v1/me", file: file, line: line)
        }
    }

    private func checkBanner(_ expect: [String: Any], _ page: RealNameController, _ site: Site) {
        let (name, file, line) = (site.name, site.file, site.line)
        let error = page.state.error
        if expect.keys.contains("textKey") {
            if let key = expect["textKey"] as? String {
                XCTAssertEqual(error?.key, key, "\(name)：错误条文案键", file: file, line: line)
            } else {
                XCTAssertNil(error, "\(name)：不出错误条", file: file, line: line)
            }
        }
        if let banned = expect["textKeyNot"] as? [String] {
            XCTAssertNotNil(error, "\(name)：要有错误条", file: file, line: line)
            XCTAssertFalse(banned.contains(error?.key ?? ""), "\(name)：错误条键不能是 \(banned)", file: file, line: line)
        }
        if let trace = expect["trace6"] as? Bool {
            XCTAssertEqual(error?.showTrace6, trace, "\(name)：trace 后 6 位", file: file, line: line)
        }
        if expect["messageClean"] as? Bool == true {
            let message = error?.message(WalletDraftTexts()) ?? ""
            XCTAssertFalse(message.isEmpty, "\(name)：错误条有字", file: file, line: line)
            XCTAssertFalse(message.contains("{") || message.contains("}"), "\(name)：留了占位", file: file, line: line)
            XCTAssertFalse(message.hasPrefix("维护中"), "\(name)：缺主语的「维护中」", file: file, line: line)
        }
    }

    private func checkPage(_ expect: [String: Any], _ page: RealNameController, _ site: Site) {
        let (name, file, line) = (site.name, site.file, site.line)
        if let fields = expect["fieldErrors"] as? [String] {
            XCTAssertEqual(page.state.fieldErrors, fields, "\(name)：字段错误", file: file, line: line)
            if !fields.isEmpty {
                XCTAssertGreaterThan(page.state.fieldErrorId, 0, "\(name)：字段错误事件（首错定位）", file: file, line: line)
            }
        }
        if let locked = expect["lockedToday"] as? Bool {
            XCTAssertEqual(page.state.lockedToday, locked, "\(name)：当日锁定", file: file, line: line)
        }
        if let gate = expect["gateActive"] as? Bool {
            XCTAssertEqual(page.gate.active, gate, "\(name)：禁用期", file: file, line: line)
        }
        if let reopen = expect["consentReopen"] as? Bool {
            XCTAssertEqual(page.state.consentId != nil, reopen, "\(name)：重新弹单独同意", file: file, line: line)
        }
    }

    private func checkNext(_ next: String, reopen: Bool, _ page: RealNameController, _ site: Site) async throws {
        let (name, file, line) = (site.name, site.file, site.line)
        if next == "blocked" {
            XCTAssertFalse(page.submitEnabled, "\(name)：不能再提交", file: file, line: line)
            RealNameActions.make(page, page.state).submit()
            XCTAssertNil(page.state.consentId, "\(name)：点了也不弹半屏", file: file, line: line)
            await quietWindow(0.5)
            XCTAssertEqual(realnamePosts.count, 1, "\(name)：不发请求", file: file, line: line)
            return
        }
        if reopen {
            agree(page)
        } else {
            await waitUntil("\(name)：没有恢复可提交", file: file, line: line) { page.submitEnabled }
            submitWithConsent(page)
        }
        await awaitPosts(2, file: file, line: line)
        let posts = realnamePosts
        guard posts.count >= 2 else { return }
        XCTAssertTrue(posts[0].body == posts[1].body, "\(name)：表单未改，请求体一致（不打印）", file: file, line: line)
        let same = key(posts[0]) == key(posts[1])
        XCTAssertEqual(same, next == "same_key", "\(name)：再次提交的幂等键应为 \(next)", file: file, line: line)
    }
}
