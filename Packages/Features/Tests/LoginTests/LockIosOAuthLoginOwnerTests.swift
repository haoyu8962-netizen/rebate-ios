import CouliNetwork
import Foundation
@testable import Login
import Router
import Session
import XCTest

/// LOCK-ios 段 2：第三方登录的请求归属只固定会话世代与作废世代、不固定账号（D10-1707 ①，`RequestOwnership.sessionOnly`）。
/// 固定账号核对扩到所有 x-auth 之后（D10-1704 (b)），createOauthAttempt（x-auth=optional）与 loginBy*（x-auth=none）若仍固定账号，
/// 会话读不出 / 存着过期或受限会话时会被 account_mismatch 拦下；改成 sessionOnly 后照常发出。中途换人（另一账号登录、退出）一定换会话
/// 世代，仍由提交前复核（OAuthLoginService:152）与落盘前世代比对（`ApiClient.captureLogin`）拦住（D10-1703 / D10-1707）。
/// 桩写法同 OAuthLoginServiceTests：真实 ApiClient + LoginStubProtocol 本地假服务 + 真实 Router，只把第三方 SDK 换成 FakeAuthorizer；
/// 本机会话直接写 `harness.tokens`（`seedSession` 先经客户端退出换代，再写存储，之后世代不变），读不出用 `tokens.failReads`。
@MainActor
final class LockIosOAuthLoginOwnerTests: XCTestCase {
    private let consent: Int64 = 1_700_000_000_000
    private static let holdId = "login"

    /// 一种第三方登录：适配器、登录路径与授权凭证。
    private struct Flow {
        let provider: String
        let path: String
        let authorizer: FakeAuthorizer
        let credential: OAuthAuthorization
    }

    /// 微信与 Apple（OAuthHarness 只接了这两个适配器；华为没有可控适配器，见回报）。
    private func flows(_ harness: OAuthHarness) -> [Flow] {
        [
            Flow(
                provider: OAuthProvider.wechat, path: Paths.wechat, authorizer: harness.wechat,
                credential: .credential(.wechat(code: "code-from-sdk"))
            ),
            Flow(
                provider: OAuthProvider.apple, path: Paths.apple, authorizer: harness.apple,
                credential: .credential(.apple(identityToken: "id-token-1", authorizationCode: "auth-code-1"))
            ),
        ]
    }

    /// 假服务：取尝试照常回；登录请求 `holdLogin` 时挂起（测试 release），否则回 full 新号（user_id u1、at-1）。
    private func installServer(holdLogin: Bool = false) {
        LoginStubProtocol.install { request in
            switch request.path {
            case Paths.attempts: okReply(attemptData)
            case Paths.wechat where holdLogin, Paths.apple where holdLogin: .hold(Self.holdId)
            case Paths.wechat, Paths.apple: okReply(loginData(scope: "full", isNew: true))
            case Paths.me: okReply(meData(phoneBound: true))
            default: okReply()
            }
        }
    }

    private func start(_ harness: OAuthHarness, _ flow: Flow) -> Task<OAuthOutcome, Never> {
        let (consent, provider) = (consent, flow.provider)
        return Task { @MainActor in await harness.oauth.start(provider: provider, consentAtMillis: consent) }
    }

    private func releaseLogin() {
        LoginStubProtocol.release(Self.holdId, with: okReply(loginData(scope: "full", isNew: true)))
    }

    private func authorization(_ path: String) -> String? {
        LoginStubProtocol.requests(path: path).first?.headers["Authorization"]
    }

