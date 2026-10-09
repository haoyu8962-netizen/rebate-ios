import DesignSystem
import Foundation
import ProductSearch
@testable import Search
import XCTest

/// 平台购买状态的假配置源：`set` 改某个平台的取值并通知订阅者；`setSilently` 只改取值不通知（模拟配置已变、页面还没刷新）。
@MainActor
final class FakePurchaseSource: PurchaseStatusSource {
    private(set) var status: [String: String] = ["taobao": "on", "jd": "on", "pdd": "on"]
    private var handlers: [UUID: @MainActor () -> Void] = [:]

    var observerCount: Int {
        handlers.count
    }

    func purchaseStatus(platform: String) -> String? {
        status[platform]
    }

    func set(_ platform: String, _ value: String) {
        status[platform] = value
        handlers.values.forEach { $0() }
    }

    func setSilently(_ platform: String, _ value: String) {
        status[platform] = value
    }

    func observePurchaseStatus(_ handler: @escaping @MainActor () -> Void) -> SearchObservation {
        let id = UUID()
        handlers[id] = handler
        return SearchObservation { [weak self] in
            MainActor.assumeIsolated { self?.handlers[id] = nil }
        }
    }
}

/// APP-06a 第 3 轮：平台购买状态（R2-01，共性 27）、被详情盖住时保留滚动锚点（R2-02，共性 29）。
@MainActor
final class SearchRound3Tests: XCTestCase {
    private let consented: [String: Any] = ["loggedIn": true, "privacy": "consented"]
    /// 只替换两个用到的键，其余原样（看得出哪个键被取）。
    private let texts: (String) -> String = { key in
        switch key {
        case ProductCardKeys.retryLater: "稍后再试"
        case ProductCardKeys.platformComingSoon: "{platform_name}返利即将开放"
        default: key
        }
    }

    private func loadedDetail(_ source: FakePurchaseSource, platform: String = "taobao") async
        -> ProductDetailController {
        let api = ManualSearchApi()
        let value = consented
        let detail = ProductDetailController(
            api: api, platform: platform, productKey: "tb:milk", itemRef: nil, purchase: source, context: { value }
        )
        detail.start()
        await eventually { api.count == 1 }
        api.respond(0, SearchFixtures.envelope(0, data: SearchFixtures.card("tb:milk", platform: platform)))
        await eventually { detail.snapshot.phase == .content }
        return detail
    }

    /// 详情页显示的卡片数据（与 ProductDetailScreen.loaded 同一组合：映射后接入平台购买状态）。
    private func detailData(_ detail: ProductDetailController, platformName: String) -> ProductCardData {
        var data = ProductCardMapper.map(detail.snapshot.product ?? [:], texts: texts).data
        data.platformName = platformName
        return ProductCardMapper.applyPurchaseStatus(data, statusRaw: detail.snapshot.purchase.rawValue, texts: texts)
    }

    /// 详情页显示的按钮状态（底栏）。
    private func buttonState(_ detail: ProductDetailController, platformName: String) -> BuyButtonState {
        detailData(detail, platformName: platformName).buyState
    }

    // MARK: - R2-01 详情：配置 on → maintenance

    func testDetailConfigOnToMaintenanceDisablesBuyWithRetryLater() async {
        let source = FakePurchaseSource()
        let detail = await loadedDetail(source)
        XCTAssertEqual(detail.snapshot.purchase, .on)
        XCTAssertEqual(buttonState(detail, platformName: "淘宝"), .normal)
        XCTAssertTrue(detail.buyIntent())

        source.set("taobao", "maintenance")
        XCTAssertEqual(detail.snapshot.purchase, .maintenance, "订阅配置变化，立即更新")
        XCTAssertEqual(buttonState(detail, platformName: "淘宝"), .retryLater("稍后再试"), "置灰「稍后再试」")
        XCTAssertFalse(detail.canBuy)
        XCTAssertFalse(detail.buyIntent(), "维护中不发购买意图")

        source.set("taobao", "on")
        XCTAssertEqual(buttonState(detail, platformName: "淘宝"), .normal, "恢复 on 后按钮恢复")
        XCTAssertTrue(detail.buyIntent())
    }

