import Foundation
@testable import Network
import Session
import XCTest

/// LOCK-ios 段 2 评审 S1：x-auth=optional 的接口「有令牌就带、没有就不带」（D10-1700）只给没固定账号的调用；调用方经
/// `send(_:isValid:sendAllowed:expected:)` 固定了账号（`RequestOwnership.account != nil`）时，必须带着这个账号的令牌发出——
/// 会话读不出 / 没有令牌 / 账号不同都按 account_mismatch 本地结束、传输层零写出（`expectedMismatch(_:_:_:)`，每次重试都重走）。
/// D10-1704 (b)：固定账号核对扩到所有 x-auth——x-auth=none 的调用固定了账号时，读不出 / 没有会话 / 换了人同样 account_mismatch、零写出；
/// 编排点名三条规则覆盖 openLink 与 getLink（两者 x-auth 都是 optional，见 ApiOperations）。D10-1707：`sessionOnly` 只固定会话世代、不看账号。
/// D10-1709：会话读不出 = 身份未知——未声明 `sendsWhenIdentityUnknown` 的 optional 不论固定与否先按 session_unreadable 拒（1a、1b、5、7g、8 已改）；
/// 声明了的调用固定账号时仍按上面核对 account_mismatch（见 LockIosIdentityUnknownTests 6）。
/// 全部对 URLProtocol 本地假服务。
final class LockIosPinnedAccountTests: XCTestCase {
    static let refreshPath = "/v1/auth/refresh"
    static let smsPath = "/v1/auth/sms-codes"
    static let loginCode = "{\"purpose\":\"login\"}"

    /// 固定了账号的 optional 调用方：返利链接（openLink，POST、签名）、链接详情（getLink，GET、不签名；D10-1704 编排点名与 openLink
    /// 同三条规则，ApiOperations 里 x-auth=optional）与首页数据（getPage，GET）。下面 1–5 条对三者逐个跑。
    static let optionalCalls = [
        ApiCall(operationId: "openLink", pathParams: ["link_id": "abc"], body: "{\"no_rebate\":false}"),
        ApiCall(operationId: "getLink", pathParams: ["link_id": "abc"]),
        ApiCall(operationId: "getPage", pathParams: ["page_key": "home"]),
    ]

    /// x-auth=none 的调用方（listArticles，GET，路径 /v1/articles）。
    static let noneCall = ApiCall(operationId: "listArticles")
    static let articlesPath = "/v1/articles"

    private func send(_ harness: Harness, _ call: ApiCall, _ expected: RequestOwnership?) async -> ApiResult {
        await harness.client.send(call, isValid: { true }, sendAllowed: { true }, expected: expected)
    }

    // MARK: - 1. 固定账号 × 会话读不出