    /// 登录成功并落盘：新会话（u1 / at-1 / full）覆盖本机原有会话。
    private func assertLoggedInAndSaved(_ outcome: OAuthOutcome, _ harness: OAuthHarness, _ label: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.loggedIn, "\(label)：\(outcome)", file: file, line: line)
        XCTAssertEqual(harness.tokens.account, "u1", "\(label)：新会话落盘", file: file, line: line)
        XCTAssertEqual(harness.tokens.accessToken, "at-1", label, file: file, line: line)
        XCTAssertEqual(harness.tokens.scope, Session.SessionScope.full, label, file: file, line: line)
        XCTAssertEqual(harness.oauth.submittedCount, 1, label, file: file, line: line)
    }

    // MARK: - 1. 存着 A 的会话且读不出

    /// 1a. D10-1707 ① / D10-1704 (b)：本机存着账号 A 的会话，发起前就读不出（Keychain 读失败）→ createOauthAttempt 与 loginBy*
    /// 照常发出（都不带 Authorization：读不出就没有可带的令牌），登录成功落盘。微信、Apple 两种。
    /// 桩：seedSession(A) 后置 failReads；登录请求挂起，确认已写出后撤掉 failReads 再放行（落盘不读会话，撤掉只为之后断言能读存储）。
    /// 依据 D10-1710：createOauthAttempt purpose=login 已列入 sendsWhenIdentityUnknown 声明名单（OAuthLoginService.createAttempt
    /// 声明），所以会话读不出时 OAuth 登录的取尝试照常（匿名）发出，不按 session_unreadable 拒。
    func testUnreadableStoredSessionStillLogsIn() async throws {
        for index in 0..<2 {
            installServer(holdLogin: true)
            let harness = OAuthHarness()
            let flow = flows(harness)[index]
            try harness.seedSession(account: "A")
            harness.tokens.failReads = .readFailed
            let task = start(harness, flow)
            await harness.waitAuthorizing(flow.authorizer)
            XCTAssertEqual(LoginStubProtocol.requests(path: Paths.attempts).count, 1, "\(flow.provider)：取尝试照常发出")
            XCTAssertNil(authorization(Paths.attempts), flow.provider)
            flow.authorizer.complete(flow.credential)
            await waitUntil { LoginStubProtocol.isHeld(Self.holdId) }
            XCTAssertEqual(LoginStubProtocol.requests(path: flow.path).count, 1, "\(flow.provider)：登录照常发出")
            XCTAssertNil(authorization(flow.path), "\(flow.provider)：x-auth=none 不带令牌")
            harness.tokens.failReads = nil
            releaseLogin()
            let outcome = await task.value
            assertLoggedInAndSaved(outcome, harness, flow.provider)
        }
    }

    /// 1b. D10-1707 ① / D10-1704 (b)：发起时 A 的会话读得出（createOauthAttempt 带 A 的令牌），授权等待期间变成读不出（世代不变）→
    /// 提交前复核不判 stale（账号不参与比较），loginBy* 照常发出（不按 account_mismatch 拦），登录成功落盘。微信、Apple 两种。
    func testSessionBecomingUnreadableDuringAuthorizationStillLogsIn() async throws {
        for index in 0..<2 {
            installServer(holdLogin: true)
            let harness = OAuthHarness()
            let flow = flows(harness)[index]
            try harness.seedSession(account: "A")
            let generation = harness.client.sessionGeneration
            let task = start(harness, flow)
            await harness.waitAuthorizing(flow.authorizer)
            XCTAssertEqual(authorization(Paths.attempts), "Bearer at-0", "\(flow.provider)：optional 有令牌照常带")
            harness.tokens.failReads = .readFailed
            XCTAssertEqual(harness.client.sessionGeneration, generation, "读不出不换代")
            flow.authorizer.complete(flow.credential)
            await waitUntil { LoginStubProtocol.isHeld(Self.holdId) }
            XCTAssertEqual(LoginStubProtocol.requests(path: flow.path).count, 1, "\(flow.provider)：登录照常发出")
            harness.tokens.failReads = nil
            releaseLogin()
            let outcome = await task.value
            assertLoggedInAndSaved(outcome, harness, flow.provider)
        }
    }

    // MARK: - 2. 存着过期会话（旧账号）

    /// 2. D10-1707 ①：本机存着旧账号 old 的会话——(a) access 仍在（服务端视为过期，本地不知道），(b) 只剩 refresh、没有 access
    /// （固定账号时 optional 没带上该账号令牌即 account_mismatch，D10-1704）→ 两种都照常发出，新会话 u1 覆盖旧会话。微信。
    /// 桩：先经客户端退出换代，再直接写存储（(b) 存空 access，读出为 access == nil）。
    func testExpiredStoredSessionIsOverwritten() async throws {
        for hasAccess in [true, false] {
            installServer()
            let harness = OAuthHarness()
            let flow = flows(harness)[0]
            harness.client.signOut()
            try harness.tokens.save(
                access: hasAccess ? "at-old" : "", refresh: "rt-old", scope: Session.SessionScope.full, account: "old"
            )
            let label = hasAccess ? "旧 access 仍在" : "没有 access"
            XCTAssertEqual(harness.tokens.account, "old", label)
            let task = start(harness, flow)
            await harness.waitAuthorizing(flow.authorizer)
            XCTAssertEqual(LoginStubProtocol.requests(path: Paths.attempts).count, 1, "\(label)：取尝试照常发出")
            XCTAssertEqual(authorization(Paths.attempts), hasAccess ? "Bearer at-old" : nil, label)
            flow.authorizer.complete(flow.credential)
            let outcome = await task.value
            XCTAssertEqual(LoginStubProtocol.requests(path: flow.path).count, 1, "\(label)：登录照常发出")
            assertLoggedInAndSaved(outcome, harness, label)
        }
    }

    // MARK: - 3. 存着受限（deletion_only）会话

    /// 3. D10-1707 ① / D10-1658 ④：本机存着 A 的 deletion_only 会话（客户端冷启动的受限会话屏障仍到期）→ createOauthAttempt
    /// （optional，purpose=login）与 loginByWechat（none）都不等屏障、不触发刷新（零 /v1/auth/refresh），照常发出；
    /// createOauthAttempt 带着现有受限令牌；新 full 会话覆盖。
    func testRestrictedStoredSessionSkipsBarrierAndLogsIn() async throws {
        installServer()
        let harness = OAuthHarness()
        let flow = flows(harness)[0]
        harness.client.signOut()
        try harness.tokens.save(access: "at-r", refresh: "rt-r", scope: Session.SessionScope.deletionOnly, account: "A")
        XCTAssertEqual(harness.client.isolatedSessionScope, Session.SessionScope.deletionOnly)
        let task = start(harness, flow)
        await harness.waitAuthorizing(flow.authorizer)
        XCTAssertEqual(authorization(Paths.attempts), "Bearer at-r", "不等屏障，带现有令牌")
        XCTAssertTrue(LoginStubProtocol.requests(path: Paths.refresh).isEmpty, "取尝试前零刷新")
        flow.authorizer.complete(flow.credential)
        let outcome = await task.value
        XCTAssertEqual(LoginStubProtocol.requests(path: flow.path).count, 1)
        XCTAssertTrue(LoginStubProtocol.requests(path: Paths.refresh).isEmpty, "全程零刷新")
        assertLoggedInAndSaved(outcome, harness, "受限会话")
    }

    // MARK: - 4. 授权期间读不出 → 可读（世代不变）

    /// 4. D10-1707 ①：发起时 A 的会话读不出（固定归属账号为 nil），授权等待期间恢复可读（世代不变）→ 提交前复核不判 stale
    /// （原来带账号比较会 nil ≠ A 判 stale），loginBy* 照常发出（原来固定「无账号」时读到 A 会 account_mismatch），登录成功落盘。
    /// 微信、Apple 两种。
    /// 依据 D10-1710：createOauthAttempt purpose=login 已列入 sendsWhenIdentityUnknown 声明名单（OAuthLoginService.createAttempt
    /// 声明），所以会话读不出时 OAuth 登录的取尝试照常（匿名）发出，不按 session_unreadable 拒。
    func testSessionBecomingReadableDuringAuthorizationIsNotStale() async throws {
        for index in 0..<2 {
            installServer()
            let harness = OAuthHarness()
            let flow = flows(harness)[index]
            try harness.seedSession(account: "A")
            harness.tokens.failReads = .readFailed
            let generation = harness.client.sessionGeneration
            let task = start(harness, flow)
            await harness.waitAuthorizing(flow.authorizer)
            XCTAssertNil(authorization(Paths.attempts), "\(flow.provider)：读不出时取尝试不带令牌")
            harness.tokens.failReads = nil
            XCTAssertEqual(harness.client.sessionGeneration, generation, "恢复可读不换代")
            flow.authorizer.complete(flow.credential)
            let outcome = await task.value
            XCTAssertEqual(LoginStubProtocol.requests(path: flow.path).count, 1, "\(flow.provider)：登录照常发出")
            assertLoggedInAndSaved(outcome, harness, flow.provider)
        }
    }

    // MARK: - 5. 用户退出（不是另一账号登录）

    /// 5a. D10-1707 ① / D10-1703：授权等待期间用户退出（经客户端 signOut，世代 +1，本机没有会话）→ stale，loginBy* 零发送，不落盘。
    func testSignOutDuringAuthorizationIsStaleAndSendsNothing() async throws {
        installServer()
        let harness = OAuthHarness()
        let flow = flows(harness)[0]
        try harness.seedSession(account: "A")
        let task = start(harness, flow)
        await harness.waitAuthorizing(flow.authorizer)
        harness.client.signOut()
        flow.authorizer.complete(flow.credential)
        let outcome = await task.value
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.stale, "\(outcome)")
        XCTAssertTrue(LoginStubProtocol.requests(path: flow.path).isEmpty, "零发送")
        XCTAssertNil(harness.tokens.scope, "不落盘")
        XCTAssertEqual(harness.oauth.submittedCount, 0)
    }

    /// 5b. D10-1707 ① / D10-1703：登录请求在途时用户退出（世代 +1）→ 响应到达时落盘前世代比对不一致（captureLogin），不落盘，按 stale；
    /// 不弹绑手机引导。
    func testSignOutWhileLoginInFlightIsNotSaved() async throws {
        installServer(holdLogin: true)
        let harness = OAuthHarness()
        let flow = flows(harness)[0]
        try harness.seedSession(account: "A")
        let task = start(harness, flow)
        await harness.waitAuthorizing(flow.authorizer)
        flow.authorizer.complete(flow.credential)
        await waitUntil { LoginStubProtocol.isHeld(Self.holdId) }
        harness.client.signOut()
        releaseLogin()
        let outcome = await task.value
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.stale, "\(outcome)")
        XCTAssertNil(harness.tokens.scope, "不落盘")
        XCTAssertNil(harness.tokens.accessToken)
        XCTAssertTrue(harness.guideSessions.isEmpty)
    }

    // MARK: - 6. 游客态

    /// 6. D10-1707 ①：游客态（本机没有会话）→ 照常：两个请求都不带 Authorization，登录成功落盘。微信、Apple 两种。
    func testGuestLogsInNormally() async {
        for index in 0..<2 {
            installServer()
            let harness = OAuthHarness()
            let flow = flows(harness)[index]
            let task = start(harness, flow)
            await harness.waitAuthorizing(flow.authorizer)
            flow.authorizer.complete(flow.credential)
            let outcome = await task.value
            XCTAssertNil(authorization(Paths.attempts), flow.provider)
            XCTAssertNil(authorization(flow.path), flow.provider)
            assertLoggedInAndSaved(outcome, harness, flow.provider)
        }
    }

    // MARK: - 7. RequestOwnership

    /// 7. D10-1707 ① / D10-1704：RequestOwnership 缺省 pinsAccount == true（其余调用方的固定账号核对不变）；sessionOnly 只留世代、
    /// 账号置 nil、pinsAccount == false，与原值不相等（不论原值有没有账号），提交前复核据此只比世代。
    func testRequestOwnershipDefaultsAndSessionOnly() {
        let pinned = RequestOwnership(account: "A", generation: 7, epoch: 3)
        XCTAssertTrue(pinned.pinsAccount)
        XCTAssertTrue(RequestOwnership(account: nil, generation: 7, epoch: 3).pinsAccount)
        let only = pinned.sessionOnly
        XCTAssertNil(only.account)
        XCTAssertEqual(only.generation, 7)
        XCTAssertEqual(only.epoch, 3)
        XCTAssertFalse(only.pinsAccount)
        XCTAssertNotEqual(only, pinned)
        let accountless = RequestOwnership(account: nil, generation: 7, epoch: 3)
        XCTAssertNotEqual(accountless.sessionOnly, accountless, "account 同为 nil 时也靠 pinsAccount 区分")
        XCTAssertEqual(pinned.sessionOnly, accountless.sessionOnly, "sessionOnly 不看账号：同世代即相等")
        XCTAssertNotEqual(pinned.sessionOnly, RequestOwnership(account: "A", generation: 8, epoch: 3).sessionOnly)
    }
}
