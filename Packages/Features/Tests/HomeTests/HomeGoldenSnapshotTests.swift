import Combine
import CouliNetwork
import DesignSystem
import Foundation
@testable import Home
import HomeCore
import SnapshotTesting
import SwiftUI
import XCTest

/// golden 样例与截图（F-HOME-02「每种卡有 golden 样例和截图」，AC-HOME-02，G29；cross-platform-lessons 第 15 条）：直接用不可改动的
/// specs/home-sdui-vectors.json 的 goldenPages 逐页驱动（fixture 名 = 截图名 golden-<名字>），经生产 HomeController 与同一个渲染器
/// `HomeSduiScreen`（本机替身给商品项与图片结果），宽 390（与设计稿同宽）。另截 Main 组合页的字号、窄屏、大屏、公告关闭前后与弹窗短视口。
/// 首页是滚动视图，按固定画布截（宽同设计稿，高 1600；弹窗另给视口高）。基准图存
/// `__Snapshots__/HomeGoldenSnapshotTests/`（入库）：实现方用录制模式（`TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1`）写出缺的基准，编排者看图
/// 确认后入库；普通运行与 CI 是比对模式，缺基准持续失败（第 2 版，评审 T-16）。
/// 第 4 版（截图比对后）：
/// - 图片换本机色块（HomeColorBlockImages，T3），截图前等图片结算，经真实窗口按图层渲染（HomeShot）。
/// - 「不是空白画布」收紧（T2）：除颜色数外，最上与最下内容之间不得有超过 48pt 的整段底色（只画出部分区段时中间留白）。
/// - 每个区段都画出来（P1）：同一页逐个加区段渲染，每多一个可见区段，画面内容的下沿必须往下长；覆盖包内默认页、Main 组合页
///   与多区段 golden 页。
/// - 置灰（T1）：本包测试没有宿主 App，图层渲染拍不到 SwiftUI 滤镜，Grayscale 不再做像素基准；改在 App 宿主的
///   HomeAppRenderTests 用 drawHierarchy 渲染真实首页路由，断言置灰后像素无彩色。
/// 第 6 版：截图前逐张等本屏预期图片各自的色块（不是任一色块出现就截，T-06），轮播固定第一帧；色块按目标区段所占的竖向范围统计
/// （T-04），共用同一图片地址的别的区段不能代过。
/// 定稿（编排 2026-10-18 19:3x 裁定①）：golden 截图比对与录制都用稳定等待（连续两帧一致或 2 秒超时再截），比对容差 ≤1% 像素
/// 差异视为一致；分块呈现、90% 到位这类时序差异不作红绿依据（F-IOS 跟进）。
@MainActor
final class HomeGoldenSnapshotTests: XCTestCase {
    private var defaultsSuites: [String] = []

    override func setUp() async throws {
        HomeColorBlockImages.install()
    }

