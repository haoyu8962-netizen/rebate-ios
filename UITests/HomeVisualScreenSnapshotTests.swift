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
                snapshot(name: "\(id)-\(dark ? "dark" : "light")")
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
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        let canvas = element("home.visual.canvas")
        XCTAssertTrue(canvas.exists, "必须截整个真实 RootView（包含系统浮层）", file: file, line: line)
        let image = canvas.screenshot().image
        XCTAssertGreaterThan(image.size.width, 0, file: file, line: line)
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
