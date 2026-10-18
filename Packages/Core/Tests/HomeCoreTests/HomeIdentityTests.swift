import CouliNetwork
import Foundation
@testable import HomeCore
import XCTest

/// 控制器的固定身份与作废（brief §0「请求归属与世代」「身份构造时一次性取、之后只比较」「会话换代清空」「等待后复核」；
/// cross-platform-lessons 第 1、23、33 条；F-X-17、F-X-19、F-X-21）。App 侧的重建接线见 AppTests/HomeAppWiringTests。
@MainActor
final class HomeIdentityTests: HomeRigTestCase {
    private func page(_ version: Int, _ id: String) -> [String: Any] {
        HomeKit.page(version: version, [HomeKit.activity(id, titles: ["测试\(id)"])])
    }

    /// A 的冷启动拉取在途时作废（换登 B）：A 的响应不写任何 LKG、不改屏；B 的控制器显示 B 自己作用域的 LKG。
    func testInvalidatedControllerDropsLateResponseAndNeverWritesAnyLkg() async throws {
        try rig.seedLkg(page(3, "b_cached"), for: HomeKit.memberB)
        let holdA = Hold()
        rig.port?.queuePage(.held(holdA))
        let controllerA = rig.controller(HomeKit.memberA)
        controllerA.start()
        await waitFor("A 的请求没发出") { rig.port?.pageCalls.count == 1 }
        controllerA.invalidate()
        XCTAssertTrue(controllerA.state.sections.isEmpty, "作废后不再显示旧账号的内容")
        XCTAssertNil(controllerA.state.source)

        let holdB = Hold()
        rig.port?.queuePage(.held(holdB))
        let controllerB = rig.controller(HomeKit.memberB)
        controllerB.start()
        await waitFor("B 显示 B 作用域的 LKG") { controllerB.state.sectionIds == ["b_cached"] }

        holdA.release(HomeKit.ok(page(9, "a_people")))
        rig.clock.advance(1500)
        await controllerA.whenIdle()
        XCTAssertNil(rig.readLkgVersion(for: HomeKit.memberA), "作废后 A 的响应写了 A 的 LKG")
        XCTAssertEqual(rig.readLkgVersion(for: HomeKit.memberB), 3, "A 的响应写进了 B 的 LKG")
        XCTAssertEqual(controllerB.state.sectionIds, ["b_cached"])
        XCTAssertTrue(controllerA.state.sections.isEmpty, "作废后 1.5 秒计时不应再显示包内默认")

        holdB.release(HomeKit.ok(page(4, "b_people")))
        await controllerB.whenIdle()
        XCTAssertEqual(rig.readLkgVersion(for: HomeKit.memberB), 4)
    }

    /// 作废后旧控制器的所有入口都无效：下拉、重试、点击、加载更多不发请求、不执行动作。
    func testEntriesOfInvalidatedControllerDoNothing() async throws {
        rig.port?.setPage(HomeKit.ok(HomeKit.page(
            version: 5,
            [HomeKit.activity("act", titles: ["测试"]), HomeKit.feed()]
        )))
        let controller = rig.controller()
        await rig.start(controller)
        let render = controller.state.render
        let tap = try XCTUnwrap(controller.state.section("act")?.items.first?.tap)
        let feed = try XCTUnwrap(controller.state.section("feed")?.feed?.ticket)
        let pages = rig.port?.pageCalls.count
        let items = rig.port?.itemCalls.count
        controller.invalidate()
        controller.refresh(render)
        controller.retryLoadFailed(render)
        controller.open(tap)
        controller.loadMore(feed)
        await controller.whenIdle()
        XCTAssertEqual(rig.port?.pageCalls.count, pages)
        XCTAssertEqual(rig.port?.itemCalls.count, items)
        XCTAssertTrue(rig.opened.isEmpty)
    }

    /// LKG 的写入分区来自构造时固定的身份（含登录世代），不读写入时的当前世代（F-X-17）：e1 的控制器只写 e1 分区。
    func testLkgPartitionComesFromTheFixedIdentity() async {
        let epochTwo = HomeIdentity(env: "test", level: .member, userId: "user-a", loginEpoch: "e2")
        rig.port?.setPage(HomeKit.ok(page(6, "a_e1")))
        let controller = rig.controller(HomeKit.memberA)
        await rig.start(controller)
        XCTAssertEqual(rig.readLkgVersion(for: HomeKit.memberA), 6)
        XCTAssertNil(rig.readLkgVersion(for: epochTwo), "旧世代的结果写进了新世代分区")
    }

    /// 身份暂时未知（或会员缺登录世代）：照常在线拉取显示，但不读不写 LKG（F-X-19、F-X-21）。
    func testUnknownIdentityFetchesOnlineButNeitherReadsNorWritesLkg() async throws {
        try rig.seedLkg(page(3, "cached"))
        for identity in [
            HomeIdentity(env: "test", level: .member, userId: "user-a", loginEpoch: "e1", known: false),
            HomeIdentity(env: "test", level: .member, userId: "user-a", loginEpoch: nil),
        ] {
            rig.port?.setPage(HomeKit.ok(page(8, "online")))
            let controller = rig.controller(identity)
            await rig.start(controller)
            XCTAssertEqual(controller.state.sectionIds, ["online"], "\(identity)")
            XCTAssertEqual(controller.state.source, .network)
        }
        XCTAssertEqual(rig.readLkgVersion(), 3, "未确认身份写了 LKG")
    }

    /// 请求归属：页面拉取带构造时固定的网络归属；基本模式按匿名请求（G25，红线 6）。
    func testPageCallsCarryFixedOwnershipAndBasicModeIsAnonymous() async throws {
        let owner = RequestOwnership(account: "user-a", generation: 7, epoch: 2)
        let member = HomeIdentity(env: "test", level: .member, userId: "user-a", loginEpoch: "e1", request: owner)
        await rig.start(rig.controller(member))
        await rig.start(rig.controller(HomeKit.basic))
        let calls = try XCTUnwrap(rig.port?.pageCalls)
        XCTAssertEqual(calls.count, 2)
        guard calls.count == 2 else { return }
        XCTAssertEqual(calls[0].owner, owner)
        XCTAssertFalse(calls[0].anonymous)
        XCTAssertTrue(calls[1].anonymous, "基本模式必须匿名")
        XCTAssertNil(calls[1].owner)
    }

    /// 基本模式的 LKG 写在 basic 分区（G25）。
    func testBasicModeWritesBasicScope() async {
        rig.port?.setPage(HomeKit.ok(page(9, "basic")))
        await rig.start(rig.controller(HomeKit.basic))
        XCTAssertEqual(rig.readLkgVersion(for: HomeKit.basic), 9)
        XCTAssertNil(rig.readLkgVersion(for: HomeKit.guest))
    }

    /// 清理（撤回 / 切环境）发生在在途写入之前：迟到的结果不把 LKG 写回来（写入世代票据，共性第 23 条）。
    func testLateResultAfterClearAllDoesNotResurrectLkg() async throws {
        let hold = Hold()
        rig.port?.queuePage(.held(hold))
        let controller = rig.controller()
        controller.start()
        await waitFor("请求没发出") { rig.port?.pageCalls.count == 1 }
        try rig.lkg.clearAll()
        hold.release(HomeKit.ok(page(7, "late")))
        await controller.whenIdle()
        XCTAssertNil(rig.readLkgVersion())
    }
}
