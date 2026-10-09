import ClientCore
import Clipboard
import Config
@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Privacy
import ProductSearch
import Router
import Session
import SwiftUI
import UIKit
import XCTest

/// 可控的平台购买状态源（配置变化时手动通知）。
@MainActor
private final class StubPurchaseSource: PurchaseStatusSource {
    var statuses: [String: String] = [:]
    private var handlers: [UUID: @MainActor () -> Void] = [:]

    func purchaseStatus(platform: String) -> String? {
        statuses[platform]
    }

    func observePurchaseStatus(_ handler: @escaping @MainActor () -> Void) -> SearchObservation {
        let key = UUID()
        handlers[key] = handler
        return SearchObservation { [weak self] in
            MainActor.assumeIsolated { _ = self?.handlers.removeValue(forKey: key) }
        }
    }

    func change(_ platform: String, _ status: String) {
        statuses[platform] = status
        handlers.values.forEach { $0() }
    }
}

/// APP-07 iOS 第 3 轮评审 R3-01（共性第 32 条，APP-06a 共性第 31 条）、R3-02（共性第 33 条）。
extension ClipboardWiringTests {
    /// 普通可返利的淘宝卡：券后 ¥29.9、预估返 ¥2.69、预估返后 ¥27.21。
    private var rebateCard: [String: Any] {
        [
            "platform": "taobao", "product_key": "tb:milk", "item_ref": "ref-1", "link_id": "link-parse-1",
            "title": "洗衣液", "price_fen": 3990, "coupon_fen": 1000, "final_price_fen": 2990,
            "est_net_price_fen": 2721, "rebate_min_fen": 269, "rebate_max_fen": 269, "rebate_basis": "normal",
            "benefit_tags": [String](), "is_presale": false, "cta": ["text_key": "btn.buy.coupon"],
            "disclaimer_keys": ["price_basis", "rebate_compare"], "availability": "ok",
        ]
    }

    /// 卡上会被看到或读出的返利相关金额文字（返利标签、预估返后、底行说明及其读屏文字）。
    private func rebateTexts(_ data: ProductCardData) -> [String] {
        var all: [String] = []
        if !data.rebateNotLaunched { // 价格可用时 = ProductCardData.showsRebate
            all += [data.rebate.text, data.rebate.accessibilityText]
            all += [data.settlementNote].compactMap(\.self)
        }
        all += [data.estNetAccessibility].compactMap(\.self)
        return all
    }

    // MARK: - R3-01 多卡弹层应用平台购买状态

    /// 多卡结果的商品卡走与搜索卡同一映射：on 照常；配置变为 not_launched → 立即发布重画，返利金额、预估返后及读屏金额都不出现，
    /// 按钮置灰「淘宝返利即将开放」；变为 maintenance → 按钮置灰「稍后再试」、返利照常。
    /// 旧逻辑：ClipboardCardList 直接 ProductCardMapper.map，不读购买状态，not_launched 仍显示 2.69 / 27.21 与可点的购买按钮，
    /// maintenance 也不是「稍后再试」；配置变化也不会让弹层重画。
    func testR3_01_CardListAppliesPurchaseStatusAndFollowsConfigChanges() async throws {
        let fixture = make()
        let source = StubPurchaseSource()
        source.statuses["taobao"] = "on"
        fixture.clipboard.purchaseSource = source
        fixture.clipboard.sceneActive()
        fixture.api.reply = .multi(errorCode: 30131)
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await settle()
        guard case let .cardList(rows, _) = try XCTUnwrap(fixture.clipboard.result).kind else {
            return XCTFail("多卡弹层")
        }
        let rowCard = try XCTUnwrap(rows.first?.card)
        XCTAssertEqual(
            fixture.clipboard.cardMapping(rowCard).data.buyState,
            ProductCardMapper.map(rowCard, texts: AppSearchTexts().text).data.buyState,
            "on：结果卡（假卡缺价格字段）的按钮与原映射一致"
        )

        let on = fixture.clipboard.cardMapping(rebateCard).data
        XCTAssertFalse(on.rebateNotLaunched)
        XCTAssertEqual(on.buyState, .normal)
        XCTAssertTrue(rebateTexts(on).contains { $0.contains("2.69") }, "on：显示返利金额")
        XCTAssertNotNil(on.estNet)

        var published = 0
        let watch = fixture.clipboard.objectWillChange.sink { published += 1 }
        defer { watch.cancel() }

        source.change("taobao", "not_launched")
        XCTAssertGreaterThan(published, 0, "配置变化发布，弹层按新状态重画")
        let off = fixture.clipboard.cardMapping(rebateCard).data
        XCTAssertTrue(rebateTexts(on).contains { $0.contains("27.21") }, "on：读屏读预估返后")
        XCTAssertTrue(off.rebateNotLaunched)
        XCTAssertNil(off.estNet, "未开放：不显示预估返后")
        XCTAssertNil(off.estNetAccessibility, "未开放：读屏也不读预估返后")
        XCTAssertNil(off.settlementNote)
        XCTAssertFalse(rebateTexts(off).contains { $0.contains("2.69") || $0.contains("27.21") })
        XCTAssertEqual(off.price.mainAmount, on.price.mainAmount, "保留商品价格")
        XCTAssertEqual(off.buyState, .retryLater("淘宝返利即将开放"), "按钮置灰并显示平台文案")
        XCTAssertEqual(
            fixture.clipboard.cardMapping(rowCard).data.buyState, .retryLater("淘宝返利即将开放"), "弹层里的结果卡同样置灰"
        )

        let before = published
        source.change("taobao", "maintenance")
        XCTAssertGreaterThan(published, before)
        let maintenance = fixture.clipboard.cardMapping(rebateCard).data
        XCTAssertEqual(maintenance.buyState, .retryLater("稍后再试"), "维护中：按钮置灰「稍后再试」")
        XCTAssertFalse(maintenance.rebateNotLaunched, "维护中只改按钮")

        source.change("taobao", "on")
        XCTAssertEqual(fixture.clipboard.cardMapping(rebateCard).data.buyState, .normal, "恢复后按钮可点")
    }

