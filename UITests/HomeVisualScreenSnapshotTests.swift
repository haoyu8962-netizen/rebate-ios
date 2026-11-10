import SnapshotTesting
import UIKit
import XCTest

/// a 组真 App 窗口截图；用 tools/testing/home-visual-tests.sh 固定模拟器状态栏为 9:41。
/// 840pt、画板长图由 AppTests 的真实 RootView 宿主负责。
@MainActor
final class HomeVisualScreenSnapshotTests: HomeVisualUITestCase {
    func testAMatrixViewportBaselines() throws {
        try matrix(overlays: false)
    }

    func testBMatrixViewportBaselines() throws {
        try matrix(overlays: true)
    }

    private func matrix(overlays: Bool) throws {
        let cases = try HomeVisualFiles.cases()
        let selection = ProcessInfo.processInfo.environment["COULI_HOME_VISUAL_CASE"]
        // FU-X-CLIP-DEFAULT-ON（test-change）：consent 场景随用途说明弹层删除
        let floating: Set = ["popup", "clipboard_card", "clipboard_no_price", "clipboard_material",
                             "clipboard_30132", "clipboard_network", "invite"]
        for item in cases where item.width <= 390 && floating.contains(item.scene) == overlays &&
            (selection == nil || item.name == selection) {
            try launch(item)
            let state = try diagnostics()
            let sources = ["lkg": "lkg", "bundled": "bundled"]
            if let source = sources[item.scene] {
                XCTAssertEqual(state.source, source)
            }
            if item.scene == "loading" {
                XCTAssertNil(state.source)
            }
            if item.scene == "empty" {
                XCTAssertEqual(state.sectionCounts, ["icons": 10, "activities": 1])
            }
            if item.scene == "feed_failure" {
                assertHit(try reveal("home.feed.retry"))
                try alignForSnapshot("home.footer", bottom: true)
            }
            assertSceneMarker(item.scene)
            // 沿用已录的 matrix-overlays.* 文件名；移出 b 组不另起一套 a 基准。
            snapshot(name: item.name, testName: "matrix(overlays:)")
            keepTree(item.name)
        }
        if let selection {
            XCTAssertTrue(cases.contains { $0.name == selection && $0.width <= 390 })
        }
    }

    func testEveryProductSectionAndFooterLightAndDark() throws {
        for dark in [false, true] {
            var item = HomeVisualCase.standard(level: "member")
            item.dark = dark
            try launch(item)
            for id in ["home.product.scroll.0", "home.product.grid.0", "home.product.feed.0", "home.footer"] {
                try alignForSnapshot(id, bottom: id == "home.footer")
                // #24 test-change（v5，编排定）：深色玻璃标签栏采样它底下的内容，那一条在复比之间有像素差（实现 r3-1：feed.0-dark
                // 4 次 3 绿，差异只在标签栏底下）。比对时按标签栏实际 frame 遮掉这一块；卡片区判据与阈值不动。
                // 标签栏本身由 ShellSystemTabBar* 用例守（显示、文字图标、品牌色、收起展开）。
                snapshot(name: "\(id)-\(dark ? "dark" : "light")", maskTabBar: true)
            }
        }
    }

    func testStressAndNoRebateBaselines() throws {
        for kind in ["scroll", "grid", "feed"] {
            for width in [320, 390] {
                try launch(.standard(scene: "stress_" + kind, width: width, category: "accessibilityExtraLarge"))
                try alignForSnapshot("home.product.\(kind).0")
                snapshot(name: "stress-\(kind)-w\(width)")
            }
            try launch(.standard(scene: "no_rebate_" + kind))
            let info = try revealFullyVisible("home.info.\(kind).0")
            info.tap()
            XCTAssertTrue(element("home.info.content.\(kind).0").waitForExistence(timeout: 5))
            try alignForSnapshot("home.product.\(kind).0")
            XCTAssertTrue(element("home.list").frame.contains(element("home.info.content.\(kind).0").frame),
                          "无返利展开文案必须完整进入截图")
            snapshot(name: "no-rebate-\(kind)-expanded")
        }
    }

    /// #24 test-change（FU-IOS-NATIVE-TABBAR v3）：系统玻璃标签栏展开 / 收起的动画在 XCUI 按钮位置停稳后还会画几帧（实现 r1-2：
    /// 页脚用例 feed.0-dark、scroll.0-light 刚录完即比对不上）。截图前等画面停稳：间隔 0.3 秒连续两张整图逐字节相同才用；
    /// 4 秒内停不下（页面本身有动画，如加载骨架）就用最后一张，与改前一样。比对判据（precision 0.99 / perceptual 0.98）不变。
    private func stableShot(of canvas: XCUIElement) -> UIImage {
        var last = canvas.screenshot()
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let next = canvas.screenshot()
            if next.pngRepresentation == last.pngRepresentation {
                return next.image
            }
            last = next
        }
        return last.image
    }

    /// 把 `area`（屏幕坐标，pt）在整窗截图里涂成纯色块（截图以 canvas 左上为原点，按截图自身的 scale 换算）。
    private func masked(_ image: UIImage, canvas: CGRect, area: CGRect) -> UIImage {
        let local = area.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
            .intersection(CGRect(origin: .zero, size: image.size))
        guard !local.isNull, !local.isEmpty else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            image.draw(at: .zero)
            UIColor.magenta.setFill()
            context.fill(local)
        }
    }

    private func assertSceneMarker(_ scene: String) {
        let markers = [
            "invalid": "home.loadFailed", "popup": "home.popup.close",
            "clipboard_card": "clipboard.cardList", "clipboard_no_price": "clipboard.cardList",
            "clipboard_material": "clipboard.cardList", "clipboard_30132": "clipboard.searchByName",
            "clipboard_network": "clipboard.retry", "invite": "clipboard.invite.confirm",
        ]
        if let id = markers[scene] {
            XCTAssertTrue(element(id).exists)
        }
    }

    private func snapshot(
        name: String,
        maskTabBar: Bool = false,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        let canvas = element("home.visual.canvas")
        XCTAssertTrue(canvas.exists, "必须截整个真实 RootView（包含系统浮层）", file: file, line: line)
        var image = stableShot(of: canvas)
        XCTAssertGreaterThan(image.size.width, 0, file: file, line: line)
        if maskTabBar {
            let bar = ShellTabBar.bar(app)
            XCTAssertTrue(bar.exists, "要遮的标签栏不在", file: file, line: line)
            image = masked(image, canvas: canvas.frame, area: bar.frame)
        }
        // 仅让录缺图的 SnapshotTesting 失败继续；前面的场景、几何和命中前置检查仍立即失败。
        let previous = continueAfterFailure
        continueAfterFailure = ProcessInfo.processInfo.environment["COULI_RECORD_SNAPSHOTS"] == "1"
        defer { continueAfterFailure = previous }
        withSnapshotTesting(record: ProcessInfo.processInfo
            .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: name,
                               file: file, testName: testName, line: line)
            }
    }
}
