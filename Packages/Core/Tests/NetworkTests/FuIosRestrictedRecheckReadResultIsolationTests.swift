import Foundation
@testable import Network
import Session
import XCTest

final class FuIosRestrictedReadIsolationTests: XCTestCase {
    /// 删掉 admitLocked 缺 refresh 时的 isolated → .superseded 分支会红：匿名 10002 会重复换代、通知、发 Effect。
    func testIsolatedAnonymous10002LocallyRejectsWithoutClearingAgain() async {
        for update in [UpdateRaw.supported, UpdateRaw.below] {
            let harness = makeHarness()
            harness.state.set(update: update)
            let changes = observe(harness.client)
            isolate(harness, changes: changes)
            let bound = harness.client.sessionGeneration
            StubURLProtocol.install { _ in fail(10002, status: 401) }

            let result = await harness.client.send(ApiCall(operationId: "getConfig"))

            assertLocalRejection(result)
            XCTAssertEqual(StubURLProtocol.requests.count, 1, "不重放、不发刷新")
            XCTAssertEqual(StubURLProtocol.requests.first?.path, "/v1/config")
            XCTAssertNil(StubURLProtocol.requests.first?.header("Authorization"), "确实是匿名请求")
            assertUnchanged(harness, changes: changes, bound: bound)
        }
    }

