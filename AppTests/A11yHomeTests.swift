import DesignSystem
import Foundation
import Home
import HomeCore
import SwiftUI
import XCTest

/// FU-IOS-A11Y（QA-12b iOS 报告 P1 首页；v4 从 HomeTests 挪来，包测试进程里取不到无障碍树）：生产 `HomeSduiScreen` + 首页视觉夹具（APP-11v 三端同一份
/// goldenPages），打开 SwiftUI 无障碍树。
/// - A11Y-11：各区段「更多 ›」读屏名称带区段标题（「今日精选 更多」一类），同屏不同名。
/// - A11Y-08（首页部分）：整页加载失败的标题是读屏标题并播报（改用 DS ErrorState 即满足：立即播报「标题，说明」、播完焦点到【重试】）；
///   信息流翻页失败行出现时立即播报失败文案，播报结束后焦点移到【重试】（`couliFocusProbe("home.feed.retry")`）。
@MainActor
final class A11yHomeTests: XCTestCase {
    private var canvas: A11yCanvas?
    private var fixture: A11yHomeFixture?
    private lazy var probes = A11yProbes()

    override func setUp() async throws {
        try A11yTree.enable(self)
    }

    override func tearDown() async throws {
        canvas?.close()
        canvas = nil
        await fixture?.close()
        fixture = nil
    }

    private func mount(_ mode: String = "network", page: String = "main_v3") async throws -> (A11yHomeFixture,
                                                                                              A11yCanvas) {
        let fixture = try A11yHomeFixture(page: page, mode: mode)
        self.fixture = fixture
        await fixture.start()
        let canvas = A11yCanvas(AnyView(HomeSduiScreen(controller: fixture.controller)), height: 1600,
                                probe: probes.probe)
        self.canvas = canvas
        await canvas.pump(0.8)
        return (fixture, canvas)
    }

    // MARK: - A11Y-11

    func testMoreButtonsNameTheirSection() async throws {
        // main_v3 只有一个区段配了「更多」；用本单专用页（两个区段都有「更多」，见 A11yHomeFixture.page，v6）
        let (_, canvas) = try await mount(page: "main_v3_two_more")
        let expected = ["scroll": "今日精选", "grid": "超市百货"]
        let ready = await canvas
            .wait { nodes in expected.keys.allSatisfy { id in nodes.contains { $0.id == "home.more.\(id)" } } }
        XCTAssertTrue(ready, "前提：两个带「更多」的区段")
        var labels: [String] = []
        for (id, title) in expected.sorted(by: { $0.key < $1.key }) {
            let node = try XCTUnwrap(A11yTree.node("home.more.\(id)", in: canvas.root))
            XCTAssertTrue(node.isButton, "home.more.\(id) 是按钮")
            XCTAssertTrue(node.label.contains(title), "「更多」要带区段标题「\(title)」（A11Y-11）：\(node.label)")
            labels.append(node.label)
        }
        XCTAssertEqual(Set(labels).count, labels.count, "同屏「更多」名称不能相同：\(labels)")
    }

    // MARK: - A11Y-08

    func testWholePageFailureTitleIsHeaderAndAnnounced() async throws {
        A11yAudit.installTap(self, voiceOver: true)
        let (fixture, canvas) = try await mount("invalid")
        XCTAssertNotNil(fixture.controller.state.loadFailed, "前提：整页失败")
        let title = fixture.controller.text("home.load_failed")
        let ready = await canvas.wait { $0.contains { $0.isElement && $0.label.contains(title) } }
        XCTAssertTrue(ready, "整页失败要有标题「\(title)」")
        let node = try XCTUnwrap(A11yTree.elements(canvas.root).first { $0.label.contains(title) })
        XCTAssertTrue(node.isHeader, "整页失败的标题要是读屏标题（1.3.1）：\(node)")
        let post = await A11yAudit.waitAnnouncement(containing: title)
        XCTAssertNotNil(post, "整页失败要播报（A11Y-08）；实际：\(A11yPostTap.posts)")
        XCTAssertEqual(post?.queued, false, "加载失败立即读")
    }

    func testFeedPageFailureIsAnnouncedThenFocusesRetry() async throws {
        A11yAudit.installTap(self, voiceOver: true)
        let (fixture, canvas) = try await mount("feed_failure")
        if let feed = fixture.controller.state.section("feed")?.feed, feed.failure == nil {
            // 视口里没自动翻页时手动翻一页（与 HomeVisualSnapshotTests feed_failure 同一做法）
            fixture.controller.loadMore(feed.ticket)
            await fixture.controller.whenIdle()
        }
        let failure = try XCTUnwrap(fixture.controller.state.section("feed")?.feed?.failure, "前提：翻页失败")
        let shown = await canvas.wait(8) { $0.contains { $0.id == "home.feed.retry" } }
        XCTAssertTrue(shown, "前提：失败行与【重试】出现")
        let post = await A11yAudit.waitAnnouncement(containing: failure.message)
        XCTAssertNotNil(post, "信息流翻页失败要播报「\(failure.message)」（A11Y-08）；实际：\(A11yPostTap.posts)")
        XCTAssertEqual(post?.queued, false, "加载失败立即读（同搜索页翻页失败）")
        A11yAudit.finishAnnouncement(post?.text ?? failure.message)
        let deadline = Date().addingTimeInterval(9.5)
        while !probes.focused.contains("home.feed.retry"), Date() < deadline {
            await canvas.pump(0.1)
        }
        XCTAssertTrue(probes.focused.contains("home.feed.retry"), "播报结束后焦点要移到【重试】；实际 \(probes.focused)")
    }
}