    // MARK: - R3-02 连续同类结果各播报一次

    /// 首页显示结果视图；连续两次错误条（50001 → 30131，都是 notice）、再连续两次 30132（unrecognized）：每个新结果各播报一次，
    /// 普通重绘（其他状态发布）不重复播报。旧逻辑：播报挂在 onAppear，同类结果视图身份不变，第二次不再执行，只播第一次。
    func testR3_02_ConsecutiveSameKindResultsAnnounceOnceEach() async throws {
        let fixture = make()
        var spoken: [String] = []
        fixture.clipboard.announcer = { spoken.append($0) }
        fixture.clipboard.sceneActive()
        let window = hostHome(fixture.clipboard)
        defer { window.isHidden = true }

        func paste(_ reply: FakeParseApi.Reply) async {
            fixture.api.reply = reply
            fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
            await settle()
        }

        await paste(.failure(code: 50001))
        let first = try XCTUnwrap(fixture.clipboard.result)
        guard case let .notice(firstText) = first.kind else { return XCTFail("50001 为错误条") }
        try await waitUntil(window) { spoken.count == 1 }
        XCTAssertEqual(spoken, [firstText])

        await paste(.inline(code: 30131))
        let second = try XCTUnwrap(fixture.clipboard.result)
        XCTAssertNotEqual(second.id, first.id)
        guard case let .notice(secondText) = second.kind else { return XCTFail("30131 为错误条") }
        try await waitUntil(window) { spoken.count == 2 }
        XCTAssertEqual(spoken, [firstText, secondText], "第二个错误条同样播报")

        // 每次粘贴之间等界面显示（真实操作中两次点击之间结果已经出现）
        await paste(.inline(code: 30132))
        let third = try XCTUnwrap(fixture.clipboard.result)
        guard case let .unrecognized(unrecognized, _) = third.kind else { return XCTFail("30132") }
        try await waitUntil(window) { spoken.count == 3 }
        await paste(.inline(code: 30132))
        XCTAssertNotEqual(fixture.clipboard.result?.id, third.id)
        try await waitUntil(window) { spoken.count == 4 }
        XCTAssertEqual(Array(spoken.suffix(2)), [unrecognized, unrecognized], "连续两次未识别各播一次")

        // 普通重绘：其他状态发布、同一结果重新渲染，不再播报
        fixture.clipboard.busy.toggle()
        fixture.clipboard.busy.toggle()
        fixture.clipboard.objectWillChange.send()
        for _ in 0..<10 {
            render(window)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(spoken.count, 4, "重绘不重复播报")
    }

    private func hostHome(_ clipboard: AppClipboard) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        window.frame = UIScreen.main.bounds
        let controller = UIHostingController(rootView: HomeClipboardArea(clipboard: clipboard))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        render(window)
        return window
    }

    /// 让宿主界面按最新状态完成一次布局（SwiftUI 在布局时更新视图并执行 onAppear）。
    private func render(_ window: UIWindow) {
        window.rootViewController?.view.setNeedsLayout()
        window.rootViewController?.view.layoutIfNeeded()
    }

