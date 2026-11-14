@testable import Clipboard
import CouliNetwork
import Foundation
import XCTest

/// LOCK-ios 段 2（编排 D10-1709 ③④）：调用点层面——parseInput 不在「身份未知也可发」名单里：ParseInputService 交给网络层的
/// ApiCall 不声明 `sendsWhenIdentityUnknown`（会话读不出时由网络层按 session_unreadable 本地拒）。
/// 固定归属（④，接 D10-1703）要改 `ParseApi` 的发送签名，接口未约定，这里不断言，见回报。
final class LockIosIdentityUnknownParseTests: XCTestCase {
    /// 记下交给网络层的调用，回本地拒绝（不出卡）。
    private final class RecordingParseApi: ParseApi, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ApiCall] = []

        var calls: [ApiCall] {
            lock.withLock { stored }
        }

        func send(_ call: ApiCall, isValid _: @escaping @Sendable () -> Bool) async -> ApiResult {
            lock.withLock { stored.append(call) }
            return .localReject(reason: LocalRejectReason.sessionUnreadable)
        }
    }

    func testParseInputDoesNotDeclareSendsWhenIdentityUnknown() async {
        let api = RecordingParseApi()
        let service = ParseInputService(api: api)
        _ = await service.parse("https://e.tb.cn/a", isValid: { true })
        XCTAssertEqual(api.calls.map(\.operationId), [ParseInputService.operationId])
        XCTAssertEqual(api.calls.first?.sendsWhenIdentityUnknown, false, "parseInput 不声明（D10-1709 ③）")
    }
}