    /// 1a. 段 2 评审 S1 / D10-1700 / D10-1704（编排点名三条之一）：optional（openLink、getLink、getPage）× 固定账号 A ×
    /// 会话读不出 → 传输层零写出（不退成匿名发出）。
    /// D10-1709（改前 account_mismatch → 改后 session_unreadable）：会话读不出 = 身份未知，三者都没声明 sendsWhenIdentityUnknown，
    /// prepare 先按 session_unreadable 拒（同要会话的接口，见 6），走不到固定账号核对。声明了的调用固定账号见 LockIosIdentityUnknownTests 6a。
    func testPinnedOptionalWithUnreadableSessionIsSessionUnreadable() async {
        for call in Self.optionalCalls {
            let harness = makeHarness()
            StubURLProtocol.install { _ in ok() }
            let pinned = harness.client.currentOwnership(credentialsReadable: true)
            XCTAssertEqual(pinned.account, "account-A")
            harness.tokens.failReads = .readFailed
            let result = await send(harness, call, pinned)
            XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionUnreadable, "\(call.operationId)：\(result)")
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, "\(call.operationId)：固定了账号不得匿名发出")
        }
    }

    /// 1b. 段 2 评审 S1 / D10-1700 / D10-1704（含 getLink）：同上，但本机是冷启动 deletion_only 会话（屏障到期）——optional 不等受限会话屏障、
    /// 不由它触发刷新（零 /v1/auth/refresh），直接本地结束、零写出；会话不动。
    /// D10-1709（改前 account_mismatch → 改后 session_unreadable）：身份未知、未声明，按 session_unreadable 本地拒。
    func testPinnedOptionalWithUnreadableRestrictedSessionSkipsBarrier() async {
        for call in Self.optionalCalls {
            let harness = makeHarness(tokens: restrictedSession())
            StubURLProtocol.install { request in
                request.path == Self.refreshPath ? ok(refreshData(access: "access-2")) : ok()
            }
            let pinned = harness.client.currentOwnership(credentialsReadable: true)
            XCTAssertEqual(pinned.account, "account-A")
            harness.tokens.failReads = .readFailed
            let result = await send(harness, call, pinned)
            XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionUnreadable, "\(call.operationId)：\(result)")
            XCTAssertTrue(StubURLProtocol.requests(path: Self.refreshPath).isEmpty, "\(call.operationId)：零刷新")
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, "\(call.operationId)：零写出")
            XCTAssertEqual(harness.client.refreshCalls, 0, "\(call.operationId)：没有起刷新窗口")
            harness.tokens.failReads = nil
            XCTAssertEqual(harness.tokens.accessToken, "access-1", "\(call.operationId)：本地拒绝不动会话")
        }
    }

    // MARK: - 2. 固定账号 × 会话可读、账号一致

    /// 2. 段 2 评审 S1 / D10-1700 / D10-1704（含 getLink）：optional × 固定 A × 会话可读、账号 A、有令牌 → 照常发出，带 Authorization: Bearer。
    func testPinnedOptionalWithMatchingSessionSendsWithBearer() async {
        for call in Self.optionalCalls {
            let harness = makeHarness()
            StubURLProtocol.install { _ in ok() }
            let pinned = harness.client.currentOwnership(credentialsReadable: true)
            let result = await send(harness, call, pinned)
            XCTAssertTrue(result.isSuccess, "\(call.operationId)：\(result)")
            XCTAssertEqual(StubURLProtocol.requests.count, 1, call.operationId)
            XCTAssertEqual(StubURLProtocol.requests.first?.header("Authorization"), "Bearer access-1", call.operationId)
        }
    }

    // MARK: - 3. 固定账号 × 有会话但没有 access 令牌

    /// 3. 段 2 评审 S1 / D10-1700 / D10-1704（含 getLink）：optional × 固定 A × 有会话（账号 A、有 refresh）但没有 access 令牌，会话世代不变 →
    /// 组请求时没带上 Authorization，按 account_mismatch 结束、零写出，也不为此先刷新。
    /// 桩：`MemorySessionTokens(access: nil, refresh:, account: "account-A")` 存成空 access，读出为 access == nil 的会话；
    /// 固定归属在同一个客户端上取，世代即当前世代。
    func testPinnedOptionalWithSessionButNoAccessTokenIsAccountMismatch() async {
        for call in Self.optionalCalls {
            let tokens = MemorySessionTokens(access: nil, refresh: "refresh-1", scope: "full", account: "account-A")
            let harness = makeHarness(tokens: tokens)
            StubURLProtocol.install { _ in ok() }
            let pinned = harness.client.currentOwnership(credentialsReadable: true)
            XCTAssertEqual(pinned.account, "account-A", "账号读得出，只是没有 access")
            // 桩存空 access 后读出为空串（不是 nil）：前提只要求「没有可用的 access」
            XCTAssertTrue((harness.tokens.accessToken ?? "").isEmpty)
            let result = await send(harness, call, pinned)
            XCTAssertEqual(result.rejectReason, LocalRejectReason.accountMismatch, "\(call.operationId)：\(result)")
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, "\(call.operationId)：零写出（含零刷新）")
        }
    }

    // MARK: - 4. 固定账号 × 会话账号是 B

    /// 4. 段 2 评审 S1 / D10-1700 / D10-1704（编排点名三条之二，含 getLink）：optional × 固定 A × 会话账号是 B
    /// （同一会话世代：直接写存储，不经客户端换代）→ account_mismatch、零写出。
    func testPinnedOptionalWithOtherAccountIsAccountMismatch() async throws {
        for call in Self.optionalCalls {
            let harness = makeHarness()
            StubURLProtocol.install { _ in ok() }
            let pinned = harness.client.currentOwnership(credentialsReadable: true)
            try harness.tokens.save(access: "access-b", refresh: "refresh-b", scope: "full", account: "account-B")
            XCTAssertEqual(harness.client.currentOwnership(credentialsReadable: true).generation, pinned.generation)
            let result = await send(harness, call, pinned)
            XCTAssertEqual(result.rejectReason, LocalRejectReason.accountMismatch, "\(call.operationId)：\(result)")
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, call.operationId)
        }
    }

    // MARK: - 5. 未固定账号 × 读不出（D10-1709 翻转）

    /// 5. D10-1700 / D10-1704（编排点名三条之三，含 getLink）/ 段 2 评审 S1：没固定账号的 optional——不传 expected，
    /// 或 expected.account 为 nil（固定时凭据不可读）——会话读不出时……
    /// D10-1709（改前「照常不带令牌发出」→ 改后 session_unreadable、零发送）：会话读不出 = 身份未知，openLink / getLink / getPage
    /// 都没声明 sendsWhenIdentityUnknown，缺省本地拒；确认游客（没有会话）照发见 7f。
    func testUnpinnedOptionalWithUnreadableSessionIsSessionUnreadable() async {
        for call in Self.optionalCalls {
            for pinAccountless in [false, true] {
                let harness = makeHarness()
                StubURLProtocol.install { _ in ok() }
                let expected = pinAccountless ? harness.client.currentOwnership(credentialsReadable: false) : nil
                XCTAssertNil(expected?.account)
                harness.tokens.failReads = .readFailed
                let label = "\(call.operationId) expected=\(pinAccountless ? "无账号" : "nil")"
                let result = await send(harness, call, expected)
                XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionUnreadable, "\(label)：\(result)")
                XCTAssertTrue(StubURLProtocol.requests.isEmpty, "\(label)：零发送")
            }
        }
    }

    // MARK: - 6. required × 固定账号 × 读不出

    /// 6. 段 2 评审 S1 / D10-1700 / D10-1704（required 读不出仍先报 session_unreadable）：要会话的接口（getMe）× 固定 A ×
    /// 会话读不出 → 仍是 session_unreadable（prepare 先拒），不能变成 account_mismatch；零写出。
    func testRequiredWithPinnedAccountAndUnreadableSessionStaysSessionUnreadable() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok() }
        let pinned = harness.client.currentOwnership(credentialsReadable: true)
        harness.tokens.failReads = .readFailed
        let result = await send(harness, ApiCall(operationId: "getMe"), pinned)
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionUnreadable, "\(result)")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: - 7. none × 固定账号（D10-1704 (b)：固定账号核对扩到 none）

    /// 7a. D10-1704 (b)（翻转原「none × 固定 A × 读不出 → 匿名照发」）：x-auth=none（listArticles）× 固定 A × 会话读不出 →
    /// account_mismatch、传输层零写出（与 Android `pendingAccount` 对 `session?.userId` 的核对同口径）。
    func testNoneWithPinnedAccountAndUnreadableSessionIsAccountMismatch() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok() }
        let pinned = harness.client.currentOwnership(credentialsReadable: true)
        XCTAssertEqual(pinned.account, "account-A")
        harness.tokens.failReads = .readFailed
        let result = await send(harness, Self.noneCall, pinned)
        XCTAssertEqual(result.rejectReason, LocalRejectReason.accountMismatch, "\(result)")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "固定了账号的 none 调用读不出会话不得发出")
    }

    /// 7b. D10-1704 (b)：none × 未固定账号 → 照常不带令牌发出；会话读得出、读不出两种都发。「未固定」= 不传 expected、
    /// expected.account 为 nil（固定时凭据不可读，只在读不出时用：读得出时它要求「此刻没有账号」，见 7e）、`sessionOnly`（D10-1707）。
    func testNoneWithoutPinnedAccountSendsWhetherReadableOrNot() async {
        for unreadable in [false, true] {
            for mode in ["nil", "无账号", "sessionOnly"] where !(mode == "无账号" && !unreadable) {
                let harness = makeHarness()
                StubURLProtocol.install { _ in ok() }
                let expected: RequestOwnership? = switch mode {
                case "无账号": harness.client.currentOwnership(credentialsReadable: false)
                case "sessionOnly": harness.client.currentOwnership(credentialsReadable: true).sessionOnly
                default: nil
                }
                if unreadable {
                    harness.tokens.failReads = .readFailed
                }
                let label = "expected=\(mode) \(unreadable ? "读不出" : "读得出")"
                let result = await send(harness, Self.noneCall, expected)
                XCTAssertTrue(result.isSuccess, "\(label)：\(result)")
                XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Self.articlesPath], label)
                XCTAssertNil(StubURLProtocol.requests.first?.header("Authorization"), "\(label)：none 不带令牌")
            }
        }
    }

    /// 7c. D10-1704 (b)：none × 固定 A × 会话读得出、账号 A → 成功；none 不带 Authorization（只核账号，不要求带令牌）。
    func testNoneWithPinnedMatchingAccountSendsWithoutAuthorization() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok() }
        let pinned = harness.client.currentOwnership(credentialsReadable: true)
        XCTAssertEqual(pinned.account, "account-A")
        let result = await send(harness, Self.noneCall, pinned)
        XCTAssertTrue(result.isSuccess, "\(result)")
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Self.articlesPath])
        XCTAssertNil(StubURLProtocol.requests.first?.header("Authorization"))
    }

    /// 7d. D10-1704 (b)：none × 固定 A × 同一会话世代里存储变成账号 B（直接写存储，不经客户端换代）或被清空（没有会话）→
    /// account_mismatch、零写出。
    func testNoneWithPinnedAccountAndOtherOrNoSessionIsAccountMismatch() async throws {
        for cleared in [false, true] {
            let harness = makeHarness()
            StubURLProtocol.install { _ in ok() }
            let pinned = harness.client.currentOwnership(credentialsReadable: true)
            if cleared {
                try harness.tokens.clear()
            } else {
                try harness.tokens.save(access: "access-b", refresh: "refresh-b", scope: "full", account: "account-B")
            }
            let label = cleared ? "没有会话" : "账号 B"
            let generation = harness.client.currentOwnership(credentialsReadable: true).generation
            XCTAssertEqual(generation, pinned.generation, "\(label)：世代不变")
            let result = await send(harness, Self.noneCall, pinned)
            XCTAssertEqual(result.rejectReason, LocalRejectReason.accountMismatch, "\(label)：\(result)")
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, label)
        }
    }

    /// 7e. D10-1704 (b)（口径不回退）：固定时没有可读会话（expected.account == nil、pinsAccount 缺省 true）的 none 调用，
    /// 此刻读到有账号的会话 → 照旧 account_mismatch、零写出。
    func testNoneWithAccountlessPinAndReadableSessionStaysAccountMismatch() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok() }
        let accountless = harness.client.currentOwnership(credentialsReadable: false)
        XCTAssertNil(accountless.account)
        XCTAssertTrue(accountless.pinsAccount)
        let result = await send(harness, Self.noneCall, accountless)
        XCTAssertEqual(result.rejectReason, LocalRejectReason.accountMismatch, "\(result)")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: - 7'. 游客态 × optional（openLink / getLink / getPage）

    /// 7f. D10-1704（编排点名三条之三）：游客态（本机没有会话）× optional——不传 expected，或固定归属取自游客态（account == nil）——
    /// 照常不带令牌发出。
    func testGuestOptionalSendsAnonymously() async {
        for call in Self.optionalCalls {
            for pin in [false, true] {
                let harness = makeHarness(tokens: MemorySessionTokens())
                StubURLProtocol.install { _ in ok() }
                let expected = pin ? harness.client.currentOwnership(credentialsReadable: true) : nil
                XCTAssertNil(expected?.account)
                let label = "\(call.operationId) \(pin ? "游客态固定" : "未固定")"
                let result = await send(harness, call, expected)
                XCTAssertTrue(result.isSuccess, "\(label)：\(result)")
                XCTAssertEqual(StubURLProtocol.requests.count, 1, label)
                XCTAssertNil(StubURLProtocol.requests.first?.header("Authorization"), label)
            }
        }
    }

    // MARK: - 7''. sessionOnly（D10-1707）

    /// 7g. D10-1707 ①：`sessionOnly` 只固定会话世代与作废世代，不看账号——none（listArticles）在会话读不出时照常不带令牌发出；
    /// 同一世代里存储换成账号 B 时两者都照常发出（optional 带 B 的令牌）。
    /// D10-1709（改前 getLink × 读不出「照常匿名发出」→ 改后 session_unreadable、零发送）：getLink 未声明 sendsWhenIdentityUnknown，
    /// 身份未知缺省本地拒；sessionOnly 不改变这一点。listArticles（none）不受影响。
    func testSessionOnlyIgnoresAccountForOptionalAndNone() async throws {
        let calls = [Self.optionalCalls[1], Self.noneCall]
        for call in calls {
            for unreadable in [true, false] {
                let harness = makeHarness()
                StubURLProtocol.install { _ in ok() }
                let owner = harness.client.currentOwnership(credentialsReadable: true).sessionOnly
                if unreadable {
                    harness.tokens.failReads = .readFailed
                } else {
                    try harness.tokens.save(
                        access: "access-b", refresh: "refresh-b", scope: "full", account: "account-B"
                    )
                }
                let label = "\(call.operationId) \(unreadable ? "读不出" : "账号 B")"
                let result = await send(harness, call, owner)
                if unreadable, call.operationId != Self.noneCall.operationId {
                    XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionUnreadable, "\(label)：\(result)")
                    XCTAssertTrue(StubURLProtocol.requests.isEmpty, "\(label)：零发送")
                    continue
                }
                XCTAssertTrue(result.isSuccess, "\(label)：\(result)")
                XCTAssertEqual(StubURLProtocol.requests.count, 1, label)
                let bearer = !unreadable && call.operationId != Self.noneCall.operationId ? "Bearer access-b" : nil
                XCTAssertEqual(StubURLProtocol.requests.first?.header("Authorization"), bearer, label)
            }
        }
    }

    /// 7h. D10-1707 ①：`sessionOnly` 仍固定会话世代——之后经客户端退出（世代 +1）再发 → session_changed、零写出（optional 与 none）。
    func testSessionOnlyStillRejectsAfterSignOut() async {
        for call in [Self.optionalCalls[0], Self.noneCall] {
            let harness = makeHarness()
            StubURLProtocol.install { _ in ok() }
            let owner = harness.client.currentOwnership(credentialsReadable: true).sessionOnly
            harness.client.signOut()
            let result = await send(harness, call, owner)
            XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionChanged, "\(call.operationId)：\(result)")
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, call.operationId)
        }
    }

    // MARK: - 8. 重试时重走

    /// 8. 段 2 评审 S1 / D10-1700：optional × 固定 A，第一次超时，退避期间（重试前）会话变成读不出 → 重试那次零写出。
    /// D10-1709（改前 account_mismatch → 改后 session_unreadable）：重试时身份未知，getPage 未声明，prepare 先按 session_unreadable
    /// 拒。桩：getPage 是 GET，超时自动重试 1 次（退避 500 毫秒）；在注入的 sleeper（onSleep）里置 failReads。
    /// openLink 是写接口不自动重试，故只用 getPage。
    func testPinnedOptionalRetryAfterSessionBecomesUnreadableSendsNothing() async {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let harness = makeHarness(tokens: tokens, onSleep: { tokens.failReads = .readFailed })
        StubURLProtocol.install { _ in .error(.timedOut) }
        let pinned = harness.client.currentOwnership(credentialsReadable: true)
        let result = await send(harness, ApiCall(operationId: "getPage", pathParams: ["page_key": "home"]), pinned)
        XCTAssertEqual(harness.recorder.sleepCalls, [RetryPolicy.readBackoffMillis], "确实走到了重试")
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionUnreadable, "\(result)")
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "只有第一次（超时）写出，重试零写出")
        XCTAssertEqual(StubURLProtocol.requests.first?.header("Authorization"), "Bearer access-1")
    }

    // MARK: - 9. 旧受限令牌 10002 → 刷新 → 重放

    /// 9. 段 2 评审 S3-3 / D10-1700：冷启动 deletion_only，optional（sendSmsCode）不等屏障、带旧受限令牌 access-1 发出，
    /// 收到 10002 → 单飞刷新一次 → 用新令牌 access-2 重放一次成功。未固定与固定账号 A 两种调用方结果相同。
    func testOptionalWithStaleRestrictedTokenRefreshesOnceAndReplaysOn10002() async {
        for pin in [false, true] {
            let harness = makeHarness(tokens: restrictedSession())
            StubURLProtocol.install { request in
                if request.path == Self.refreshPath {
                    return ok(refreshData(access: "access-2", scope: SessionScope.deletionOnly))
                }
                return request.header("Authorization") == "Bearer access-2" ? ok() : fail(10002, status: 401)
            }
            let expected = pin ? harness.client.currentOwnership(credentialsReadable: true) : nil
            let label = pin ? "固定账号 A" : "未固定"
            let result = await send(harness, ApiCall(operationId: "sendSmsCode", body: Self.loginCode), expected)
            XCTAssertTrue(result.isSuccess, "\(label)：\(result)")
            XCTAssertEqual(
                StubURLProtocol.requests.map { "\($0.path) \($0.header("Authorization") ?? "-")" },
                ["\(Self.smsPath) Bearer access-1", "\(Self.refreshPath) -", "\(Self.smsPath) Bearer access-2"],
                label
            )
            XCTAssertEqual(StubURLProtocol.requests(path: Self.refreshPath).count, 1, "\(label)：刷新只发一次")
            XCTAssertEqual(harness.client.refreshCalls, 1, label)
            XCTAssertEqual(harness.tokens.accessToken, "access-2", label)
        }
    }
}
