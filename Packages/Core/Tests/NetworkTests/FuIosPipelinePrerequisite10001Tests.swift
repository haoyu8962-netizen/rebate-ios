import Foundation
import Generated
@testable import Network
import Session
import XCTest

/// FU-IOS-WITHDRAW-STEPUP-PANEL-CLEANUP 补测 S3-4（FU-IOS-CONTRACT-LOCK-6c97062/review-funds-r1.md）：管线层前置码缺 10001。
/// LockIos6c97062SensitiveOperationTests 的 testWithdrawalPrerequisiteThroughPipelineDoesNotReplay /
/// testPrerequisiteAfterUnknownKeepsPendingWithoutReplay 只走了 10004 / 10005（映射层那条已含 10001）。这里照同一写法补 10001：
/// - 提现首次提交走管线收到 10001 → 只引导（guide_only，去登录）、不重放、不登记 pending_action，只发一次；
/// - 结果未知后【确认上一笔】（两个入口）收到 10001 → 只引导、不重放、不换键、不登记，键保持待确认（unknown），只有那次确认。
/// 网络层本单不改，今天应为绿（钉现状）。对 URLProtocol 本地假服务。
final class FuIosPipelinePrerequisite10001Tests: XCTestCase {
    private static let operationId = "createWithdrawal"
    private static let path = "/v1/withdrawals"
    private static let body = "{\"amount_fen\":1000,\"payout_account_id\":\"pa-1\"}"

    private enum Entry: CaseIterable {
        case plain
        case target
    }

    /// 首次发送没有统一外壳（超时）→ 键进入结果未知；返回键。
    private func makeUnknown(_ harness: Harness) async throws -> String {
        StubURLProtocol.install { _ in .error(.timedOut) }
        let first = await harness.client.send(ApiCall(operationId: Self.operationId, body: Self.body))
        guard case let .transportFailure(_, _, key, unknown) = first else {
            XCTFail("首次发送应结果未知，实际 \(first)")
            throw NSError(domain: "fu-ios-10001", code: 1)
        }
        XCTAssertTrue(unknown, "前提：结果未知")
        return try XCTUnwrap(key, "前提：有原键")
    }

    private func confirm(_ harness: Harness, key: String, via entry: Entry) async -> ApiResult {
        switch entry {
        case .plain:
            await harness.client.confirmPending(operationId: Self.operationId)
        case .target:
            await harness.client.confirmPending(
                operationId: Self.operationId, stepUpToken: nil,
                target: PendingTarget(
                    account: "account-A", key: key,
                    expected: harness.client.currentOwnership(credentialsReadable: true)
                )
            )
        }
    }

    /// 管线：提现首次提交得到 10001 → 只引导（去登录），不重放、不登记 pending_action，只发一次。
    func testWithdrawal10001ThroughPipelineOnlyGuidesAndSendsOnce() async throws {
        let harness = makeHarness()
        StubURLProtocol.install { _ in fail(10001, status: 401) }
        let result = await harness.client.send(ApiCall(operationId: Self.operationId, body: Self.body))
        let effect = try XCTUnwrap(result.effect, "10001：\(result)")
        XCTAssertEqual(effect.kind, .guideOnly, "敏感操作上的 10001 只引导")
        XCTAssertEqual(effect.route, "Login", "引导去登录")
        XCTAssertEqual(effect.replay, ReplayMode.none, "不自动重放")
        XCTAssertFalse(effect.registerPending, "不登记 pending_action（补完登录后不自动重放提现）")
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "只发一次")
        XCTAssertEqual(StubURLProtocol.requests(path: Self.path).count, 1, "提现写出 1 次")
    }

    /// 结果未知后确认（两个入口）得到 10001：只引导、不同键重放、不换键、不登记，键仍是 unknown；只有那次确认。
    func testConfirm10001AfterUnknownKeepsPendingWithoutReplay() async throws {
        for entry in Entry.allCases {
            let harness = makeHarness()
            let key = try await makeUnknown(harness)
            StubURLProtocol.install { _ in fail(10001, status: 401) }
            let result = await confirm(harness, key: key, via: entry)
            let label = "确认 / \(entry)"
            let effect = try XCTUnwrap(result.effect, "\(label)：\(result)")
            XCTAssertEqual(effect.kind, .guideOnly, "\(label)：只引导")
            XCTAssertNotEqual(effect.replay, .sameKey, "\(label)：不自动同键重放")
            XCTAssertNotEqual(effect.replay, .newKey, "\(label)：不换键")
            XCTAssertFalse(effect.registerPending, "\(label)：不登记 pending_action")
            XCTAssertEqual(effect.pendingKeyUnknown, true, "\(label)：键仍未知")
            XCTAssertEqual(StubURLProtocol.requests.count, 1, "\(label)：只有那次确认")
            let sent = try XCTUnwrap(StubURLProtocol.requests(path: Self.path).first, label)
            XCTAssertEqual(sent.header("Idempotency-Key"), key, "\(label)：确认用原键")
            XCTAssertEqual(harness.pending.state(key: key).stateRaw, PendingKeyStore.unknown, "\(label)：保持待确认")
            XCTAssertNotNil(harness.backend.read(account: "account-A", key: key), "\(label)：记录还在")
        }
    }
}
