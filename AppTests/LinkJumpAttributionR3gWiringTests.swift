import ClientCore
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Trade
import XCTest

/// APP-08 iOS 第七次修复 NEW-06（S2）：link_jump 埋点带购买发起时固定的请求归属。真实接线的 AppTrade 上报口：
/// 来源未变时 user_id 用固定归属里的账号（不读当前会话）；外跳结果等待期间换成 B 之后到达的 A 的步骤一律丢弃，不记到 B 名下。
@MainActor
final class LinkJumpAttributionR3gWiringTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "LinkJumpAttributionR3gWiringTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        AppStubProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default
            .removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName))
        AppStubProtocol.reset()
    }

    private final class Tracked {
        var events: [(TrackEvent, TrackAttribution?)] = []
    }

    private let step: TradeObject = [
        "phase": "purchase", "union_platform": "taobao", "step": "scheme", "result": "launched",
        "attempt_id": "A7", "link_id": "L1", "duration_ms": 12, "installed": "unknown",
    ]

    func testStepFromAIsDroppedAfterSwitchToBAndAttributedToAOtherwise() throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let tracked = Tracked()
        let trade = AppTrade(
            network: fixture.network, config: fixture.config, privacy: fixture.privacy, routing: fixture.routing,
            login: fixture.login, credentialsReadable: { true }, track: { tracked.events.append(($0, $1)) }
        )
        // 购买发起时固定的归属（与 AppTrade 给购买来源的读取同一种）
        let ownerA = trade.requestOwnership()
        XCTAssertEqual(ownerA.account, "user-a", "前提：A 已登录")

        trade.sink.report(step, owner: ownerA)
        XCTAssertEqual(tracked.events.count, 1)
        XCTAssertEqual(tracked.events.first?.1, TrackAttribution(userId: "user-a"), "user_id 取发起时的 A")

        // 外跳结果等待期间换成 B：之后到达的 A 的步骤丢弃
        fixture.network.client.signOut()
        try fixture.tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
        XCTAssertEqual(trade.requestOwnership().account, "user-b", "前提：当前是 B")
        trade.sink.report(step, owner: ownerA)
        XCTAssertEqual(tracked.events.count, 1, "换号后 A 的 link_jump 不记到 B 名下")
        XCTAssertFalse(tracked.events.contains { $0.1?.userId == "user-b" })
    }
}