    /// 删掉 pipelineAction 旧世代分支的 .end 本地拒绝结果、改成交付原 Effect 会红。
    /// 因而真实带旧令牌的请求必须先发出，再清会话进入隔离，最后交付 10002。
    func testInFlightOldBearer10002AfterIsolationLocallyRejects() async {
        let harness = makeHarness()
        let changes = observe(harness.client)
        let isolatedGeneration = Box<UInt64>()
        StubURLProtocol.install { request in
            XCTAssertEqual(request.header("Authorization"), "Bearer access-1", "前提：发出时尚未隔离")
            harness.tokens.failClears = true
            harness.client.signOut()
            isolatedGeneration.value = harness.client.sessionGeneration
            return fail(10002, status: 401)
        }

        let result = await harness.client.send(ApiCall(operationId: "getMe"))

        assertLocalRejection(result)
        XCTAssertNotNil(isolatedGeneration.value)
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "旧请求不重放、不发刷新")
        XCTAssertEqual(StubURLProtocol.requests.first?.path, "/v1/me")
        assertUnchanged(harness, changes: changes, bound: isolatedGeneration.value ?? UInt64.max)
    }

    /// 删掉 admitLocked 的 isolated 分支会红；直接入队覆盖 usedToken 非 nil，避免只测到外层旧世代拦截。
    func testIsolatedRefreshAdmissionWithOldTokenIsSuperseded() async {
        let harness = makeHarness()
        let changes = observe(harness.client)
        isolate(harness, changes: changes)
        let bound = harness.client.sessionGeneration
        StubURLProtocol.install { _ in fail(10002, status: 401) }

        let outcome = await harness.client.joinRefresh(generation: bound, usedToken: "access-1")

        XCTAssertEqual(outcome, .superseded)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        assertUnchanged(harness, changes: changes, bound: bound)
    }

    /// 删掉非隔离分支的 clearSessionLocked / emit / recordRefreshFailureLocked 任一项会红。
    /// 同时保留 supported 跳登录、below 留强更，以及旧世代重复入队复用结论、不再通知的原行为。
    func testNonisolatedMissingRefreshStillClearsEmitsAndRemembersFailure() async {
        for update in [UpdateRaw.supported, UpdateRaw.below] {
            let harness = makeHarness(tokens: MemorySessionTokens())
            harness.state.set(update: update)
            let changes = observe(harness.client)
            let bound = harness.client.sessionGeneration
            StubURLProtocol.install { _ in fail(10002, status: 401) }

            let result = await harness.client.send(ApiCall(operationId: "getConfig"))

            guard case let .sessionCleared(effect) = result else {
                XCTFail("无会话时仍按刷新失败清一次：\(result)")
                continue
            }
            XCTAssertEqual(effect.kind, update == UpdateRaw.below ? .clearSessionStayForceUpdate : .clearSessionLogin)
            XCTAssertEqual(effect.route, update == UpdateRaw.below ? "ForceUpdate" : "Login")
            XCTAssertEqual(effect.sessionGeneration, bound &+ 1)
            XCTAssertEqual(harness.client.sessionGeneration, bound &+ 1)
            XCTAssertEqual(harness.recorder.effectCalls, [effect])
            XCTAssertEqual(changes.values, [.cleared])
            XCTAssertEqual(harness.client.lock.withLock { harness.client.refreshFailures[bound] }, effect)

            let repeated = await harness.client.joinRefresh(generation: bound, usedToken: nil)

            XCTAssertEqual(repeated, .cleared(effect))
            XCTAssertEqual(harness.client.sessionGeneration, bound &+ 1)
            XCTAssertEqual(harness.recorder.effectCalls, [effect], "同世代不重复发 Effect")
            XCTAssertEqual(changes.values, [.cleared], "同世代不重复通知")
            XCTAssertEqual(harness.client.refreshCalls, 0)
            XCTAssertEqual(StubURLProtocol.requests.count, 1)
            XCTAssertEqual(StubURLProtocol.requests.first?.path, "/v1/config")
        }
    }

    /// 删掉 admitLocked 缺 refresh 时的 isolated 分支会红：同一隔离期匿名 10002 会再次清会话、发 Effect。
    /// 先发出旧 Bearer 请求并扣住回包，再用 10404 触发唯一一次跳登录；随后依次交付匿名、旧 Bearer、匿名 10002。
    func testThreeMixed10002DuringOneIsolationEmitOnlyInitialLoginEffect() async throws {
        let harness = makeHarness()
        let client = harness.client
        let changes = observe(client)
        harness.tokens.failClears = true
        StubURLProtocol.install { request in
            if request.path == "/v1/me" {
                return .hold("d10-1911-old-bearer")
            }
            return fail(request.query == "clear=1" ? 10404 : 10002, status: 401)
        }
        let oldRequest = Task { await client.send(ApiCall(operationId: "getMe")) }
        await StubURLProtocol.waitUntilHeld("d10-1911-old-bearer")
        defer {
            StubURLProtocol.release("d10-1911-old-bearer", with: .error(.cancelled))
            oldRequest.cancel()
        }
        XCTAssertEqual(StubURLProtocol.requests.first?.header("Authorization"), "Bearer access-1")
        let before = client.sessionGeneration

        let cleared = await client.send(ApiCall(operationId: "getConfig", query: "clear=1"))

        let initialEffect = try XCTUnwrap(cleared.effect)
        XCTAssertEqual(initialEffect.kind, .clearSessionLogin)
        XCTAssertEqual(initialEffect.route, "Login")
        XCTAssertEqual(initialEffect.code, 10404)
        XCTAssertEqual(client.sessionGeneration, before &+ 1)
        XCTAssertEqual(initialEffect.sessionGeneration, before &+ 1)
        let bound = client.sessionGeneration
        assertUnchanged(harness, changes: changes, bound: bound, effects: [initialEffect])

        for index in 0..<3 {
            let result: ApiResult
            if index == 1 {
                StubURLProtocol.release("d10-1911-old-bearer", with: fail(10002, status: 401))
                result = await oldRequest.value
            } else {
                result = await client.send(ApiCall(operationId: "getConfig"))
                XCTAssertNil(StubURLProtocol.requests.last?.header("Authorization"), "隔离后请求确实匿名")
            }
            assertLocalRejection(result)
            assertUnchanged(harness, changes: changes, bound: bound, effects: [initialEffect])
            XCTAssertEqual(harness.recorder.effectCalls.dropFirst().count, 0, "第 \(index + 1) 次：新增 Effect 为零")
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 4, "初始清会话一次，混合 10002 三次；无重放")
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").count, 1)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/config").count, 3)
        XCTAssertTrue(StubURLProtocol.requests(path: "/v1/auth/refresh").isEmpty)
    }

    private func observe(_ client: ApiClient) -> SessionChangeLog {
        let changes = SessionChangeLog()
        client.observeSessionChanges { changes.append($0, lockHeld: false) }
        return changes
    }

    private func isolate(_ harness: Harness, changes: SessionChangeLog) {
        let before = harness.client.sessionGeneration
        harness.tokens.failClears = true
        harness.client.signOut()
        XCTAssertEqual(harness.client.sessionGeneration, before &+ 1)
        XCTAssertEqual(changes.values, [.cleared], "前提：清会话的那一次通知已交付")
        XCTAssertTrue(harness.client.lock.withLock { harness.client.revokedSession != nil })
        XCTAssertEqual(harness.tokens.accessToken, "access-1", "前提：旧条目删不掉")
        XCTAssertTrue(harness.recorder.effectCalls.isEmpty)
    }

    private func assertLocalRejection(_ result: ApiResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .localReject(reason) = result else {
            return XCTFail("必须在本地结束：\(result)", file: file, line: line)
        }
        XCTAssertEqual(reason, LocalRejectReason.sessionChanged, file: file, line: line)
        XCTAssertNil(result.effect, file: file, line: line)
    }

    private func assertUnchanged(
        _ harness: Harness,
        changes: SessionChangeLog,
        bound: UInt64,
        effects: [ErrorEffect] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(harness.client.sessionGeneration, bound, file: file, line: line)
        XCTAssertEqual(harness.recorder.effectCalls, effects, file: file, line: line)
        XCTAssertTrue(harness.recorder.forceUpdateCalls.isEmpty, file: file, line: line)
        XCTAssertEqual(changes.values, [.cleared], "隔离后新增通知为零", file: file, line: line)
        XCTAssertEqual(harness.client.refreshCalls, 0, file: file, line: line)
        XCTAssertTrue(harness.client.lock.withLock { harness.client.refreshFailures.isEmpty }, file: file, line: line)
        XCTAssertTrue(harness.client.lock.withLock { harness.client.revokedSession != nil }, file: file, line: line)
        XCTAssertEqual(harness.tokens.accessToken, "access-1", file: file, line: line)
    }
}
