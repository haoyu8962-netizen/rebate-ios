import CouliNetwork
import DesignSystem
import Foundation
import OrderCore
import Orders
import Session
import XCTest

/// APP-08 iOS 第 1 轮评审（NATIVE/APP-08/ios-review-r1.md）：R1-05 服务端校准时钟（跨日、跨年）、R1-06 延迟对齐复核、
/// I07 补页期间用户滚动取消恢复。共性第 34、35 条；APP-06a 第 38、41 条。
@MainActor
final class OrderReviewR1ClockAndRestoreTests: XCTestCase {
    private var env = FakeOrderEnv()

    override func setUp() async throws {
        env = FakeOrderEnv()
    }

    /// 记下延迟对齐实际滚动到的目标。
    @MainActor
    private final class Scrolls {
        var ids: [String] = []

        func add(_ id: String) {
            ids.append(id)
        }
    }

    // MARK: - R1-05：服务端校准时钟

    private static func epoch(_ iso: String) throws -> Int64 {
        let formatter = ISO8601DateFormatter()
        let date = try XCTUnwrap(formatter.date(from: iso))
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func httpDate(_ millis: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }

    /// 本机时钟 = 服务端 + `skew`；列表响应带服务端 Date。返回校准后的时刻。
    private func calibratedNow(server: Int64, skew: Int64) async -> Int64 {
        let device = server + skew
        OrdersStub.install { _ in
            .json(status: 200, headers: ["Date": Self.httpDate(server)],
                  body: OrderFixtures.envelope(0, data: OrderFixtures.page([])))
        }
        let client = ApiClient(
            identity: ClientIdentity(platform: "ios", appVersion: "9.9.9", build: "1", channel: "appstore"),
            context: {
                NetworkContext(
                    privacy: PrivacyRaw.full, environmentSettled: true, credentialsReadable: true,
                    update: UpdateRaw.supported, apiBaseURL: URL(string: "https://api.test.invalid")
                )
            },
            device: OrdersStubDevice(),
            tokens: MemorySessionTokens(access: "at-1", refresh: "rt-1", scope: "full", account: "user-a"),
            pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
            configuration: OrdersStub.configuration(),
            clock: { device },
            sleeper: { _ in }
        )
        XCTAssertEqual(client.calibratedNowMillis, device, "没校过：本机时钟")
        let list = OrderListController(api: client, gate: OrderRateGate(), env: env, cache: nil)
        list.start()
        await eventually { list.snapshot.phase == .empty }
        return client.calibratedNowMillis
    }

    /// 跨日：服务端 10-10 10:00，手机快一天；付款 10-10 09:00 → 「今天 09:00」（不是「昨天」）。
    func testCalibratedClockAcrossDay() async throws {
        let server = try Self.epoch("2026-10-10T10:00:00+08:00")
        let paid = try Self.epoch("2026-10-10T09:00:00+08:00")
        let now = await calibratedNow(server: server, skew: 86_400_000)
        XCTAssertEqual(now, server)
        XCTAssertEqual(CouliFormat.timeListPast(epochMillis: paid, nowEpochMillis: now), "今天 09:00")
        XCTAssertEqual(
            CouliFormat.timeListPast(epochMillis: paid, nowEpochMillis: server + 86_400_000), "昨天 09:00",
            "未校准时的错误显示（对照）"
        )
    }

    /// 跨年：服务端 2027-01-01 08:00，手机慢两天（还在 2026 年）；付款 2026-06-01 → 「2026-06-01」（不是同年的「06-01」）；
    /// 缓存时间提示同样按校准时钟。
    func testCalibratedClockAcrossYear() async throws {
        let server = try Self.epoch("2027-01-01T08:00:00+08:00")
        let paid = try Self.epoch("2026-06-01T12:00:00+08:00")
        let now = await calibratedNow(server: server, skew: -2 * 86_400_000)
        XCTAssertEqual(now, server)
        XCTAssertEqual(CouliFormat.timeListPast(epochMillis: paid, nowEpochMillis: now), "2026-06-01")
        XCTAssertEqual(
            CouliFormat.timeListPast(epochMillis: paid, nowEpochMillis: server - 2 * 86_400_000), "06-01",
            "未校准时的错误显示（对照）"
        )
        let cachedAt = try Self.epoch("2026-12-31T23:30:00+08:00")
        XCTAssertEqual(CouliFormat.timeListPast(epochMillis: cachedAt, nowEpochMillis: now), "昨天 23:30")
    }

    /// 偏差不超过 300 秒不校正（秒级延迟不抖动）。
    func testSmallSkewNotCalibrated() async throws {
        let server = try Self.epoch("2026-10-10T10:00:00+08:00")
        let now = await calibratedNow(server: server, skew: 120_000)
        XCTAssertEqual(now, server + 120_000)
    }

    // MARK: - R1-06 / I07：延迟锚点对齐

    /// 带一次待执行延迟回调的列表页（回调由测试手动执行）。
    private final class Deferred {
        var works: [@MainActor () -> Void] = []

        @MainActor
        func run() {
            let pending = works
            works = []
            pending.forEach { $0() }
        }
    }

    private func restoringPage(target: String = "o7") async -> (OrderListPageConfig, Deferred) {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.page([
            OrderFixtures.row("o1"),
            OrderFixtures.row(target),
        ])) }
        let controller = OrderListController(api: makeOrdersClient(), gate: OrderRateGate(), env: env, cache: nil)
        let page = OrderListPageConfig(controller: controller, texts: OrderDraftTexts(), mask: AmountMaskStore(
            defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard
        ), pendingTrack: nil)
        let deferred = Deferred()
        page.nextLoop = { work in deferred.works.append(work) }
        page.anchor.begin(target: target)
        controller.start()
        await eventually { controller.snapshot.phase == .content }
        return (page, deferred)
    }

    func testDelayedAlignRunsOnceWhenStillValid() async {
        let (page, deferred) = await restoringPage()
        let scrolled = Scrolls()
        page.restoreStep { scrolled.add($0) }
        XCTAssertTrue(scrolled.ids.isEmpty, "对齐放到下一轮主循环")
        deferred.run()
        XCTAssertEqual(scrolled.ids, ["o7"])
        XCTAssertEqual(page.anchor.moves, 1)
    }

    /// 回调执行前会话换代 / 环境清理（App 走 invalidate + leave）：不滚动、恢复任务取消、不再记录。
    func testDelayedAlignSkippedAfterInvalidate() async {
        let (page, deferred) = await restoringPage()
        let scrolled = Scrolls()
        page.restoreStep { scrolled.add($0) }
        page.invalidate()
        page.controller.leave()
        deferred.run()
        XCTAssertTrue(scrolled.ids.isEmpty, "失效后不得滚动")
        XCTAssertFalse(page.anchor.restoring)
        XCTAssertFalse(page.recordTop("o1"), "失效后不得记录 / 持久化")
    }

    /// 回调执行前 App 侧会话 / 隐私 / 环境版本变了（还没走到同步出口）：同样不滚动并取消恢复。
    func testDelayedAlignSkippedWhenPageNoLongerCurrent() async {
        let (page, deferred) = await restoringPage()
        var current = true
        page.isCurrent = { current }
        let scrolled = Scrolls()
        page.restoreStep { scrolled.add($0) }
        current = false
        deferred.run()
        XCTAssertTrue(scrolled.ids.isEmpty)
        XCTAssertFalse(page.anchor.restoring)
    }

    /// 只有页面执行器离开（leave 不改轮次）：回调同样不滚动。
    func testDelayedAlignSkippedWhenControllerLeft() async {
        let (page, deferred) = await restoringPage()
        let scrolled = Scrolls()
        page.restoreStep { scrolled.add($0) }
        page.controller.leave()
        deferred.run()
        XCTAssertTrue(scrolled.ids.isEmpty)
    }

    /// I07：目标还没加载、正在补页时用户滚动了列表 → 恢复取消；目标页随后到达也不把用户拉回旧目标。
    func testUserScrollDuringLoadMoreCancelsRestore() async {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1")], next: "c2")) }
        let controller = OrderListController(api: makeOrdersClient(), gate: OrderRateGate(), env: env, cache: nil)
        let page = OrderListPageConfig(controller: controller, texts: OrderDraftTexts(), mask: AmountMaskStore(
            defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard
        ), pendingTrack: nil)
        let deferred = Deferred()
        page.nextLoop = { work in deferred.works.append(work) }
        page.anchor.begin(target: "o7")
        // 列表首次可交互（加载中就报告位置）：建立基准
        page.scrolled(offset: 0)
        controller.start()
        await eventually { controller.snapshot.phase == .content }
        OrdersStub.install { _ in .hold("more") }
        let scrolled = Scrolls()
        page.restoreStep { scrolled.add($0) }
        await eventually { OrdersStub.isHeld("more") }
        XCTAssertTrue(controller.snapshot.loadingMore, "目标未加载：补页中")
        // 补页期间用户（或读屏、惯性）滚动了列表
        page.scrolled(offset: -240)
        XCTAssertFalse(page.anchor.restoring, "被本任务以外的原因移动：取消恢复")
        OrdersStub.release("more", with: OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o7")])))
        await eventually { controller.snapshot.items.count == 2 }
        page.restoreStep { scrolled.add($0) }
        deferred.run()
        XCTAssertTrue(scrolled.ids.isEmpty, "不把用户拉回旧目标")
        XCTAssertTrue(page.recordTop("o3"), "取消后按实际视口记录")
    }

    /// 排版取整误差以内的位置报告不算移动。
    func testSubPointJitterDoesNotCancelRestore() {
        let keeper = OrderAnchorKeeper()
        keeper.begin(target: "o7")
        keeper.observe(offset: 12)
        keeper.observe(offset: 12.5)
        XCTAssertTrue(keeper.restoring)
        keeper.observe(offset: 40)
        XCTAssertFalse(keeper.restoring)
    }
}
