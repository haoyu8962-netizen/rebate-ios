@testable import Couli
import Foundation
import OrderCore
import Orders
import SnapshotTesting
import SwiftUI
import UIKit
import XCTest

/// APP-08v-a 订单列表整页基准（brief §2.6 状态矩阵、§5）：真实 App 组装、visualOrders 同一份数据、固定时钟、与画板同宽同高。
/// 名字与 Android `app/src/test/snapshots/order-list-v/` 同名。默认只比对（缺图失败）；`COULI_RECORD_SNAPSHOTS=1` 只录缺图。
/// 不带底部 Tab（外壳归 APP-11v），底部按主屏指示条留 34。末卡出现时生产执行器自动翻页，假服务回空页（页脚稳定；compare 记 C6）。
/// 翻页加载中（菊花动画，两帧不一致）不拍，翻页失败另拍。
@MainActor
final class OrderListVisualSnapshotTests: OrderVisualTestCase {
    struct Shot {
        let name: String
        var script: () throws -> OrderVisualStub.Script
        var canvas = OrderVisualHost.Canvas()
        var scope: String?
        var hidden = false
        var stale = false
        var waitFor: String? = "order.card.A"
        var images: [String] = ["A", "C"]
        var after: (@MainActor (OrderVisualHost) -> Void)?
        var settle: (@MainActor (OrderVisualHost) -> Bool)?
    }

    private func page(_ name: String, scope: String = "self") -> () throws -> OrderVisualStub.Script {
        { [unowned self] in
            var script = try listScript()
            script.pages[scope] = try .data(OrderVisualData.page(name))
            return script
        }
    }

    func testArtboardsLight() async throws {
        try await run([
            Shot(name: "Orders-v2-light", script: { try self.listScript() }, canvas: .init(height: 1740)),
            Shot(name: "OrdersShare-v2-light", script: { try self.listScript() }, canvas: .init(height: 1492),
                 scope: "share", waitFor: "order.card.E", images: []),
            Shot(name: "OrdersEmpty-light", script: page("list_self_empty"), waitFor: "orders.empty", images: []),
            Shot(name: "OrdersShareEmpty-light", script: page("list_share_empty", scope: "share"), scope: "share",
                 waitFor: "orders.empty", images: []),
            Shot(name: "OrdersClaimPinned-light", script: page("list_self_pinned"), canvas: .init(height: 2075)),
            Shot(name: "OrdersHidden-light", script: { try self.listScript() }, canvas: .init(height: 1951),
                 hidden: true),
            Shot(name: "OrdersStale-v2-light", script: { try self.listScript() }, canvas: .init(height: 1794),
                 stale: true, waitFor: "orders.stale"),
            Shot(name: "OrdersSearch-v2-light", script: search, after: { $0.submit("纯牛奶") },
                 settle: { $0.probes["orders.searchFound"] != nil }),
            Shot(name: "OrdersSearchEmpty-light", script: search, scope: "share", waitFor: "order.card.E", images: [],
                 after: { $0.submit("xyz") }, settle: { $0.probes["orders.empty"] != nil }),
            Shot(name: "OrdersFilterPlatform-v2-light", script: { try self.listScript() },
                 after: { $0.orders.listConfig?.sheet = .platform },
                 settle: { $0.probes["orders.sheet.option.taobao"] != nil }),
            Shot(name: "OrdersFilterMonth-v2-light", script: page("month_options"),
                 after: { $0.orders.listConfig?.sheet = .month },
                 settle: { $0.probes["orders.sheet.option.2026-07"] != nil }),
        ])
    }