    private func waitUntil(_ window: UIWindow, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("等待超时") }
            render(window)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// R3-01 生产接线：AppSearch 接上剪贴板时把搜索卡的购买状态源交给它；单卡结果打开的详情页按同一来源（包内 pdd=not_launched）。
@MainActor
final class ClipboardPurchaseWiringTests: XCTestCase {
    private struct Device: DeviceCredentials {
        var deviceId: String? = "device-fixture"
        var installSecret: String? = "test-only.install.device-a"
    }

    private var suite = ""

    override func setUp() {
        suite = "ClipboardPurchaseWiringTests.\(UUID().uuidString)"
        AppStubProtocol.reset()
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        AppStubProtocol.reset()
    }

    /// 生产组装的搜索模块（包内配置：pdd=not_launched、taobao=on）与它的 Router。
    private func makeSearch() throws -> (AppSearch, AppRouting) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let tokens = MemorySessionTokens()
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = "consented"
        privacyStore.consentedVersion = "1"
        let runner = WithdrawalCleanupRunner(store: privacyStore, registry: withdrawal)
        let network = AppNetwork(
            tokens: tokens, pendingBackend: MemoryPendingKeyBackend(), device: Device(),
            withdrawalRegistry: withdrawal, environmentRegistry: environmentSwitch,
            credentialsReadable: { runner.credentialsReadable }, configuration: AppStubProtocol.configuration()
        )
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: environmentSwitch)
        let privacy = PrivacyController(
            store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1", withdrawalRunner: runner
        )
        let update = UpdateFixtures.makeUpdate()
        let routing = AppRouting(environment: environment, privacy: privacy, update: update)
        let config = AppConfig(
            client: network.client, file: ClientFile(name: suite + ".json"),
            environmentRegistry: EnvironmentSwitchCleanerRegistry(cleaners: [])
        )
        network.attach(environment: environment, privacy: privacy, update: update)
        routing.shellAppeared()
        let search = AppSearch(
            network: network, config: config, privacy: privacy, routing: routing, restorationDefaults: defaults
        )
        return (search, routing)
    }

    /// 旧逻辑：AppClipboard 没有购买状态源，多卡弹层的拼多多卡按 on 显示返利与可点按钮。
    func testR3_01_SearchWiringSharesPurchaseStatusWithCardListAndSingleCardDetail() throws {
        let (search, routing) = try makeSearch()
        let clipboard = AppClipboard(
            system: FakeSystemClipboard(), store: MemoryClipboardHashStore(), api: FakeParseApi(),
            router: routing.router,
            deps: AppClipboard.Deps(
                privacy: { .consented }, privacyPrompting: { false }, forceUpdate: { false },
                configJson: { "{}" }, guest: { true }, sessionGeneration: { 0 }, networkEpoch: { 0 }
            )
        )
        XCTAssertNil(clipboard.purchaseSource)
        search.clipboard = clipboard
        XCTAssertNotNil(clipboard.purchaseSource, "接线后与搜索卡共用购买状态源")

        let pdd: [String: Any] = [
            "platform": "pdd", "product_key": "pdd:x", "title": "纸巾", "price_fen": 3990, "coupon_fen": 1000,
            "final_price_fen": 2990, "est_net_price_fen": 2721, "rebate_min_fen": 269, "rebate_max_fen": 269,
            "rebate_basis": "normal", "benefit_tags": [String](), "is_presale": false,
            "cta": ["text_key": "btn.buy.coupon"], "disclaimer_keys": ["price_basis"], "availability": "ok",
        ]
        var taobao = pdd
        taobao["platform"] = "taobao"
        taobao["product_key"] = "tb:x"
        let hidden = clipboard.cardMapping(pdd).data
        XCTAssertTrue(hidden.rebateNotLaunched, "包内 pdd=not_launched：多卡弹层隐藏返利")
        XCTAssertNil(hidden.estNet)
        if case .retryLater = hidden.buyState {} else {
            XCTFail("拼多多卡按钮置灰")
        }
        let shown = clipboard.cardMapping(taobao).data
        XCTAssertFalse(shown.rebateNotLaunched)
        XCTAssertEqual(shown.buyState, .normal)

        // 单卡结果：以 parse 卡为种子打开详情，详情按同一来源置灰
        XCTAssertTrue(clipboard.openDetail(pdd))
        let destination = try XCTUnwrap(routing.router.path.last)
        XCTAssertEqual(destination.route, "ProductDetail")
        let detail = search.productPage(destination)
        XCTAssertEqual(detail.controller.snapshot.purchase, .notLaunched)
        XCTAssertFalse(detail.controller.buyIntent())
    }
}
