import Foundation
import Generated
@testable import Network
import Session
import XCTest

/// APP-13a-1-ios 写测 r2（D10-2090 ⑥）：钉住网络层「待确认重发时原体为空串就不带 body」这两行（`ApiClient+Pending.swift`
/// `confirmPending(operationId:stepUpToken:)`、`ApiClient+PendingTarget.swift` `confirmPending(operationId:stepUpToken:target:)`）。
/// - 有请求体的操作（提现申请 createWithdrawal、改收款 savePayoutAccount）：结果未知后【确认上一笔】重发，请求体逐字节不变，Content-Type、
///   Idempotency-Key、方法与路径都与首次发送相同（BR-ID-10「原键、原体」；APP-09 不得回归）；
/// - 没有请求体的申请注销（requestDeletion）：首次与重发都不带 body（没有 Content-Type），签名按零字节计算（APP-13a 共性第 1 条）。
/// 全部对 URLProtocol 本地假服务（`StubURLProtocol`），照同目录 `ApiClientLessonsTests` 的写法。
final class App13a1PendingReplayBodyTests: XCTestCase {
    private struct Case {
        let operationId: String
        let method: String
        let path: String
        let body: String?
    }

    private let withdrawal = Case(
        operationId: "createWithdrawal", method: "POST", path: "/v1/withdrawals",
        body: "{\"amount_fen\":1000,\"payout_account_id\":\"pa-1\"}"
    )
    private let payout = Case(
        operationId: "savePayoutAccount", method: "PUT", path: "/v1/me/payout-account",
        // 带空格与中文的原文：逐字节比较，不允许重新序列化
        body: "{\"payout_method\":\"alipay\", \"logon_id\":\"13800005678\",\"payee_name\":\"测试三\"}"
    )
    private let deletion = Case(operationId: "requestDeletion", method: "POST", path: "/v1/me/deletion", body: nil)

    /// 首次发送没有统一外壳（超时）→ 键进入结果未知；返回键与那一次实际发出的请求。
    private func makeUnknown(_ harness: Harness, _ item: Case) async throws -> (String, StubURLProtocol.Recorded) {
        StubURLProtocol.install { _ in .error(.timedOut) }
        let first = await harness.client.send(
            ApiCall(operationId: item.operationId, body: item.body, stepUpToken: "step-up-1")
        )
        guard case let .transportFailure(_, _, key, unknown) = first else {
            XCTFail("\(item.operationId)：\(first)")
            throw NSError(domain: "app13a1", code: 1)
        }
        XCTAssertTrue(unknown, item.operationId)
        let sent = try XCTUnwrap(StubURLProtocol.requests(path: item.path).first, item.operationId)
        return (try XCTUnwrap(key), sent)
    }

    private enum Entry: CaseIterable {
        case plain
        case target
    }

    private func confirm(_ harness: Harness, _ item: Case, key: String, via entry: Entry) async -> ApiResult {
        switch entry {
        case .plain:
            return await harness.client.confirmPending(operationId: item.operationId, stepUpToken: "step-up-2")
        case .target:
            let target = PendingTarget(
                account: "account-A", key: key, expected: harness.client.currentOwnership(credentialsReadable: true)
            )
            return await harness.client.confirmPending(operationId: item.operationId, stepUpToken: "step-up-2",
                                                       target: target)
        }
    }

    private func assertSameRequest(
        _ first: StubURLProtocol.Recorded, _ replay: StubURLProtocol.Recorded, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(replay.method, first.method, "\(label)：方法", file: file, line: line)
        XCTAssertEqual(replay.path, first.path, "\(label)：路径", file: file, line: line)
        XCTAssertEqual(Data(replay.body.utf8), Data(first.body.utf8), "\(label)：请求体逐字节不变", file: file, line: line)
        XCTAssertEqual(replay.header("Content-Type"), first.header("Content-Type"), "\(label)：Content-Type 不变",
                       file: file, line: line)
        XCTAssertEqual(replay.header("Idempotency-Key"), first.header("Idempotency-Key"), "\(label)：原键",
                       file: file, line: line)
    }

    /// 提现申请、改收款：两个确认入口重发都与首次发送逐字节相同（有体照带、Content-Type 照带）。
    func testConfirmReplaysNonEmptyBodyVerbatim() async throws {
        for item in [withdrawal, payout] {
            for entry in Entry.allCases {
                StubURLProtocol.install { _ in ok() }
                let harness = makeHarness()
                let (key, first) = try await makeUnknown(harness, item)
                let label = "\(item.operationId) / \(entry)"
                XCTAssertEqual(first.body, item.body, "\(label)：首次发送原样带体")
                XCTAssertEqual(first.header("Content-Type"), "application/json; charset=utf-8", label)

                StubURLProtocol.install { _ in ok() }
                let result = await confirm(harness, item, key: key, via: entry)
                XCTAssertTrue(result.isSuccess, "\(label)：\(result)")
                let replay = try XCTUnwrap(StubURLProtocol.requests(path: item.path).first, "\(label)：没有重发")
                assertSameRequest(first, replay, label)
                XCTAssertEqual(replay.body, item.body, "\(label)：原体")
                XCTAssertEqual(replay.header("Content-Type"), "application/json; charset=utf-8", "\(label)：有体就带 Content-Type")
            }
        }
    }

    /// 申请注销：首次与两个确认入口的重发都不带 body（没有 Content-Type），签名按零字节，原键。
    func testConfirmReplaysEmptyDeletionWithoutBody() async throws {
        for entry in Entry.allCases {
            StubURLProtocol.install { _ in ok() }
            let harness = makeHarness()
            let (key, first) = try await makeUnknown(harness, deletion)
            let label = "requestDeletion / \(entry)"
            XCTAssertEqual(first.body, "", "\(label)：首次不带体")
            XCTAssertNil(first.header("Content-Type"), "\(label)：首次没有请求体就没有 Content-Type")
            XCTAssertEqual(harness.backend.read(account: "account-A", key: key)?.body, "", "\(label)：未决记录原体为空串")

            StubURLProtocol.install { _ in ok() }
            let result = await confirm(harness, deletion, key: key, via: entry)
            XCTAssertTrue(result.isSuccess, "\(label)：\(result)")
            let replay = try XCTUnwrap(StubURLProtocol.requests(path: deletion.path).first, "\(label)：没有重发")
            assertSameRequest(first, replay, label)
            XCTAssertEqual(replay.body, "", "\(label)：重发不带体")
            XCTAssertNil(replay.header("Content-Type"), "\(label)：重发没有 Content-Type")
            let timestamp = try XCTUnwrap(replay.header("X-Timestamp"), label)
            let nonce = try XCTUnwrap(replay.header("X-Nonce"), label)
            let expected = RequestSigner.sign(
                installSecret: TestDevice().installSecret ?? "",
                signingString: RequestSigner.signingString(
                    method: "POST", pathWithQuery: deletion.path, timestamp: timestamp, nonce: nonce, body: Data()
                )
            )
            XCTAssertEqual(replay.header("X-Sign"), expected, "\(label)：重发签名按零字节")
            XCTAssertNil(harness.backend.read(account: "account-A", key: key), "\(label)：成功后记录删除")
        }
    }
}
