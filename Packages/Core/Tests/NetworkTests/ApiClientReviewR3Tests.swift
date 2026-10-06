import Foundation
import Generated
@testable import Network
import Session
import XCTest

/// iOS 第 3 轮评审（NATIVE/APP-03a/ios-review-r3.md）R3-01、R3-02 的复现测试，全部对 URLProtocol 本地假服务。
final class ApiClientReviewR3Tests: XCTestCase {
    // MARK: - R3-01：冷启动受限屏障的判定、快照与入队原子，按会话世代 + 屏障编号结算

    /// 冷启动保存着 deletion_only 会话、版本 below：刷新停在假服务时已有一批带令牌请求在等；放行刷新（新令牌仍是
    /// deletion_only）的同时另一批请求并发进入屏障。整个冷启动只刷新 1 次，所有业务请求都带新令牌发出。
    func testColdStartBelowBarrierRefreshesOnceUnderConcurrentInterleaving() async {
        for round in 0..<20 {
            let harness = makeHarness(tokens: MemorySessionTokens(
                access: "access-1", refresh: "refresh-1", scope: SessionScope.deletionOnly, account: "account-A"
            ))
            harness.state.set(update: UpdateRaw.below)
            let refreshes = Box<Int>()
            StubURLProtocol.install { request in
                guard request.path == "/v1/auth/refresh" else {
                    return ok()
                }
                refreshes.value = (refreshes.value ?? 0) + 1
                return refreshes.value == 1
                    ? .hold("barrier-refresh")
                    : ok(refreshData(access: "access-x\(refreshes.value ?? 0)", scope: SessionScope.deletionOnly))
            }
            let client = harness.client
            let early = (0..<6).map { _ in Task { await client.send(ApiCall(operationId: "getDeletion")) } }
            await StubURLProtocol.waitUntilHeld("barrier-refresh")
            let late: [ApiResult] = await withTaskGroup(of: ApiResult.self) { group in
                for index in 0..<12 {
                    let operation = index.isMultiple(of: 2) ? "getDeletion" : "getMe"
                    group.addTask { await client.send(ApiCall(operationId: operation)) }
                    if index == 4 {
                        StubURLProtocol.release(
                            "barrier-refresh",
                            with: ok(refreshData(access: "access-2", scope: SessionScope.deletionOnly))
                        )
                    }
                }
                var results: [ApiResult] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
            var results = late
            for task in early {
                await results.append(task.value)
            }
            XCTAssertTrue(results.allSatisfy(\.isSuccess), "round \(round): \(results)")
            XCTAssertEqual(client.refreshCalls, 1, "round \(round): 同一次冷启动只刷新一次")
            XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1, "round \(round)")
            let business = StubURLProtocol.requests.filter { $0.path != "/v1/auth/refresh" }
            XCTAssertEqual(business.count, 18, "round \(round)")
            XCTAssertTrue(
                business.allSatisfy { $0.header("Authorization") == "Bearer access-2" },
                "round \(round): 不带旧受限令牌、也不带二次刷新的令牌"
            )
            XCTAssertEqual(harness.tokens.accessToken, "access-2")
            // 屏障已按（会话世代, 编号）结算：之后再来一批并发请求也直接放行。
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<6 {
                    group.addTask { _ = await client.send(ApiCall(operationId: "getDeletion")) }
                }
            }
            XCTAssertEqual(client.refreshCalls, 1, "round \(round): 屏障结算后复用结果，不再刷新")
            XCTAssertTrue(harness.recorder.effectCalls.isEmpty, "round \(round)")
        }
    }

    // MARK: - R3-02：旧会话的 guide_only 补办引导不交给新会话

    /// 账号 A 提现在途 → 退出并登录 B → A 的迟到响应 10004 / 10005 / 30304（guide_only）：只结算原调用，按
    /// session_changed 结束，不交付任何引导；B 的会话不动。
    func testLateGuideOnlyFromOldSessionIsNotDeliveredToNewSession() async {
        for code in [10004, 10005, 30304] {
            let harness = makeHarness()
            StubURLProtocol.install { request in
                switch request.path {
                case "/v1/auth/login/sms":
                    ok(loginData(access: "b-access", scope: "full", user: "account-B"))
                case "/v1/auth/refresh":
                    ok(refreshData(access: "unexpected"))
                case "/v1/me":
                    ok()
                default:
                    .hold("withdraw-A")
                }
            }
            let call = Task {
                await harness.client.send(ApiCall(
                    operationId: "createWithdrawal",
                    body: "{\"amount\":1000,\"payout_account_id\":\"pa-1\"}",
                    stepUpToken: "step-up-1"
                ))
            }
            await StubURLProtocol.waitUntilHeld("withdraw-A")
            harness.client.signOut()
            let login = await harness.client.send(ApiCall(operationId: "loginBySms", body: "{}"))
            XCTAssertTrue(login.isSuccess, "\(code)")
            StubURLProtocol.release(
                "withdraw-A",
                with: fail(code, status: 403, data: code == 10004 ? "{\"consent_type\":\"withdraw_terms\"}" : "{}")
            )
            let result = await call.value
            XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionChanged, "\(code): \(result)")
            XCTAssertNil(result.effect, "\(code)")
            XCTAssertTrue(harness.recorder.effectCalls.isEmpty, "\(code): 旧响应不交付补办引导")
            XCTAssertEqual(harness.tokens.accessToken, "b-access", "\(code)")
            XCTAssertEqual(harness.tokens.account, "account-B", "\(code)")
            let me = await harness.client.send(ApiCall(operationId: "getMe"))
            XCTAssertTrue(me.isSuccess, "\(code): B 的会话照常可用")
            XCTAssertEqual(harness.client.refreshCalls, 0, "\(code)")
        }
    }
}
