import CouliNetwork
import Foundation
@testable import Trade
import XCTest

/// APP-08 iOS 第七次修复 NEW-06（S2）：link_jump 埋点带这次购买发起时固定的请求归属；外跳结果等待期间换号（来源变了）就丢弃，
/// 不把 A 的购买尝试记到 B 名下。对照：没换号时每一步都带 A 的固定归属上报。
@MainActor
final class LinkJumpAttributionR3gTests: XCTestCase {
    private final class Session {
        var account = "user-A"
        var generation: UInt64 = 1

        var origin: String {
            "\(account)#\(generation)"
        }

        var request: RequestOwnership {
            RequestOwnership(account: account, generation: generation, epoch: 0)
        }

        func switchToB() {
            account = "user-B"
            generation += 1
        }
    }

    private func rig(_ session: Session) -> PurchaseHarness {
        let rig = PurchaseHarness(sessionKey: { session.account })
        rig.controller.jumpOrigin = { session.origin }
        rig.controller.jumpSource = { JumpSource(origin: session.origin, request: session.request) }
        rig.ports.launchResults = [false, true]
        return rig
    }

    private let steps: [[String: Any]] = [
        ["type": "scheme", "value": "app://a"], ["type": "universal_link", "value": "https://x.test/u"],
    ]

    func testStepsCarryFixedOwnerWhenSourceUnchanged() async {
        let session = Session()
        let rig = rig(session)
        let ownerA = session.request
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(attempt: "A7", steps: steps)))
        await eventually { rig.sink.events.count == 2 }
        XCTAssertEqual(rig.sink.owners, [ownerA, ownerA], "每一步都带发起时固定的 A")
    }

    /// 外跳结果等待期间（拉起目标 App、等返回结果）换成 B：这一步与之后的步骤零上报。
    func testSwitchWhileAwaitingJumpResultDropsEvents() async {
        let session = Session()
        let rig = rig(session)
        rig.ports.onLaunch = { session.switchToB() }
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(attempt: "A7", steps: steps)))
        await eventually { !rig.ports.launched.isEmpty }
        await settle()

        XCTAssertTrue(rig.sink.events.isEmpty, "换号之后到达的 A 的外跳结果：零 link_jump")
        XCTAssertFalse(rig.sink.owners.contains { $0?.account == "user-B" }, "不记到 B 名下")
    }
}