    // MARK: - R2-01 详情：配置 on → not_launched

    func testDetailConfigOnToNotLaunchedShowsPlatformComingSoon() async {
        let source = FakePurchaseSource()
        let detail = await loadedDetail(source, platform: "pdd")
        XCTAssertTrue(detail.buyIntent())
        let before = detailData(detail, platformName: "拼多多")
        XCTAssertNotNil(before.estNet, "on：详情显示预估返后")
        XCTAssertFalse(before.rebateNotLaunched)
        source.set("pdd", "not_launched")
        XCTAssertEqual(detail.snapshot.purchase, .notLaunched)
        XCTAssertEqual(
            buttonState(detail, platformName: "拼多多"), .retryLater("拼多多返利即将开放"), "置灰并显示平台文案"
        )
        // R3-02：详情大卡随配置切换隐藏返利金额与预估返后，商品价格保留。
        let after = detailData(detail, platformName: "拼多多")
        XCTAssertTrue(after.rebateNotLaunched)
        XCTAssertNil(after.estNet)
        XCTAssertNil(after.estNetAccessibility)
        XCTAssertEqual(after.price.mainAmount, before.price.mainAmount)
        XCTAssertFalse(detail.buyIntent())
        // 别的平台变化不影响本页。
        source.set("taobao", "maintenance")
        XCTAssertEqual(detail.snapshot.purchase, .notLaunched)
    }

    /// 配置已变但页面还没收到通知：发出购买意图前再核对一次，不放行。
    func testBuyIntentRechecksCurrentStatus() async {
        let source = FakePurchaseSource()
        let detail = await loadedDetail(source)
        source.setSilently("taobao", "maintenance")
        XCTAssertEqual(detail.snapshot.purchase, .on, "还没通知")
        XCTAssertFalse(detail.buyIntent(), "点击时按此刻配置核对")
        XCTAssertEqual(detail.snapshot.purchase, .maintenance, "核对后界面同步置灰")
    }

    /// 打开时配置就不是 on；离开页面后注销订阅、不再更新。缺失或不认识的取值按 on（TODO(N-27)，点击时以 50301 为准）。
    func testInitialStatusLeaveAndUnknownValues() async {
        let source = FakePurchaseSource()
        source.set("jd", "maintenance")
        let detail = await loadedDetail(source, platform: "jd")
        XCTAssertEqual(detail.snapshot.purchase, .maintenance)
        XCTAssertFalse(detail.buyIntent())
        XCTAssertEqual(source.observerCount, 1)
        detail.leave()
        XCTAssertEqual(source.observerCount, 0, "出栈注销订阅")
        source.set("jd", "on")
        XCTAssertEqual(detail.snapshot.purchase, .maintenance, "离开后不再更新")
        XCTAssertEqual(PlatformPurchase.parse(nil), .on)
        XCTAssertEqual(PlatformPurchase.parse("bogus"), .on)
        XCTAssertEqual(PlatformPurchase.parse("not_launched"), .notLaunched)
    }

    // MARK: - R2-01 列表卡

