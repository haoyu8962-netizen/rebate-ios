@testable import Couli
import DesignSystem
import Foundation
import ProductSearch
import Router
import Search
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-A11Y（QA-12b iOS 报告 P2 搜索）：真实 App 组装的搜索页（OrdersAppFixture → AppTrade → AppSearch.searchPage → 生产 SearchView），
/// 搜索走本机假服务（AppStubProtocol + 调试假搜索 `DebugFakeSearch` 的第一页 3 张卡，不翻页）。打开 SwiftUI 无障碍树，按读屏的方式找、激活、擦除。
/// - A11Y-01：口径说明弹窗（message 构造器）能用读屏「返回」手势关闭，关闭后不跳页。
/// - A11Y-02：价格区间半屏能用「返回」手势关闭，底下的搜索页不出栈（报告「返回手势冒泡」一项在进程内这样判）。
/// - A11Y-04：结果卡读成一项、角色是按钮、双击（默认动作）进详情；卡内另外只有口径 i 与购买两个按钮（D10-1248 ⑦：不读看不见的字）。
/// - A11Y-09：价格区间不合法，点【确定】后播报原因。
@MainActor
final class A11ySearchTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var canvas: A11yCanvas?
    private var fixture: OrdersAppFixture?
    private var page: SearchPageConfig?

    override func setUpWithError() throws {
        suiteName = "a11y-search-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        AppStubProtocol.reset()
        AppStubProtocol.install(Self.answer)
    }

    override func tearDown() async throws {
        canvas?.close()
        canvas = nil
        page = nil
        fixture = nil
        defaults?.removePersistentDomain(forName: suiteName)
        AppStubProtocol.reset()
    }

    /// 假服务（网络线程）：搜索回调试假搜索第一页（去掉下一页）；其余回空成功。
    private nonisolated static func answer(_ request: AppStubProtocol.Recorded) -> AppStubProtocol.Reply {
        func envelope(_ code: Int, _ data: String) -> AppStubProtocol.Reply {
            .json(status: 200, body: "{\"code\":\(code),\"msg\":\"\",\"data\":\(data),\"trace_id\":\"t-a11y\"}")
        }
        guard request.path == "/v1/products/search",
              let first = DebugFakeSearch.answer(path: request.path, query: ["q": "milk", "platform": "taobao"]),
              var object = (try? JSONSerialization.jsonObject(with: Data(first.data.utf8))) as? [String: Any]
        else { return envelope(0, "{}") }
        object["has_more"] = false
        object["next_cursor"] = NSNull()
        return envelope(first.code, DebugFakeSearch.json(object))
    }

    // MARK: - 宿主

    private var router: Router {
        get throws { try XCTUnwrap(fixture).routing.router }
    }

    /// 打开搜索「milk」并等 3 张结果卡进无障碍树。
    private func openResults(width: CGFloat = 390, size: DynamicTypeSize = .large,
                             file: StaticString = #filePath, line: UInt = #line) async throws -> A11yCanvas {
        try A11yTree.enable(self)
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        self.fixture = fixture
        let runner = fixture.runner
        let trade = AppTrade(
            network: fixture.network, config: fixture.config, privacy: fixture.privacy, routing: fixture.routing,
            login: fixture.login, credentialsReadable: { runner.credentialsReadable }, track: { _, _ in }
        )
        let search = AppSearch(network: fixture.network, config: fixture.config, privacy: fixture.privacy,
                               routing: fixture.routing, trade: trade, restorationDefaults: defaults,
                               credentialsReadable: { runner.credentialsReadable })
        let router = fixture.routing.router
        router.open(RouteRequest(route: "Search", values: ["q": .string("milk"), "platform": .string("taobao")],
                                 from: .inApp))
        let destination = try XCTUnwrap(router.path.last, "Router 没有推入 Search", file: file, line: line)
        let config = search.searchPage(destination)
        page = config
        let canvas = A11yCanvas(AnyView(SearchView(config: config)), width: width, height: 1400, size: size)
        self.canvas = canvas
        let ready = await canvas.wait(10) { nodes in
            (0..<3).allSatisfy { index in nodes.contains { $0.id == "search.card.\(index)" } }
        }
        XCTAssertTrue(ready, "没有出 3 张结果卡（请求 \(AppStubProtocol.requests.map(\.path))）", file: file, line: line)
        return canvas
    }

    private func texts() throws -> SearchTexts {
        try XCTUnwrap(page).texts
    }

    private func cardTitle(_ index: Int) throws -> String {
        let items = try XCTUnwrap(page).controller.snapshot.items
        return try XCTUnwrap(items[index]["title"] as? String)
    }

    /// 卡内（容器 `search.card.<i>`）读屏能停留的元素。
    private func cardElements(_ canvas: A11yCanvas, _ index: Int) -> [A11yNode] {
        A11yTree.elements(canvas.root).filter { $0.inside("search.card.\(index)") }
    }

    // MARK: - A11Y-04 结果卡

    /// 每张卡：恰有一个整卡按钮（名称含商品名），另外只有口径 i 与购买两个按钮；没有零散文字项（标题、标签、价格、返利、副行不单独停）。
    func testResultCardIsOneButtonPlusInfoAndBuy() async throws {
        let canvas = try await openResults()
        let info = try texts().text(ProductCardKeys.disclaimerButton)
        for index in 0..<3 {
            let title = try cardTitle(index)
            let elements = cardElements(canvas, index)
            let dump = A11yTree.dump(elements)
            let summary = elements.filter { $0.isButton && $0.label.contains(title) }
            XCTAssertEqual(summary.count, 1, "卡 \(index)：要恰有一个读出商品名的整卡按钮：\n\(dump)")
            let others = elements.filter { !($0.isButton && $0.label.contains(title)) }
            XCTAssertTrue(others.allSatisfy(\.isButton), "卡 \(index)：除整卡外只能是按钮（i、购买），不能有零散文字项：\n\(dump)")
            XCTAssertLessThanOrEqual(others.count, 2, "卡 \(index)：整卡之外最多 i 与购买两项：\n\(dump)")
            XCTAssertEqual(others.filter { $0.label == info }.count, 1, "卡 \(index)：口径 i 仍是独立按钮：\n\(dump)")
            XCTAssertTrue(elements.allSatisfy { $0.frame.width > 1 && $0.frame.height > 1 && canvas.window.bounds
                              .intersects($0.frame)
            },
            "卡 \(index)：读屏项都要看得见（D10-1248 ⑦）：\n\(dump)")
            XCTAssertFalse(A11yTree.nodes(canvas.root).contains { $0.inside("search.card.\(index)") && $0.isHeader },
                           "卡 \(index)：列表卡内不能有「标题」角色的项（商品名不是标题，SearchRound3 同口径）：\n\(dump)")
        }
    }

    /// 读屏双击整卡（默认动作）进商品详情。
    func testActivatingCardOpensDetail() async throws {
        let canvas = try await openResults()
        let title = try cardTitle(0)
        let summary = try XCTUnwrap(cardElements(canvas, 0).first { $0.isButton && $0.label.contains(title) },
                                    "没有整卡按钮：\n\(A11yTree.dump(cardElements(canvas, 0)))")
        let before = try router.path.count
        XCTAssertTrue(A11yTree.activate(summary), "整卡按钮的默认动作没有接住")
        await canvas.pump(0.6)
        XCTAssertEqual(try router.path.count, before + 1, "双击整卡要推入一页")
        XCTAssertEqual(try router.path.last?.route, "ProductDetail")
    }

    // MARK: - A11Y-01 口径说明弹窗

    func testDisclaimerDialogClosesWithEscape() async throws {
        let canvas = try await openResults()
        let texts = try texts()
        let info = try XCTUnwrap(
            cardElements(canvas, 0).first { $0.label == texts.text(ProductCardKeys.disclaimerButton) },
            "卡 0 没有口径 i：\n\(A11yTree.dump(cardElements(canvas, 0)))"
        )
        XCTAssertTrue(A11yTree.activate(info), "口径 i 没有接住双击")
        let title = texts.text(SearchKeys.disclaimerTitle)
        // 弹窗标题与卡内口径 i 同名：按标题角色认弹窗标题（i 按钮不是标题，关弹窗后它仍在）
        let isDialogTitle: (A11yNode) -> Bool = { $0.label == title && $0.isElement && $0.isHeader }
        let opened = await canvas.wait { $0.contains(where: isDialogTitle) }
        XCTAssertTrue(opened, "口径说明弹窗没有打开")
        let node = try XCTUnwrap(A11yTree.elements(canvas.root).first(where: isDialogTitle))
        let before = try router.path.count
        XCTAssertTrue(A11yTree.escape(from: node.object), "弹窗没有接住读屏「返回」手势（A11Y-01）")
        let closed = await canvas.wait { !$0.contains(where: isDialogTitle) }
        XCTAssertTrue(closed, "「返回」手势后弹窗要关闭，等同【知道了】")
        XCTAssertEqual(try router.path.count, before, "关闭弹窗不能把搜索页退掉")
    }

    // MARK: - A11Y-02 价格区间半屏

    func testPriceSheetClosesWithEscapeAndPageStays() async throws {
        let canvas = try await openResults()
        let config = try XCTUnwrap(page)
        config.showsPriceSheet = true
        let ready = await canvas.wait { $0.contains { $0.id == "search.price.min" } }
        XCTAssertTrue(ready, "价格半屏没有打开")
        let field = try XCTUnwrap(A11yTree.node("search.price.min", in: canvas.root))
        let before = try router.path.count
        XCTAssertTrue(A11yTree.escape(from: field.object), "半屏没有接住读屏「返回」手势（A11Y-02）")
        await canvas.pump(0.6)
        XCTAssertFalse(config.showsPriceSheet, "「返回」手势要关闭半屏，等同关闭键")
        XCTAssertEqual(try router.path.count, before, "手势不能冒泡到导航把搜索页退掉")
    }

    // MARK: - A11Y-09 价格不合法

    func testInvalidPriceIsAnnounced() async throws {
        let canvas = try await openResults()
        A11yAudit.installTap(self, voiceOver: true)
        let config = try XCTUnwrap(page)
        config.priceDraftMin = "100"
        config.priceDraftMax = "1"
        config.showsPriceSheet = true
        let ready = await canvas.wait { $0.contains { $0.id == "search.price.confirm" } }
        XCTAssertTrue(ready, "价格半屏没有打开")
        let confirm = try XCTUnwrap(A11yTree.node("search.price.confirm", in: canvas.root))
        XCTAssertTrue(A11yTree.activate(confirm), "【确定】没有接住双击")
        let invalid = try texts().text(SearchKeys.sheetInvalid)
        let shown = await canvas.wait { $0.contains { $0.id == "search.price.invalid" } }
        XCTAssertTrue(shown, "前提：最低价高于最高价要出提示行")
        let post = await A11yAudit.waitAnnouncement(containing: invalid)
        XCTAssertNotNil(post, "价格区间不合法要播报「\(invalid)」（A11Y-09）；实际：\(A11yPostTap.posts)")
        XCTAssertTrue(config.showsPriceSheet, "半屏保留")
    }
}
