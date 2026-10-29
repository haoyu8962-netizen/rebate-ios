@testable import Couli
import DesignSystem
import Foundation
import Generated
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// 判据与宿主自证（当前产品上应全绿）：宿主确实按 visualWallet 画出生产钱包、显示时钟固定、断网缓存造法可用、收益入口开关只在测试包层生效；
/// 图标墨迹判据分得开断网 / 三角 / i、柱状 / 折线；金额墨迹判据拦得住父级裁切。这些不过，其余用例的红就不能算「缺实现」。
@MainActor
final class WalletVisualOracleTests: WalletVisualTestCase {
    /// 宿主：生产执行器拿到 normal 摘要（字段原样）；显示时钟按 Date 校准到 10:32（±60 秒）；钱包页只读摘要。
    func testHostLoadsVisualSummaryWithFixedDisplayClock() async throws {
        let page = try fresh()
        try WalletVisualScript.summary(page.script, "normal")
        try await page.showWallet()
        let image = await page.stable { $0.controller?.state.phase == .content }
        XCTAssertNotNil(image)
        let summary = try XCTUnwrap(page.controller?.state.summary, "执行器没拿到摘要")
        let expected = try XCTUnwrap(WalletJSON.summary(WalletVisualData.summary("normal")))
        XCTAssertEqual(summary, expected, "摘要与 visualWallet.normal 逐字段相同")
        let now = try WalletVisualData.nowMillis()
        let shown = try XCTUnwrap(page.controller).displayNowMillis()
        XCTAssertLessThan(abs(shown - now), 60000, "显示时钟按 Date 校准到 visualWallet.clock")
        XCTAssertGreaterThanOrEqual(summaryRequests, 1)
        XCTAssertEqual(nonSummaryRequests, [], "钱包页只读摘要（不预取 rules、不取 getMe、无写请求）")
        // 主卡狸橙实底确实画出来（不是空白页）
        let hero = pixel(CouliColor.token("rebate.solid.background"), dark: false)
        XCTAssertGreaterThan(count(try XCTUnwrap(image), in: CGRect(x: 0, y: 0, width: 390, height: 844), near: hero,
                                   tolerance: 6), 20000, "页面上要有主卡狸橙底")
    }

    /// 断网缓存造法：09:30 成功一次写缓存 → 断网重开 → 生产读缓存，staleAt = 09:30、断网原因、【提现】置灰；显示时钟回到 10:32。
    func testStaleSetupReadsCacheFrom0930() async throws {
        let page = try fresh()
        try await page.prepareStale(summary: "normal")
        _ = await page.stable { $0.controller?.state.staleAt != nil }
        let state = try XCTUnwrap(page.controller?.state)
        let cachedAt = try WalletVisualData.cachedAtMillis()
        XCTAssertLessThan(abs((state.staleAt ?? 0) - cachedAt), 60000, "缓存时刻 09:30")
        XCTAssertTrue(state.staleNetwork, "断网原因")
        XCTAssertFalse(state.withdrawEnabled, "旧数据【提现】置灰（G-W05 维持）")
        XCTAssertEqual(state.summary, try WalletJSON.summary(WalletVisualData.summary("normal")))
        let now = try WalletVisualData.nowMillis()
        XCTAssertLessThan(abs(try XCTUnwrap(page.controller).displayNowMillis() - now), 60000)
    }

    /// 收益入口：生产 AppWallet 下 since=null 照旧隐藏（G20）；测试包层只改两项开关后，同一个生产执行器才显示，并经 AppWallet 打开路由。
    func testEarningsSwitchOnlyInTestWrapper() async throws {
        let page = try fresh()
        try WalletVisualScript.summary(page.script, "normal")
        try await page.showWallet()
        _ = await page.stable { $0.controller?.state.phase == .content }
        XCTAssertNil(Routes.all["Earnings"]?.sinceIOS, "生产 Earnings since.ios 仍为 null")
        XCTAssertFalse(try XCTUnwrap(page.controller).earningsVisible, "生产环境收益入口隐藏（G20）")
        let other = try fresh()
        try WalletVisualScript.summary(other.script, "normal")
        await other.showWalletWithEarnings()
        _ = await other.stable { $0.controller?.state.phase == .content }
        let controller = try XCTUnwrap(other.controller)
        XCTAssertTrue(controller.earningsVisible)
        XCTAssertEqual(controller.state.summary, try WalletJSON.summary(WalletVisualData.summary("normal")),
                       "包层只改开关，摘要照常")
    }