    func testListCardBuyFollowsPurchaseStatus() {
        let source = FakePurchaseSource()
        let page = SearchPageConfig(
            controller: SearchController(api: ManualSearchApi(), config: FakeSearchConfig()), history: SearchHistory(),
            texts: TestTexts(), initialQuery: nil, initialPlatform: nil, purchase: source
        )
        XCTAssertTrue(page.buyAllowed(platform: "jd"))
        let revision = page.purchaseRevision
        source.set("jd", "maintenance")
        XCTAssertGreaterThan(page.purchaseRevision, revision, "订阅配置变化，列表重画")
        XCTAssertFalse(page.buyAllowed(platform: "jd"), "列表卡购买点击前核对")
        XCTAssertEqual(page.purchaseStatusRaw(platform: "jd"), "maintenance")
        XCTAssertEqual(
            ProductCardMapper.purchaseButtonState(.normal, statusRaw: "maintenance", platformName: "京东", texts: texts),
            .retryLater("稍后再试")
        )
        // R3-02：列表卡用同一映射，on → not_launched 前后返利金额与预估返后随之隐藏。
        let card = ProductCardMapper.map(
            SearchFixtures.object(SearchFixtures.card("pdd:a", platform: "pdd")), texts: texts
        ).data
        let shownOn = ProductCardMapper.applyPurchaseStatus(
            card, statusRaw: page.purchaseStatusRaw(platform: "pdd"), texts: texts
        )
        XCTAssertFalse(shownOn.rebateNotLaunched)
        XCTAssertNotNil(shownOn.estNet)
        source.set("pdd", "not_launched")
        XCTAssertFalse(page.buyAllowed(platform: "pdd"))
        let shownOff = ProductCardMapper.applyPurchaseStatus(
            card, statusRaw: page.purchaseStatusRaw(platform: "pdd"), texts: texts
        )
        XCTAssertTrue(shownOff.rebateNotLaunched)
        XCTAssertNil(shownOff.estNet)
        XCTAssertEqual(shownOff.price.mainAmount, shownOn.price.mainAmount, "商品价格保留")
        XCTAssertEqual(
            ProductCardMapper.purchaseButtonState(
                .normal, statusRaw: page.purchaseStatusRaw(platform: "pdd"), platformName: "拼多多", texts: texts
            ),
            .retryLater("拼多多返利即将开放")
        )
        XCTAssertTrue(page.buyAllowed(platform: "taobao"))
        XCTAssertEqual(
            ProductCardMapper.purchaseButtonState(.disabled, statusRaw: "on", platformName: "淘宝", texts: texts),
            .disabled,
            "on 不改原来的状态"
        )
    }

    // MARK: - R2-02 被详情盖住时保留锚点

    func testCoveredByDetailKeepsLastAnchorUntilNewQuery() async {
        let api = ManualSearchApi()
        let page = SearchPageConfig(
            controller: SearchController(api: api, config: FakeSearchConfig()), history: SearchHistory(),
            texts: TestTexts(), initialQuery: "milk", initialPlatform: nil
        )
        var saved: [SearchPageState] = []
        page.onStateChange = { saved.append($0) }
        page.start()
        await eventually { api.count == 1 }
        api.respond(0, SearchFixtures.envelope(0, data: SearchFixtures.page(
            ["tb:a", "tb:b", "tb:c", "tb:d"].map { SearchFixtures.card($0) }, more: false
        )))
        await eventually { page.controller.snapshot.phase == .content }
        // 滚下去：视口顶部是第 3 张卡，它的上部 40pt 已滚出视口。
        page.topResultCardChanged(index: 2, offset: -40)
        await eventually { saved.last?.scrollAnchor == 2 }
        XCTAssertEqual(saved.last?.scrollOffset, -40, "顶部卡的偏移一起保存（R3-01）")
        // 同一张卡内继续滚：只改偏移，稍后合并保存。
        page.topResultCardChanged(index: 2, offset: -71.6)
        await eventually { saved.last?.scrollOffset == -72 }
        XCTAssertEqual(saved.last?.scrollAnchor, 2)
        // 点卡片进详情：页面被盖住后不再上报（SearchView 按 listOnScreen 冻结），锚点与偏移保持。
        let coveredFrom = saved.count
        await settle()
        XCTAssertEqual(page.scrollAnchor, 2, "盖住时保留最后有效锚点")
        XCTAssertEqual(saved.last?.scrollAnchor, 2, "持久化的锚点不被清空（进程在详情页被回收后仍能回到原位置）")
        XCTAssertFalse(saved[coveredFrom...].contains { $0.scrollAnchor == nil }, "盖住过程中没有写过空锚点")
        // 新一轮查询：锚点重置。
        XCTAssertTrue(page.controller.submit("paper"))
        await eventually { api.count == 2 }
        await eventually { saved.last?.scrollAnchor == nil }
        XCTAssertNil(page.scrollAnchor, "新查询从顶部开始")
        XCTAssertNil(saved.last?.scrollOffset)
    }

