import Foundation
import Generated
@testable import Network
import Session
import XCTest

/// F-AND-10（APP-03a-android R5-01，三端核对）：清会话的隔离只在确认旧会话已删、或已被成功保存的新会话替换后才解除；
/// 写入失败（登录令牌没保存成功）不解除隔离，旧令牌继续被阻断。以及 APP-03b 给 ApiCall 加的 If-None-Match 与响应头带回。
final class SessionIsolationFollowupTests: XCTestCase {
    private func meCall() -> ApiCall {
        ApiCall(operationId: "getMe")
    }

    private func bearers() -> [String] {
        StubURLProtocol.requests.compactMap { $0.header("Authorization") }
    }

    func testClearFailureWithConcurrentLoginSaveFailureKeepsOldTokenBlocked() async {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let harness = makeHarness(tokens: tokens)
        StubURLProtocol.install { request in
            request.path.hasPrefix("/v1/auth/login") ? ok(loginData(access: "access-new", scope: "full")) : ok()
        }

        // 清会话（退出登录）时删除失败：旧会话在内存里作废。
        tokens.failClears = true
        harness.client.signOut()
        // 同时一次登录拿到令牌，但写进安全存储失败（写入失败造成的世代变化不能解除隔离）。
        tokens.failSaves = true
        let login = await harness.client.send(ApiCall(operationId: "loginBySms", body: "{\"phone\":\"13800138000\"}"))
        guard case let .sessionNotSaved(reason, _) = login else {
            return XCTFail("令牌没保存成功不算登录成功：\(login)")
        }
        XCTAssertEqual(reason, LocalRejectReason.sessionSaveFailed)

        _ = await harness.client.send(meCall())
        XCTAssertFalse(bearers().contains("Bearer access-1"), "隔离未解除：旧令牌不得发出")
        XCTAssertEqual(tokens.accessToken, "access-1", "条目仍在（删除一直失败）")

        // 删除仍失败，但新登录保存成功 → 被新会话替换，隔离解除，用新令牌。
        tokens.failSaves = false
        let relogin = await harness.client.send(ApiCall(operationId: "loginBySms", body: "{\"phone\":\"13800138000\"}"))
        XCTAssertTrue(relogin.isSuccess)
        _ = await harness.client.send(meCall())
        XCTAssertEqual(bearers().last, "Bearer access-new")
        XCTAssertFalse(bearers().contains("Bearer access-1"))
    }

    func testIsolationLiftsOnlyAfterConfirmedDeletion() async {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let harness = makeHarness(tokens: tokens)
        StubURLProtocol.install { _ in ok() }
        tokens.failClears = true
        harness.client.signOut()
        _ = await harness.client.send(meCall())
        XCTAssertTrue(bearers().isEmpty, "删除失败期间不带旧令牌")

        tokens.failClears = false
        _ = await harness.client.send(meCall())
        XCTAssertNil(tokens.accessToken, "读取时重试删除成功")
        XCTAssertTrue(bearers().isEmpty)
    }

    /// APP-03b 共性 9：埋点的 user_id 取经过隔离判断的账号；隔离中、读取失败时为空。
    func testIsolatedAccountIsEmptyWhileIsolatedOrUnreadable() {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let harness = makeHarness(tokens: tokens)
        XCTAssertEqual(harness.client.isolatedAccount, "account-A")
        tokens.failReads = .readFailed
        XCTAssertNil(harness.client.isolatedAccount, "读取失败为空")
        tokens.failReads = nil
        tokens.failClears = true
        harness.client.signOut()
        XCTAssertNil(harness.client.isolatedAccount, "隔离中为空")
        XCTAssertEqual(tokens.account, "account-A", "条目仍在")
    }

    func testIfNoneMatchIsSentVerbatimOnReadsAndResponseHeadersComeBack() async {
        let harness = makeHarness()
        StubURLProtocol.install { request in
            request.header("If-None-Match") == "W/\"cfg-2\""
                ? .json(status: 304, headers: ["ETag": "W/\"cfg-2\""], body: "")
                : ok("{}", headers: ["ETag": "\"cfg-3\""])
        }
        let (result, meta) = await harness.client.sendWithResponseHeaders(
            ApiCall(operationId: "getConfig", ifNoneMatch: "W/\"cfg-2\"")
        )
        XCTAssertEqual(StubURLProtocol.requests.first?.header("If-None-Match"), "W/\"cfg-2\"")
        XCTAssertEqual(meta.httpStatus, 304)
        if case let .transportFailure(_, status, _, _) = result {
            XCTAssertEqual(status, 304)
        } else {
            XCTFail("304 没有统一外壳：\(result)")
        }
        let (fresh, freshMeta) = await harness.client.sendWithResponseHeaders(ApiCall(operationId: "getConfig"))
        XCTAssertTrue(fresh.isSuccess)
        XCTAssertEqual(freshMeta.header("etag"), "\"cfg-3\"")
        XCTAssertNil(StubURLProtocol.requests.last?.header("If-None-Match"))

        _ = await harness.client.send(ApiCall(operationId: "logout", ifNoneMatch: "\"x\""))
        XCTAssertNil(StubURLProtocol.requests.last?.header("If-None-Match"), "写接口不带 If-None-Match")
    }
}
