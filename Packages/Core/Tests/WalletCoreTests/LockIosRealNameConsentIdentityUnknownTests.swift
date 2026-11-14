import CouliNetwork
import Foundation
@testable import WalletCore
import XCTest

/// LOCK-ios（编排 D10-1711）：recordConsent 在「身份未知」（存着会话但读不出）时只有隐私中心撤回隐私同意（type=privacy、
/// accepted=false）声明 `sendsWhenIdentityUnknown: true`；实名单独同意（type=id_verification、accepted=true，ApiRealNameBackend）
/// 不在名单里，身份未知时由网络层本地拒（session_unreadable、零发送）。这里经 `WalletApi` 替身直接看实名同意交给网络层的 ApiCall：
/// 没有声明（缺省 false）、也没置 requiresSession，请求体就是实名同意本身。网络层对未声明 recordConsent 的拒绝见
/// NetworkTests/LockIosIdentityUnknownTests 7b。
final class LockIosRealNameConsentUnknownTests: XCTestCase {
    /// 只记下交来的 ApiCall，不发请求（返回本地拒绝，结果不在本测试关心范围）。
    private final class RecordingWalletApi: WalletApi, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ApiCall] = []

        var calls: [ApiCall] {
            lock.withLock { recorded }
        }

        func send(
            _ call: ApiCall, isValid _: @escaping @Sendable () -> Bool, sendAllowed _: @escaping @Sendable () -> Bool,
            expected _: RequestOwnership?
        ) async -> ApiResult {
            lock.withLock { recorded.append(call) }
            return .localReject(reason: LocalRejectReason.sessionUnreadable)
        }

        func confirmPending(operationId _: String, stepUpToken _: String?, target _: PendingTarget) async -> ApiResult {
            .localReject(reason: LocalRejectReason.invalidCall)
        }

        func abandonPending(operationId _: String, target _: PendingTarget) async -> ApiResult {
            .localReject(reason: LocalRejectReason.invalidCall)
        }

        func pendingStatus(operationId _: String) async -> PendingLookup {
            .none
        }

        func restorePending() async {}
    }

    /// D10-1711：实名单独同意 recordConsent {type: id_verification, accepted: true} 交给网络层的 ApiCall 没有声明
    /// sendsWhenIdentityUnknown（身份未知时由网络层拒，不匿名发出）。
    @MainActor
    func testRealNameConsentDoesNotDeclareSendsWhenIdentityUnknown() async throws {
        let api = RecordingWalletApi()
        let backend = ApiRealNameBackend(
            api: api, gate: RetryAfterGate(clock: { 0 }), consentVersion: { 3 }, clock: { 1_790_661_600_000 }
        )
        _ = await backend.recordConsent(owner: nil)
        XCTAssertEqual(api.calls.count, 1)
        let call = try XCTUnwrap(api.calls.first)
        XCTAssertEqual(call.operationId, "recordConsent")
        XCTAssertFalse(call.sendsWhenIdentityUnknown, "实名同意不在 D10-1711 名单里")
        XCTAssertFalse(call.requiresSession)
        let data = try XCTUnwrap(call.body?.data(using: .utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["type"] as? String, "id_verification")
        XCTAssertEqual(body["accepted"] as? Bool, true)
        XCTAssertEqual(body["channel"] as? String, "realname_sheet")
    }
}
