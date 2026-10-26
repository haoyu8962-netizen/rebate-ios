@testable import Couli
import DesignSystem
import Foundation
import OrderCore
import SwiftUI
import UIKit
import XCTest

/// 判据自证（当前产品上应全绿）：证明宿主与像素判据本身可用，红灯不是测试设施问题。
/// 1) 宿主：真实 App 组装 + 假服务 + 测试位图确实把 list_self 画出来（只发一次 scope=self 的列表请求、A 的图已上屏）；
/// 2) 墨迹判据：【复制】紧随单号放行，盒子撑满推到行尾（Android a M10）判红；
/// 3) 图标判据：断网图标与 i / 警告三角、圆圈对勾与裸对勾都分得开。
@MainActor
final class OrderVisualOracleTests: OrderVisualTestCase {
    func testHostRendersRealListFromVisualFixture() async throws {
        let page = try fresh(listScript())
        await page.showList(.init(height: 1740))
        let image = await page.stable { _, image in
            OrderVisualImages.served.contains { $0.hasSuffix("/order-v/A.png") }
                && ProductVisualPixels(image).count(in: CGRect(origin: .zero, size: image.size), step: 3) {
                    $0.isStripe
                } > 300
        }
        let shot = try XCTUnwrap(image)
        XCTContext.runActivity(named: "宿主画面") { $0.add(XCTAttachment(image: shot)) }
        XCTAssertEqual(OrderVisualStub.orderRequests.first?.line, "GET /v1/orders?scope=self", "首屏只发自购列表请求")
        XCTAssertEqual(page.orders.listConfig?.controller.snapshot.items.map(\.orderId), ["A", "B", "M", "C", "J"],
                       "生产执行器拿到的就是 visualOrders.list_self")
        XCTAssertEqual(page.orders.now(), try OrderVisualData.nowMillis(), "固定时钟 10:30")
    }

    func testCopyInkJudgeAcceptsFollowingAndRejectsPushedToEnd() async throws {
        let number = "3741234567890123456"
        let view = VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 8) {
                Text(verbatim: number).font(.system(size: 12)).couliProbe("good.number", role: "text")
                Text(verbatim: "复制").font(.system(size: 12)).couliProbe("good.copy", role: "text")
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text(verbatim: number).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    .couliProbe("bad.number", role: "text")
                Text(verbatim: "复制").font(.system(size: 12)).couliProbe("bad.copy", role: "text")
            }
        }
        .foregroundColor(CouliColor.textSecondary)
        .padding(16)
        .frame(width: 320, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CouliColor.backgroundSurface)
        let (image, probes) = await ProductVisualRender.standalone(view, size: CGSize(width: 320, height: 120))
        let pixels = ProductVisualPixels(image)
        let surface = ProductVisualPixels.RGB(CouliColor.backgroundSurface, dark: false)
        func gap(_ prefix: String) throws -> CGFloat {
            let numberRect = try XCTUnwrap(probes["\(prefix).number"]?.rect)
            let copy = try XCTUnwrap(probes["\(prefix).copy"]?.rect)
            let band = CGRect(x: numberRect.minX, y: numberRect.minY,
                              width: copy.minX - numberRect.minX - 0.5, height: numberRect.height)
            let ink = try XCTUnwrap(inkRight(pixels, in: band, background: surface))
            return copy.minX - ink
        }
        XCTAssertLessThanOrEqual(try gap("good"), 16, "紧随写法放行")
        XCTAssertGreaterThan(try gap("bad"), 16, "盒子撑满、复制推到行尾判红（只看盒子右缘会漏）")
    }

    func testIconJudgeSeparatesWifiOffInfoAlertAndCheckCircle() async throws {
        for (drawn, candidates) in [
            ("wifi.slash", ["wifi.slash", "exclamationmark.triangle", "info.circle"]),
            ("info.circle", ["wifi.slash", "exclamationmark.triangle", "info.circle"]),
            ("checkmark.circle", ["checkmark.circle", "checkmark"]),
            ("checkmark", ["checkmark.circle", "checkmark"]),
            ("clock", ["clock", "info.circle", "exclamationmark.triangle", "checkmark.circle"]),
        ] {
            let view = Image(systemName: drawn)
                .font(.system(size: 16, weight: .regular))
                .frame(width: 20, height: 20)
                .foregroundColor(CouliColor.textSecondary)
                .couliProbe("icon", role: "icon")
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(CouliColor.backgroundMuted)
            let (image, probes) = await ProductVisualRender.standalone(view, size: CGSize(width: 80, height: 80))
            let rect = try XCTUnwrap(probes["icon"]?.rect)
            let nearest = await nearestIcon(image, in: rect, candidates: candidates,
                                            background: CouliColor.backgroundMuted, dark: false)
            XCTAssertEqual(nearest, drawn, "图标判据认出 \(drawn)")
        }
    }

    /// 断网缓存的造法本身可用：先 09:30 在线取一次（生产写缓存），再断网重开——生产执行器进 stale、缓存时刻 09:30。
    func testPrepareStaleReallyReachesStaleCache() async throws {
        let page = try fresh(listScript())
        try await page.prepareStale(.init(height: 1794))
        _ = await page.stable { host, _ in host.orders.listConfig?.controller.snapshot.phase == .stale }
        let snapshot = try XCTUnwrap(page.orders.listConfig?.controller.snapshot)
        XCTAssertEqual(snapshot.phase, .stale, "列表进断网缓存态")
        XCTAssertEqual(snapshot.staleAt, try OrderVisualData.staleAtMillis(), "缓存时刻 09:30")
        XCTAssertEqual(snapshot.items.map(\.orderId), ["A", "B", "M", "C", "J"])
    }

    /// v2（T4）：金额墨迹判据放行完整金额、拦下测量框外层的父级裁切（M3 写法：测量挂在内层、外层限宽 60 并裁切）。
    func testAmountInkJudgeRejectsParentClipping() async throws {
        let text = OrderVisualData.money(9_999_999)
        // 自然宽按同一字体量（与生产 OrderListAmounts.naturalWidth 同口径）
        let natural = (text as NSString)
            .size(withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold)]).width
        let view = VStack(alignment: .leading, spacing: 24) {
            CouliUnbreakableText(
                text,
                size: 17,
                weight: .couliSemibold,
                relativeTo: .body,
                probeID: "good",
                role: "amount",
                naturalWidth: natural
            )
            CouliUnbreakableText(
                text,
                size: 17,
                weight: .couliSemibold,
                relativeTo: .body,
                probeID: "bad",
                role: "amount",
                naturalWidth: natural
            )
            .frame(maxWidth: 60, alignment: .leading).clipped()
        }
        .foregroundColor(CouliColor.textPrimary)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CouliColor.backgroundSurface)
        let (image, probes) = await ProductVisualRender.standalone(view, size: CGSize(width: 320, height: 140))
        let host = try fresh(OrderVisualStub.Script())
        // 把参考视图的测量交给底座的测量接收方，判据走与正式用例同一条路径
        for record in probes.records.values {
            host.probes.probe.report(record)
        }
        let surface = ProductVisualPixels.RGB(CouliColor.backgroundSurface, dark: false)
        try assertAmountInkFillsFrame("good", image: image, background: surface, "完整金额")
        XCTExpectFailure("父级裁切的金额必须被判红") {
            try? assertAmountInkFillsFrame("bad", image: image, background: surface, "裁切金额")
        }
    }
}
