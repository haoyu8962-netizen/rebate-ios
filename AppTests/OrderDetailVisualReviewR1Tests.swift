@testable import Couli
import DesignSystem
import Foundation
import OrderCore
import Router
import SwiftUI
import UIKit
import XCTest

/// APP-08v-b iOS 测试 b v2：独立评审 r1（review-b-ios-r1.md）的测试缺口。
/// - S2-2：【刷新】在 42901 共享禁用期内、请求在途时置灰（两帧一致后取色 = 禁用令牌底色）；禁用期内按钮动作零请求；
/// - S2-1：已结算 + 下发【联系客服】：底栏【去提现】是实心主按钮，整页至少一个实心主按钮；
/// - S2-4：【问问 AI】的 App 出口经 Router 判定后确实进入 AgentChat（Tab 根），参数带 context.order_id。
///
/// 进程内没有触摸合成；读屏激活在宿主里也拿不到 SwiftUI 读屏树（b v2 首跑实测：`orderDetail.refresh` 找不到）。
/// 所以这里「点」= 调用按钮绑定的同一个动作（`controller.refresh()` / 页面配置的 `onAskAI`），真触摸的次数与落地断言在
/// UI 用例 `OrderDetailVisualUITests` 里（在途连点三下恰好一次 getOrder；问问 AI 后 Tab 切到「AI 助手」）。
/// 42901 只能在进程内造：UI 用例的假服务注入（COULI_FAKE_ORDER_VISUAL）只会回成功或 30701，没有 42901 的输入。
@MainActor
final class OrderDetailVisualReviewR1Tests: OrderVisualTestCase {
    private func controller(_ page: OrderVisualHost) throws -> OrderDetailController {
        try XCTUnwrap(page.orders.details.values.compactMap(\.controller).first, "没有详情执行器")
    }

    private func waitUntil(_ what: String, seconds: Double = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("等待超时：\(what)", file: file, line: line)
    }

    private func detailRequests() -> Int {
        OrderVisualStub.orderRequests.filter { $0.line == "GET /v1/orders/M" }.count
    }

    private var disabledFill: ProductVisualPixels.RGB {
        ProductVisualPixels.RGB(CouliColor.token("button.primary.disabled.background"), dark: false)
    }

    private func refreshFill(_ image: UIImage?, file: StaticString = #filePath,
                             line: UInt = #line) throws -> ProductVisualPixels.RGB {
        let image = try XCTUnwrap(image, "没截到稳定画面", file: file, line: line)
        let refresh = try rect("orderDetail.refresh", file: file, line: line)
        return ProductVisualPixels(image).color(at: CGPoint(x: refresh.minX + 6, y: refresh.midY))
    }

    /// 未知状态详情（订单 M），内容态、【刷新】不置灰。
    private func openUnknown() async throws -> OrderVisualHost {
        let detail = try OrderVisualData.detail("detail_unknown")
        let page = try fresh(OrderVisualStub.Script(details: ["M": .data(detail)]))
        try await page.showDetail("M")
        let image = await page.stable { host, _ in
            host.probes["orderDetail.refresh"] != nil
                && host.orders.details.values.contains { $0.controller?.snapshot.phase == .content }
        }
        XCTAssertEqual(detailRequests(), 1, "前提：进详情只发一次 getOrder")
        let fill = try refreshFill(image)
        XCTAssertFalse(fill.near(disabledFill, tolerance: 12), "前提：内容态【刷新】不置灰（底色 \(fill)）")
        return page
    }

    // MARK: - S2-2【刷新】置灰

    /// ① 42901 共享禁用期：刷新收到 42901 → 进禁用期；期内【刷新】置灰；按钮动作再触发 3 次零新增请求。
    func testRefreshGreyedAndSilentDuring42901() async throws {
        let page = try await openUnknown()
        let controller = try controller(page)
        OrderVisualStub.update { $0.details["M"] = .error(42901) }
        XCTAssertTrue(controller.refresh(), "前提：内容态可刷新")
        await waitUntil("刷新收到 42901 进入禁用期") { controller.gate.active && controller.snapshot.blocked }
        XCTAssertEqual(detailRequests(), 2, "刷新一次 = getOrder 一次（回 42901）")
        let image = await page.stable { host, _ in
            host.probes["orderDetail.refresh"] != nil && controller.snapshot.blocked
        }
        let fill = try refreshFill(image)
        XCTAssertTrue(fill.near(disabledFill, tolerance: 12),
                      "42901 禁用期：【刷新】置灰（底色 \(fill)，禁用令牌 \(disabledFill)）")
        let before = detailRequests()
        for _ in 0..<3 {
            XCTAssertFalse(controller.refresh(), "禁用期内【刷新】的动作不受理")
        }
        try? await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(detailRequests(), before, "禁用期内零请求")
        XCTAssertTrue(controller.gate.active, "前提：以上断言都在禁用期内完成（缺省 5 秒）")
    }

