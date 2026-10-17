import Foundation
@testable import Network
import SecureStore
@testable import Session
import XCTest

/// FU-IOS-0712 第 1 项（续）：升级兼容与「待核验」标记的改写。
extension FollowupIos0712SessionTests {
    // MARK: - 升级兼容（旧令牌没有世代）

    func testPreUpgradeSessionWithoutEpochStaysUsableKeepsNoEpochAndRevokesByRefreshFingerprint() async throws {
        let legacy = #"{"access":"old-access","refresh":"old-refresh","scope":"full","account":"user-a"}"#
        let store = ScriptedSecureStore(values: [tokensAccount: Data(legacy.utf8)])
        let file = MemorySessionRevocationMarks()
        let tokens = SecureSessionTokens(store: store, revocationFile: file)
        let harness = makeHarness(sessionStore: tokens)
        XCTAssertEqual(try tokens.readSession()?.access, "old-access", "升级前的会话照常可用")
        XCTAssertNil(harness.client.sessionLoginEpoch(credentialsReadable: true), "没有世代：按账号分区的缓存不读不写")
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                return ok(refreshData(access: "access-2"))
            }
            return request.header("Authorization") == "Bearer access-2" ? ok("{}") : fail(10002, status: 401)
        }
        _ = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(try tokens.readSession()?.access, "access-2")
        XCTAssertNil(try tokens.readSession()?.loginEpoch, "刷新沿用（仍没有世代）")
        // 清会话删除失败：按 refresh_token 摘要撤销，重建读不回
        store.failRemoves = [tokensAccount]
        harness.client.signOut()
        let mark = try XCTUnwrap(store.raw(markAccount))
        XCTAssertEqual(
            SessionRevocation.decode(String(data: mark, encoding: .utf8) ?? ""),
            SessionRevocation.target(loginEpoch: nil, refresh: "refresh-2")
        )
        XCTAssertNil(try SecureSessionTokens(store: store, revocationFile: file).readSession())
        // 下次登录：有世代，旧标记不误伤
        store.failRemoves = []
        let next = makeHarness(sessionStore: SecureSessionTokens(store: store, revocationFile: file))
        await login(next)
        XCTAssertNotNil(next.client.sessionLoginEpoch(credentialsReadable: true))
    }

    // MARK: - 删不掉的「待核验」标记由新登录改写（鸿蒙 FU-HM-0717 同口径）

    func testLeftoverAnySessionMarkIsSupersededByANewLoginAndStillBlocksTheOldSession() async throws {
        let store = ScriptedSecureStore()
        let file = MemorySessionRevocationMarks()
        let old = #"{"access":"old","refresh":"old-r","scope":"full","account":"user-a","login_epoch":"E-old"}"#
        store.values[tokensAccount] = Data(old.utf8)
        store.values[markAccount] = Data(SessionRevocation.encode(SessionRevocation.anySession).utf8)
        store.failRemoves = [markAccount]
        file.put(formal: Data(SessionRevocation.encode(SessionRevocation.anySession).utf8))
        file.failDeletes = true
        XCTAssertNil(try SecureSessionTokens(store: store, revocationFile: file).readSession(), "前提：* 阻断")
        let harness = makeHarness(sessionStore: SecureSessionTokens(store: store, revocationFile: file))
        await login(harness, access: "new-access")
        let epoch = try XCTUnwrap(harness.client.sessionLoginEpoch(credentialsReadable: true))
        XCTAssertEqual(
            SessionRevocation.decode(String(data: try XCTUnwrap(store.raw(markAccount)), encoding: .utf8) ?? ""),
            "s:" + epoch, "删不掉的 * 改写成「除了这次登录」"
        )
        XCTAssertEqual(try SecureSessionTokens(store: store, revocationFile: file).readSession()?.access, "new-access",
                       "重建后新登录照常可用")
        store.values[tokensAccount] = Data(old.utf8)
        XCTAssertNil(try SecureSessionTokens(store: store, revocationFile: file).readSession(), "旧会话仍被阻断")
    }
}