    /// 图标判据：同尺寸参考图标里，断网 / 三角 / i、柱状 / 折线 / 钟表各自离自己最近。
    func testIconJudgeSeparatesCandidates() async throws {
        let candidates = ["wifi.slash", "exclamationmark.triangle", "info.circle", "chart.bar",
                          "chart.line.uptrend.xyaxis", "clock"]
        let view = HStack(spacing: 20) {
            ForEach(candidates, id: \.self) { name in
                Image(systemName: name).resizable().scaledToFit().frame(width: 20, height: 20)
                    .foregroundColor(CouliColor.statusWarningText).couliProbe("page.\(name)", role: "icon")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CouliColor.backgroundSurface)
        let surface = pixel(CouliColor.backgroundSurface, dark: false)
        let (image, probes) = await WalletVisualRender.standalone(view, size: CGSize(
            width: 300,
            height: 60
        )) { pixels in
            pixels.count(in: CGRect(x: 0, y: 0, width: 300, height: 60)) { !$0.near(surface, tolerance: 40) } > 120
        }
        for name in candidates {
            let frame = try XCTUnwrap(probes["page.\(name)"]?.rect, "参考图标没上报：\(probes.keys.sorted())")
            let found = await nearestIcon(image, in: frame, candidates: candidates,
                                          background: CouliColor.backgroundSurface,
                                          ink: CouliColor.statusWarningText)
            XCTAssertEqual(found, name, "图标判据要分得开 \(name)")
        }
    }

    /// 金额墨迹判据（严格反例）：父级把金额裁掉一半时必须判红；完整金额放行。
    func testAmountInkJudgeRejectsParentClipping() async throws {
        let whole = CouliUnbreakableText("¥9876543.21", size: 34, weight: .bold, relativeTo: .largeTitle,
                                         probeID: "amount", role: "amount")
            .foregroundColor(.white)
        let clipped = whole.frame(maxWidth: 80, alignment: .leading).clipped()
        let ok = await render(AnyView(whole))
        try judge(image: ok.0, probes: ok.1)
        let bad = await render(AnyView(clipped))
        XCTExpectFailure("父级裁切截断金额必须被判红", strict: true) {
            try? judge(image: bad.0, probes: bad.1)
        }
    }

    /// a v3（评审 r1 S1-2）：段内折行判据自证——48 号「¥9876543.21」在 248 宽里折成两行（首行 7 字约 203 宽）：完整放行；
    /// 布局后遮掉右侧 60（首行末字被切掉约半位，v3 首轮用 30 没碰到字——首行没占满 248）、
    /// 中间少一位（画出来的字比测量文字少一个）都必须拦下。
    func testWrappedAmountJudgeRejectsOneMissingDigit() async throws {
        let text = "¥9876543.21"
        let size: CGFloat = 48
        let whole = try await wrapped(drawn: text, clipTrailing: 0)
        let ok = await WalletWrappedAmountJudge.problems(
            image: whole.0,
            rect: whole.1,
            text: text,
            fontSize: size,
            background: solid
        )
        XCTAssertEqual(ok, [], "完整折行金额放行")
        let clipped = try await wrapped(drawn: text, clipTrailing: 60)
        let cut = await WalletWrappedAmountJudge.problems(
            image: clipped.0,
            rect: clipped.1,
            text: text,
            fontSize: size,
            background: solid
        )
        XCTAssertFalse(cut.isEmpty, "行尾字被裁掉必须判红")
        let missing = try await wrapped(drawn: "¥987653.21", clipTrailing: 0)
        let gap = await WalletWrappedAmountJudge.problems(
            image: missing.0,
            rect: missing.1,
            text: text,
            fontSize: size,
            background: solid
        )
        XCTAssertFalse(gap.isEmpty, "中间少一位必须判红")
    }

    private var solid: ProductVisualPixels.RGB {
        pixel(CouliColor.token("rebate.solid.background"), dark: false)
    }

    /// 248 宽、48 号粗体等宽数字段内折行的一段金额；`clipTrailing` > 0 时在布局之后把右侧这么宽的绘制遮掉（测量框不变）。
    private func wrapped(drawn: String, clipTrailing: CGFloat) async throws -> (UIImage, CGRect) {
        let label = Text(verbatim: drawn).font(Font.system(size: 48, weight: .bold).monospacedDigit())
            .foregroundColor(.white).fixedSize(horizontal: false, vertical: true)
            .frame(width: 248, alignment: .leading)
            .couliProbe("wrapped", role: "amount", text: drawn)
            .mask(alignment: .topLeading) {
                GeometryReader { proxy in
                    Rectangle().frame(width: max(0, proxy.size.width - clipTrailing))
                }
            }
        let view = label.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CouliColor.token("rebate.solid.background"))
        let background = solid
        let (image, probes) = await WalletVisualRender.standalone(view, size: CGSize(
            width: 320,
            height: 200
        )) { pixels in
            pixels.count(in: CGRect(x: 0, y: 0, width: 320, height: 200)) { !$0.near(background, tolerance: 40) } > 200
        }
        let rect = try XCTUnwrap(probes["wrapped"]?.rect, "自证用金额没上报测量")
        XCTAssertGreaterThan(rect.height, 48 * 1.5, "确实折成了两行")
        return (image, rect)
    }

    private func render(_ view: AnyView) async -> (UIImage, [String: CouliLayoutProbeRecord]) {
        let root = view.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CouliColor.token("rebate.solid.background"))
        return await WalletVisualRender.standalone(root, size: CGSize(width: 390, height: 100)) { pixels in
            pixels.count(in: CGRect(x: 0, y: 0, width: 390, height: 100)) { $0.red > 240 && $0.green > 240 } > 50
        }
    }

    private func judge(image: UIImage, probes: [String: CouliLayoutProbeRecord]) throws {
        let item = try XCTUnwrap(probes["amount"])
        let pixels = ProductVisualPixels(image)
        let background = pixel(CouliColor.token("rebate.solid.background"), dark: false)
        let tolerance = max(3, item.fontSize * 0.25)
        let band = item.rect.insetBy(dx: -tolerance, dy: 0)
        let left = try XCTUnwrap(inkLeft(pixels, in: band, background: background))
        let right = try XCTUnwrap(inkRight(pixels, in: band, background: background))
        XCTAssertGreaterThanOrEqual(right, item.rect.maxX - tolerance, "字形右端没到测量框右缘")
        XCTAssertGreaterThanOrEqual(right - left, item.naturalWidth - 2 * tolerance, "可见字形宽 < 自然宽")
    }
}