    func testArtboardsDark() async throws {
        let dark = OrderVisualHost.Canvas(dark: true)
        try await run([
            Shot(name: "OrdersDark-dark", script: { try self.listScript() }, canvas: .init(height: 2015, dark: true)),
            Shot(name: "OrdersShare-v2-dark", script: { try self.listScript() },
                 canvas: .init(height: 1492, dark: true), scope: "share", waitFor: "order.card.E", images: []),
            Shot(name: "OrdersEmpty-dark", script: page("list_self_empty"), canvas: dark, waitFor: "orders.empty",
                 images: []),
            Shot(name: "OrdersShareEmpty-dark", script: page("list_share_empty", scope: "share"), canvas: dark,
                 scope: "share", waitFor: "orders.empty", images: []),
            Shot(name: "OrdersClaimPinned-dark", script: page("list_self_pinned"),
                 canvas: .init(height: 2075, dark: true)),
            Shot(name: "OrdersHidden-dark", script: { try self.listScript() }, canvas: .init(height: 1951, dark: true),
                 hidden: true),
            Shot(name: "OrdersStale-v2-dark", script: { try self.listScript() },
                 canvas: .init(height: 1794, dark: true), stale: true, waitFor: "orders.stale"),
            Shot(name: "OrdersSearch-v2-dark", script: search, canvas: dark, after: { $0.submit("纯牛奶") },
                 settle: { $0.probes["orders.searchFound"] != nil }),
            Shot(name: "OrdersSearchEmpty-dark", script: search, canvas: dark, scope: "share",
                 waitFor: "order.card.E", images: [], after: { $0.submit("xyz") },
                 settle: { $0.probes["orders.empty"] != nil }),
            Shot(name: "OrdersFilterPlatform-v2-dark", script: { try self.listScript() }, canvas: dark,
                 after: { $0.orders.listConfig?.sheet = .platform },
                 settle: { $0.probes["orders.sheet.option.taobao"] != nil }),
            Shot(name: "OrdersFilterMonth-v2-dark", script: page("month_options"), canvas: dark,
                 after: { $0.orders.listConfig?.sheet = .month },
                 settle: { $0.probes["orders.sheet.option.2026-07"] != nil }),
        ])
    }

    /// 无稿页面状态：加载骨架、首屏错误（trace6）、翻页失败、查询范围提示。
    func testPageStates() async throws {
        try await run([
            Shot(name: "state-loading-light", script: hold, waitFor: "orders.skeleton.0.card", images: []),
            Shot(name: "state-loading-dark", script: hold, canvas: .init(dark: true), waitFor: "orders.skeleton.0.card",
                 images: []),
            Shot(name: "state-error-light", script: failing, waitFor: nil, images: [],
                 settle: { _ in OrderVisualStub.orderRequests.count == 1 }),
            Shot(name: "state-error-dark", script: failing, canvas: .init(dark: true), waitFor: nil, images: [],
                 settle: { _ in OrderVisualStub.orderRequests.count == 1 }),
            Shot(name: "state-pagination-error-light", script: pageError, canvas: .init(height: 1740),
                 settle: { $0.probes["orders.pageError"] != nil }),
            Shot(name: "state-history-range-light", script: page("history"), canvas: .init(height: 1740),
                 settle: { $0.probes["orders.historyHint"] != nil }),
        ])
    }

    /// 适配：200%（AX3）× 390 浅 / 深、× 320（已选「拼多多」「2026 年 10 月」）；840；半屏窗口内真 200%。
    func testAdaptation() async throws {
        let ax = DynamicTypeSize.accessibility3
        try await run([
            Shot(name: "Orders-font200-w390-light", script: page("stress"), canvas: .init(height: 1200, size: ax),
                 waitFor: "order.card.STRESS", images: []),
            Shot(name: "Orders-font200-w390-dark", script: page("stress"),
                 canvas: .init(height: 1200, dark: true, size: ax), waitFor: "order.card.STRESS", images: []),
            Shot(name: "Orders-font200-w320-light", script: page("stress"),
                 canvas: .init(width: 320, height: 1400, size: ax), waitFor: "order.card.STRESS", images: [],
                 after: { host in
                     _ = host.orders.listConfig?.controller.setPlatform("pdd")
                     _ = host.orders.listConfig?.controller.setMonth("2026-10")
                 },
                 // v3（评审 r1 S2-2）：筛选会重新加载，骨架也是静止画面——就绪必须是新条件下的卡片已加载
                 settle: { host in
                     guard let snapshot = host.orders.listConfig?.controller.snapshot else { return false }
                     return snapshot.phase == .content && snapshot.query.platform == "pdd"
                         && snapshot.query.month == "2026-10" && host.probes["order.card.STRESS"] != nil
                         && host.probes["order.card.STRESS.amount.right"] != nil
                 }),
            Shot(name: "Orders-w840-light", script: page("list_self_pinned"), canvas: .init(width: 840, height: 2075)),
            Shot(name: "OrdersFilterPlatform-v2-light-font200", script: { try self.listScript() },
                 canvas: .init(size: ax), after: { $0.orders.listConfig?.sheet = .platform },
                 settle: { $0.probes["orders.sheet.option.taobao"] != nil }),
            Shot(name: "OrdersFilterMonth-v2-light-font200", script: page("month_options"), canvas: .init(size: ax),
                 after: { $0.orders.listConfig?.sheet = .month },
                 settle: { $0.probes["orders.sheet.option.all"] != nil }),
        ])
    }