    // MARK: - R3-01 按实际视口找顶部卡

    /// LazyVStack 会提前建出视口上方的卡（onAppear 早于真正可见）：顶部卡按框算，取第一张底边还在视口顶边以下的卡。
    func testViewportTopCardUsesActualFramesNotAppearedCards() {
        let frames: [Int: CGRect] = [
            0: CGRect(x: 16, y: -500, width: 340, height: 150), // 已建出、在视口上方很远
            1: CGRect(x: 16, y: -338, width: 340, height: 150),
            2: CGRect(x: 16, y: -176, width: 340, height: 150), // 底边 -26：已整张滚出
            3: CGRect(x: 16, y: -14, width: 340, height: 150), // 底边 136：视口顶部的卡
            4: CGRect(x: 16, y: 148, width: 340, height: 150),
        ]
        let top = SearchViewportTop.topCard(frames)
        XCTAssertEqual(top?.index, 3)
        XCTAssertEqual(top?.offset, -14)
        // 列表在顶部：第一张卡在横幅下面，偏移为正。
        XCTAssertEqual(SearchViewportTop.topCard([0: CGRect(x: 16, y: 16, width: 340, height: 150)])?.offset, 16)
        XCTAssertNil(SearchViewportTop.topCard([:]))
    }

    /// 保存的偏移跨进程带回来，恢复完成前不被新的上报覆盖；旧数据没有偏移时按 0。
    func testRestoredOffsetIsKeptUntilRestoreFinishes() async throws {
        let state = SearchPageState(
            conditions: SearchConditions(keyword: "milk"), input: "milk", scrollAnchor: 1, scrollOffset: -57
        )
        let decoded = try XCTUnwrap(SearchPageState.decode(state.encoded()))
        XCTAssertEqual(decoded.scrollOffset, -57)
        // 旧数据（第 3 轮之前保存的）没有 scrollOffset 键：编码时 nil 不写键，解出来仍为 nil。
        let legacyData = try XCTUnwrap(SearchPageState(input: "milk", scrollAnchor: 1).encoded())
        XCTAssertFalse((String(bytes: legacyData, encoding: .utf8) ?? "").contains("scrollOffset"))
        let legacy = try XCTUnwrap(SearchPageState.decode(legacyData))
        XCTAssertNil(legacy.scrollOffset, "旧数据没有偏移也能解出")

        let api = ManualSearchApi()
        let page = SearchPageConfig(
            controller: SearchController(api: api, config: FakeSearchConfig()), history: SearchHistory(),
            texts: TestTexts(), initialQuery: nil, initialPlatform: nil, restored: decoded
        )
        page.start()
        XCTAssertEqual(page.restoreTarget?.offset, -57)
        await eventually { api.count == 1 }
        api.respond(0, SearchFixtures.envelope(0, data: SearchFixtures.page(
            ["tb:a", "tb:b", "tb:c"].map { SearchFixtures.card($0) }, more: false
        )))
        await eventually { page.controller.snapshot.phase == .content }
        page.topResultCardChanged(index: 0, offset: 16)
        XCTAssertEqual(page.scrollAnchor, 1, "恢复完成前不记录")
        let target = try XCTUnwrap(page.restoreTarget)
        XCTAssertEqual(target.index, 1)
        XCTAssertEqual(target.offset, -57)
        page.endRestore(target)
        page.topResultCardChanged(index: 1, offset: -57)
        XCTAssertEqual(page.state().scrollAnchor, 1)
        XCTAssertEqual(page.state().scrollOffset, -57)
    }
}

private extension SearchFixtures {
    /// 卡片 JSON 文本 → 接口对象（与执行器解出的 [String: Any] 一致）。
    static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }
}