    override func tearDown() async throws {
        HomeColorBlockImages.uninstall()
        for suite in defaultsSuites {
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    // MARK: - 每个 golden 页

    func testEveryGoldenPageRendersThroughTheSameRenderer() async throws {
        let pages = try SnapshotKit.goldenPages()
        XCTAssertEqual(pages.count, 15)
        for name in pages.keys.sorted() {
            let page = try XCTUnwrap(pages[name] as? [String: Any])
            let controller = await render(page)
            XCTAssertNotNil(controller.state.source, "\(name) 没有渲染")
            if name == "popup" {
                let popup = try XCTUnwrap(controller.state.popup, "golden popup 要弹")
                await snap(
                    HomePopupView(popup: popup, onClose: {}, onTap: {}), height: 844, expect: [popup.image],
                    named: "golden-popup"
                )
            } else {
                // empty_source / with_condition 的卡全部为空（按规则整卡隐藏），画布本来就是空的
                let blank = ["empty_source", "with_condition"].contains(name)
                await snap(
                    HomeSduiScreen(controller: controller), expect: Self.leadImage(controller), named: "golden-\(name)",
                    expectContent: !blank
                )
            }
        }
    }

    // MARK: - Main 组合页（设计稿 Main）

    func testMainAtDesignFontScalesAndWidths() async throws {
        let controller = await render(try SnapshotKit.main())
        await snap(HomeSduiScreen(controller: controller), expect: Self.mainLead, named: "Main")
        await snap(HomeSduiScreen(controller: controller), size: .xxxLarge, expect: Self.mainLead, named: "Main130")
        await snap(
            HomeSduiScreen(controller: controller),
            size: .accessibility2,
            expect: Self.mainLead,
            named: "Main200"
        )
        await snap(HomeSduiScreen(controller: controller), width: 320, expect: Self.mainLead, named: "Main320")
        await snap(
            HomeSduiScreen(controller: controller),
            size: .accessibility2,
            width: 320,
            expect: Self.mainLead,
            named: "Main320-200"
        )
        await snap(HomeSduiScreen(controller: controller), width: 840, expect: Self.mainLead, named: "MainLarge")
    }

    func testNoticeBeforeAndAfterClose() async throws {
        let controller = await render(try SnapshotKit.main())
        await snap(HomeSduiScreen(controller: controller), expect: Self.mainLead, named: "NoticeBar-before")
        controller.closeNotice(try XCTUnwrap(controller.state.section("notice_main")?.items.first?.close))
        await snap(HomeSduiScreen(controller: controller), expect: Self.mainLead, named: "NoticeBar-after")
    }

    // MARK: - 每个区段都画出来（P1）

    /// 包内默认页（金刚区 + 双入口，HomeBundled）：两张卡都要画出来。
    func testBundledDefaultPageDrawsEverySection() async throws {
        let data = try XCTUnwrap(HomeBundled.data())
        let page = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let drawn = try await assertEverySectionDrawn(page, name: "包内默认页")
        XCTAssertGreaterThanOrEqual(drawn, 2, "前提：包内默认页至少两张区段卡")
    }

    /// Main 组合页（公告、轮播、金刚区、双入口、今日精选、超市百货、商品流）：每张卡都要画出来。
    func testMainPageDrawsEverySection() async throws {
        let drawn = try await assertEverySectionDrawn(try SnapshotKit.main(), name: "Main", height: 3200)
        XCTAssertGreaterThanOrEqual(drawn, 7, "前提：Main 每个区段都可见")
    }

    /// 多区段 golden 页（超长文案、解码隔离、版本门槛）：保留下来的每张卡都要画出来。
    func testMultiSectionGoldenPagesDrawEverySection() async throws {
        let pages = try SnapshotKit.goldenPages()
        for name in ["long_text", "mixed_bad", "min_app_version", "default_home"] {
            let page = try XCTUnwrap(pages[name] as? [String: Any])
            let drawn = try await assertEverySectionDrawn(page, name: "golden-\(name)")
            XCTAssertGreaterThanOrEqual(drawn, 2, "前提：golden-\(name) 至少两张可见区段卡")
        }
    }

    /// 图片走本机色块（T3 / 第 5 版 T-04 / 第 6 版 T-04、T-06）：URLSession.shared 的全部请求都被记录，除图片主机外没有任何请求；
    /// Main 组合页逐个加区段渲染，**每个带图片的区段在它自己占的竖向范围里**（加入前内容下沿 ~ 加入后内容下沿）画出各自预期图片的色块
    /// ——横滑卡、网格卡、信息流共用 p/0～p/3，别的区段不能替目标区段过关；每张图各自等到画出来（先后不限、8 秒上限），不是任一色块
    /// 出现就截图。
    func testImagesComeFromLocalColorBlocks() async throws {
        let page = try SnapshotKit.main()
        let sections = try XCTUnwrap(page["sections"] as? [[String: Any]])
        let product = { (index: Int) in "https://img.example.com/p/\(index).png" }
        // 每个带图区段首屏必须画出的图片：轮播第一帧；今日精选（横滑）前两件；超市百货（两列）全部四件；信息流前两件
        let targets: [String: [String]] = [
            "banner": ["https://img.example.com/banner-a.png"], "scroll": [product(0), product(1)],
            "grid": (0..<4).map(product), "feed": [product(0), product(1)],
        ]
        let height: CGFloat = 3200
        var bottom: CGFloat = 0
        var checked: [String] = []
        for count in 1...sections.count {
            var partial = page
            partial["sections"] = Array(sections.prefix(count))
            let controller = await render(partial)
            let id = sections[count - 1]["id"] as? String ?? ""
            let urls = targets[id] ?? []
            let image = await HomeShot.capture(
                HomeSduiScreen(controller: controller).background(CouliColor.backgroundCanvas), height: height,
                expect: urls.map { HomeImageExpectation(url: $0, minY: bottom) }
            )
            let edge = HomePixelScan(image, step: 2).contentBottom ?? 0
            if !urls.isEmpty {
                checked.append(id)
                let band = urls.map { HomeImageExpectation(url: $0, minY: bottom, maxY: edge) }
                for (item, pixels) in zip(band, HomePixelScan.counts(band, in: image)) {
                    XCTAssertTrue(HomeColorBlockImages.served.contains(item.url), "\(id)：图片 \(item.url) 没有请求（色块没有注入）")
                    XCTAssertGreaterThanOrEqual(
                        pixels, HomeShot.minimumPixels,
                        "\(id) 区段（\(Int(bottom))~\(Int(edge))pt）里图片 \(item.url) 的色块只有 \(pixels) 像素：这一区段的图片没有显示" +
                            "（仍是占位？别的区段的同一图片不算）"
                    )
                }
            }
            bottom = max(bottom, edge)
        }
        XCTAssertEqual(checked, ["banner", "scroll", "grid", "feed"], "前提：Main 的四个带图区段都核对到了")
        XCTAssertEqual(HomeColorBlockImages.unexpected, [], "截图时有图片主机以外的请求")
    }

    /// 短视口下关闭按钮仍可见可点（命中区不小于 44pt；读屏顺序 弹窗名 → 关闭 → 图片 交开发验收）。
    func testPopupOnShortViewportKeepsCloseVisible() async throws {
        let controller = await render(try SnapshotKit.main(withPopup: true))
        let popup = try XCTUnwrap(controller.state.popup)
        await snap(
            HomePopupView(popup: popup, onClose: {}, onTap: {}),
            height: 480,
            expect: [popup.image],
            named: "MainPopup-short"
        )
    }

    /// banner 某帧图片加载失败：该帧显示规定的占位（color.background.placeholder），不可点（评审 T-13）。
    func testBannerImageFailureShowsPlaceholder() async throws {
        let controller = await render(try XCTUnwrap(try SnapshotKit.goldenPages()["banner"] as? [String: Any]))
        let first = try XCTUnwrap(controller.state.section("banner")?.items.first?.imageTicket)
        controller.imageLoaded(first, ok: false)
        XCTAssertEqual(controller.state.section("banner")?.items.first?.imageFailed, true)
        // 只有一张轮播卡，不查「中间整段空白」：失败帧现在按禁用态压淡、与底色接近（截图比对 P6，看图验收）
        await snap(
            HomeSduiScreen(controller: controller), height: 600, expect: [], named: "banner-image-failed",
            contiguous: false
        )
    }

    /// 弹窗带推广标识（评审 T-06）：角标原样显示在弹窗上。
    func testPopupShowsAdLabel() async throws {
        var popup = try XCTUnwrap(
            ((try SnapshotKit.goldenPages()["popup"] as? [String: Any])?["sections"] as? [[String: Any]])?.first
        )
        popup["ad_label"] = "推广"
        let controller = await render(["page_key": "home", "version": 50, "sections": [popup]])
        let shown = try XCTUnwrap(controller.state.popup)
        XCTAssertEqual(shown.adLabel, "推广")
        await snap(
            HomePopupView(popup: shown, onClose: {}, onTap: {}),
            height: 844,
            expect: [shown.image],
            named: "popup-adlabel"
        )
    }

    // MARK: - 工具

    private func render(_ page: [String: Any]) async -> HomeController {
        let suite = "home-snapshot-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let deps = SnapshotKit.deps(page: page, defaults: UserDefaults(suiteName: suite)!)
        let controller = HomeController(
            identity: HomeIdentity(env: "test", level: .guest, userId: nil, loginEpoch: nil), deps: deps
        )
        controller.start()
        await controller.whenIdle()
        XCTAssertEqual(controller.state.source, .network, "前提：页面经渲染器显示（不是空白画布）")
        return controller
    }

    /// 录制与比对分开（评审 T-16）：缺省是比对模式，缺基准一律失败、不写图；只有显式设
    /// `COULI_RECORD_SNAPSHOTS=1`（xcodebuild 用 `TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1`）才录制缺的基准。
    private static var recording: Bool {
        ProcessInfo.processInfo.environment["COULI_RECORD_SNAPSHOTS"] == "1"
    }

    private func snap(
        _ view: some View, size: DynamicTypeSize = .large, width: CGFloat = 390, height: CGFloat = 1600,
        expect: [String],
        named name: String, expectContent: Bool = true, contiguous: Bool = true, file: StaticString = #filePath,
        testName: String = #function, line: UInt = #line
    ) async {
        // 稳定等待（裁定①）：比对与录制同一做法，连续两帧一致或 2 秒超时再截
        let image = await HomeShot.capture(
            view.background(CouliColor.backgroundCanvas), width: width, height: height, size: size,
            expect: expect.map { HomeImageExpectation(url: $0) }, stable: true, file: file, line: line
        )
        if expectContent {
            // 渲染器确实画了内容（不只是底色），而且内容是连着的：只画出部分区段时中间会留大片底色（T2 / P1）
            let scan = HomePixelScan(image, step: 2)
            XCTAssertGreaterThanOrEqual(scan.distinctColors, 3, "\(name)：渲染出来是空白画布", file: file, line: line)
            XCTAssertLessThanOrEqual(
                contiguous ? scan.longestInnerBlank : 0, Self.maxInnerBlank,
                "\(name)：内容中间有 \(Int(scan.longestInnerBlank))pt 的整段空白（有区段卡没画出来）", file: file, line: line
            )
        }
        // 容差（裁定①）：≤1% 像素不同视为一致（precision 0.99；单像素色差容忍 perceptualPrecision 0.98 不变）
        withSnapshotTesting(record: Self.recording ? .missing : .never) {
            assertSnapshot(
                of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: name, file: file,
                testName: testName, line: line
            )
        }
    }

    /// 一页首屏一定显示的图片（第 6 版 T-06）：最上面一个带图片的区段的第一张（https 图片；内置图标不算）。没有图片的页为空，
    /// 允许零请求。画布内其余图片不再逐块等（裁定①：稳定等待 + 容差比对，见 snap）。
    private static func leadImage(_ controller: HomeController) -> [String] {
        for section in controller.state.sections {
            if let image = section.items.first(where: { $0.image?.hasPrefix("https://") == true })?.image {
                return [image]
            }
        }
        return controller.state.popup.map { [$0.image] } ?? []
    }

    /// Main 组合页任何字号、宽度下首屏都有的图片：轮播第一帧与今日精选第一件。
    private static let mainLead = ["https://img.example.com/banner-a.png", "https://img.example.com/p/0.png"]

    /// 相邻两张卡之间的正常间距远小于此；超过就是有卡没画出来。
    private static let maxInnerBlank: CGFloat = 48

    /// 逐个加区段渲染同一页：可见行变多时，画面内容的下沿必须至少往下长 16pt（新加的卡画出来了）。返回可见区段数。
    @discardableResult
    private func assertEverySectionDrawn(
        _ page: [String: Any], name: String, height: CGFloat = 2400, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> Int {
        let sections = try XCTUnwrap(page["sections"] as? [[String: Any]], file: file, line: line)
        var rows = 0
        var bottom: CGFloat = 0
        var visible = 0
        for count in 1...sections.count {
            var partial = page
            partial["sections"] = Array(sections.prefix(count))
            let controller = await render(partial)
            // 新加区段带图片时，等它自己的第一张图在加入前内容下沿以下画出来（T-04 / T-06：按区域、逐张等）
            // 同 id 的重复区段（mixed_bad 的第二个 good_a）按规则丢弃、不新增行，不另等图片
            let added = sections[count - 1]["id"] as? String
            let repeated = sections.prefix(count - 1).contains { $0["id"] as? String == added }
            let grows = controller.state.rowKeys.count > rows && !repeated
            let lead = controller.state.sections.first { grows && $0.id == added }?.items
                .first { $0.image?.hasPrefix("https://") == true }?.image
            let image = await HomeShot.capture(
                HomeSduiScreen(controller: controller).background(CouliColor.backgroundCanvas), height: height,
                expect: lead.map { [HomeImageExpectation(url: $0, minY: bottom)] } ?? [], file: file, line: line
            )
            let scan = HomePixelScan(image, step: 2)
            let id = sections[count - 1]["id"] as? String ?? "#\(count)"
            let now = controller.state.rowKeys.count
            let edge = scan.contentBottom ?? 0
            XCTAssertLessThan(edge, height - 8, "\(name)：画布不够高，换更高的画布", file: file, line: line)
            if now > rows {
                visible += 1
                XCTAssertGreaterThanOrEqual(
                    edge, bottom + 16,
                    "\(name)：加入第 \(count) 个区段（\(id)）后画面没有多出内容，这张卡没画出来（内容下沿 \(Int(edge))pt，" +
                        "加入前 \(Int(bottom))pt）",
                    file: file, line: line
                )
                XCTAssertLessThanOrEqual(
                    scan.longestInnerBlank, Self.maxInnerBlank,
                    "\(name)：前 \(count) 个区段中间有 \(Int(scan.longestInnerBlank))pt 整段空白", file: file, line: line
                )
            }
            rows = max(rows, now)
            bottom = max(bottom, edge)
        }
        return visible
    }
}