    // MARK: - 脚本

    private func search() throws -> OrderVisualStub.Script {
        try listScript(extra: [
            "q:纯牛奶": .data(OrderVisualData.page("search_self")),
            "q:xyz": .data(OrderVisualData.page("search_share_empty")),
        ])
    }

    private func hold() throws -> OrderVisualStub.Script {
        try listScript(extra: ["self": .hold])
    }

    private func failing() throws -> OrderVisualStub.Script {
        try listScript(extra: ["self": .error(50001)])
    }

    private func pageError() throws -> OrderVisualStub.Script {
        try listScript(extra: ["cursor:visual-next-2": .error(50001)])
    }

    // MARK: - 执行

    private func run(_ shots: [Shot], file: StaticString = #filePath, testName: String = #function,
                     line: UInt = #line) async throws {
        for shot in shots {
            try await take(shot, file: file, testName: testName, line: line)
        }
    }

    private func take(_ shot: Shot, file: StaticString, testName: String, line: UInt) async throws {
        let page = try fresh(shot.script())
        page.setHidden(shot.hidden)
        if shot.stale {
            try await page.prepareStale(shot.canvas)
        } else {
            await page.showList(shot.canvas, scope: shot.scope)
        }
        // 初始页面就绪：等待项出现、有图的卡画出测试位图（与 after 无关）。
        let initial: (OrderVisualHost, UIImage) -> Bool = { host, image in
            if let waitFor = shot.waitFor, host.probes[waitFor] == nil {
                return false
            }
            return shot.images.allSatisfy { id in
                host.probes["order.card.\(id)"] == nil || host.thumbnailDrawn(image, id: id)
            }
        }
        var image: UIImage?
        if let after = shot.after {
            // v3（评审 r1 S2-2）：操作之后不再沿用初始等待项，所以每个有操作的镜头都必须给出能区分结果的 settle
            guard shot.settle != nil else {
                XCTFail("\(shot.name)：有 after 的镜头必须带 settle（区分操作后的结果，不能让静止骨架冒充就绪）", file: file,
                        line: line)
                return
            }
            // v2（实现交回 T2 / T3）：先等初始页面就绪（含商品图）再操作；操作之后不再要求初始等待项（搜索无结果后那张卡已不在，
            // 与「空态」互斥），只看 settle + 两帧一致；半屏遮罩把测试位图压暗，开着半屏时不再复核三段色。
            _ = await page.stable(file: file, line: line, until: initial)
            after(page)
            image = await page.stable(file: file, line: line) { host, image in
                guard shot.settle?(host) ?? true else { return false }
                // 半屏开着时整页盖遮罩，测试位图被压暗：只在没有遮罩时复核商品图（搜索结果等）
                return host.orders.listConfig?.sheet != nil || shot.images.allSatisfy { id in
                    host.probes["order.card.\(id)"] == nil || host.thumbnailDrawn(image, id: id)
                }
            }
        } else {
            image = await page.stable(file: file, line: line) { host, image in
                if let settle = shot.settle, !settle(host) {
                    return false
                }
                return initial(host, image)
            }
        }
        guard let image else { return }
        XCTAssertEqual(image.size, CGSize(width: shot.canvas.width, height: shot.canvas.height),
                       "\(shot.name)：画布尺寸", file: file, line: line)
        withSnapshotTesting(record: ProcessInfo.processInfo
            .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: shot.name,
                               file: file, testName: testName, line: line)
            }
    }
}

extension OrderVisualHost {
    /// 搜索框输入并提交（生产执行器的同一入口：键入不发请求，提交才搜）。
    func submit(_ keyword: String) {
        guard let controller = orders.listConfig?.controller else { return }
        controller.updateSearchText(keyword)
        _ = controller.submitSearch()
    }
}
