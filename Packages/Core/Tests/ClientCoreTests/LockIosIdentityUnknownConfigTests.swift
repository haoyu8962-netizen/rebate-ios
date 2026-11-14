import ClientCore
import CouliNetwork
import Foundation
import Session
import XCTest

/// LOCK-ios 段 2（编排 D10-1709 ③）：调用点层面——生产的 getConfig 拉取（`ConfigFetcher.make`）声明「身份未知也可发」：
/// 本机存着会话但这一刻读不出时，`/v1/config` 照常不带 Authorization 发出（不被 session_unreadable 拦下、配置拉取不停摆）。
final class LockIosIdentityUnknownConfigTests: XCTestCase {
    private let configPath = "/v1/config"

    @MainActor
    func testConfigFetcherSendsWhenIdentityUnknown() async {
        CoreStubProtocol.install { _ in coreOK("{\"dict_version\":\"net-1\"}") }
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let state = CoreTestState()
        let client = ApiClient(
            identity: ClientIdentity(platform: "ios", appVersion: "1.2.0", build: "120", channel: "app_store"),
            context: { state.context },
            tokens: tokens,
            pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
            configuration: CoreStubProtocol.configuration(),
            sleeper: { _ in }
        )
        tokens.failReads = .readFailed
        let done = expectation(description: "config 拉取回调")
        ConfigFetcher.make(client: client)(nil) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        let sent = CoreStubProtocol.requests(path: configPath)
        XCTAssertEqual(sent.count, 1, "身份未知时 getConfig 照常发出（调用点声明 sendsWhenIdentityUnknown）")
        XCTAssertNil(sent.first?.header("Authorization"), "读不出的会话不得当成有令牌")
    }
}
