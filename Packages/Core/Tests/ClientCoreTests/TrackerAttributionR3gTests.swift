import ClientCore
import Foundation
import Generated
import XCTest

/// APP-08 iOS 第七次修复 NEW-06（S2）：带固定账号归属的事件编码 user_id 时只用归属里的账号，不读当前会话。
final class TrackerAttributionR3gTests: XCTestCase {
    private func makeQueue(_ file: MemoryFile, current: @escaping () -> String?) -> TrackerQueue {
        TrackerQueue(
            readFile: file.read, writeFile: file.write, sink: { _ in false }, privacy: "consented", userId: current,
            currentDeviceId: { "device-t" }, platform: "ios", appVersion: "1.2.0", channel: "appstore",
            sessionId: "session-t", clock: { 1_790_661_600_000 }, canUpload: { false }
        )
    }

    private func userIds(_ file: MemoryFile) throws -> [String?] {
        let text = try XCTUnwrap(file.value)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let events = try XCTUnwrap(object["events"] as? [String])
        return try events.map { packet in
            let event = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(packet.utf8)) as? [String: Any])
            return event["user_id"] as? String
        }
    }

    func testAttributedEventUsesFixedAccountNotCurrent() throws {
        let file = MemoryFile()
        var current: String? = "user-b"
        var reads = 0
        let queue = makeQueue(file) {
            reads += 1
            return current
        }
        XCTAssertTrue(queue.track(
            event: ClientEvents.appLaunch(page: "ProductDetail"), attribution: TrackAttribution(userId: "user-a")
        ))
        XCTAssertEqual(reads, 0, "带固定归属：编码时不读当前会话")
        XCTAssertTrue(queue.track(
            event: ClientEvents.appLaunch(page: "ProductDetail"), attribution: TrackAttribution(userId: nil)
        ))
        current = "user-c"
        XCTAssertTrue(queue.track(event: ClientEvents.appLaunch(page: "Home")))

        XCTAssertEqual(try userIds(file), ["user-a", nil, "user-c"], "固定 A、发起时游客不带、没有归属的照旧取当前")
    }
}