    /// ② 请求在途（假服务挂住回答）：刷新发出一个 getOrder 后【刷新】置灰（在途连点的真触摸次数见 UI 用例）。
    func testRefreshGreyedAndSingleRequestWhileInFlight() async throws {
        let page = try await openUnknown()
        let controller = try controller(page)
        OrderVisualStub.update { $0.details["M"] = .hold }
        XCTAssertTrue(controller.refresh(), "前提：内容态可刷新")
        await waitUntil("刷新后请求在途") { controller.snapshot.refreshing && detailRequests() == 2 }
        let image = await page.stable { host, _ in
            host.probes["orderDetail.refresh"] != nil && controller.snapshot.refreshing
        }
        let fill = try refreshFill(image)
        XCTAssertTrue(fill.near(disabledFill, tolerance: 12),
                      "请求在途：【刷新】置灰（底色 \(fill)，禁用令牌 \(disabledFill)）")
        XCTAssertEqual(detailRequests(), 2, "在途期间没有新增 getOrder")
    }

    // MARK: - S2-1 已结算 + 联系客服

    /// 已结算且下发 CONTACT_CS：卡内【联系客服】（单个，描边）、底栏【去提现】实心主按钮（品牌色）；整页至少一个实心主按钮。
    func testSettledWithContactServiceKeepsFilledWithdraw() async throws {
        var detail = try OrderVisualData.detail("detail_settled")
        detail["reason_action"] = ["CONTACT_CS"]
        let (page, image) = try await openDetail(detail)
        let pixels = ProductVisualPixels(image)
        let primary = ProductVisualPixels.RGB(CouliColor.brandPrimary, dark: false)
        let withdraw = try rect("orderDetail.action.withdraw")
        assertInside(withdraw, try rect("orderDetail.bottomBar"), "【去提现】在底栏")
        let contact = try rect("orderDetail.action.contact_cs")
        assertInside(contact, try rect("orderDetail.statusCard"), "【联系客服】在卡内")
        let withdrawFill = pixels.color(at: CGPoint(x: withdraw.minX + 6, y: withdraw.midY))
        XCTAssertTrue(withdrawFill.near(primary, tolerance: 20),
                      "底栏【去提现】是实心主按钮（底色 \(withdrawFill)，品牌色 \(primary)）")
        let actions = page.probes.records.values
            .filter { $0.id.hasPrefix("orderDetail.action.") && $0.role == "button" }
        let filled = actions.filter {
            pixels.color(at: CGPoint(x: $0.rect.minX + 6, y: $0.rect.midY)).near(primary, tolerance: 20)
        }
        XCTAssertFalse(filled.isEmpty, "整页至少一个实心主按钮（按钮：\(actions.map(\.id).sorted())）")
    }

    // MARK: - S2-4【问问 AI】经 Router 落地

    /// 触发【问问 AI】的 App 出口后 Router 判定放行：最后一次判定 open AgentChat；Tab 根换成 AgentChat、参数 context.order_id = 本单；详情出栈。
    func testAskAILandsOnAgentChatWithOrderContext() async throws {
        let (page, _) = try await openDetail("detail_estimated")
        let router = page.fixture.routing.router
        let destination = try XCTUnwrap(router.path.last, "前提：详情经 Router 推入")
        XCTAssertEqual(destination.route, "OrderDetail")
        // 生产组装给这一页的配置（与页面拿到的同一个工厂）；按钮绑定的就是它的 onAskAI
        let ask = try XCTUnwrap(page.orders.detailPage(destination).onAskAI, "详情配置了【问问 AI】出口")
        ask()
        await waitUntil("【问问 AI】后 Router 切到 AgentChat") { router.tabRoot.route == "AgentChat" }
        XCTAssertEqual(router.lastDecision?.kind, .open, "Router 判定放行（\(String(describing: router.lastDecision))）")
        XCTAssertEqual(router.lastDecision?.route, "AgentChat")
        XCTAssertEqual(router.tabRoot.params, ["context": .object(["order_id": .string("C")])],
                       "进入 AgentChat 的参数带本单 order_id")
        XCTAssertTrue(router.path.isEmpty, "切 Tab 根后详情出栈")
    }
}
