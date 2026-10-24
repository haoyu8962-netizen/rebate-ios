import DesignSystem
import Foundation
@testable import Home
import HomeCore
import SnapshotTesting
import SwiftUI
import XCTest

/// SDUI 局部基准；整页及原生浮层另由 HomeVisualScreenSnapshotTests 走真实 RootView。
@MainActor
final class HomeVisualSnapshotTests: XCTestCase {
    override func setUp() {
        HomeColorBlockImages.install()
    }

    override func tearDown() {
        HomeColorBlockImages.uninstall()
    }

    func testStateMatrixLightAndDark() async throws {
        for mode in ["network", "loading", "bundled", "lkg", "feed_failure", "invalid", "empty"] {
            for dark in [false, true] {
                let fixture = try HomeVisualFixture(mode: mode)
                await fixture.start()
                let state = fixture.controller.state
                switch mode {
                case "loading": XCTAssertNil(state.source)
                case "bundled": XCTAssertEqual(state.source, .bundled)
                case "lkg": XCTAssertEqual(state.source, .lkg)
                case "invalid": XCTAssertNotNil(state.loadFailed)
                case "empty": XCTAssertEqual(state.sections.map(\.id), ["icons", "activities"])
                default: XCTAssertEqual(state.source, .network)
                }
                if mode == "feed_failure" {
                    let feed = try XCTUnwrap(state.section("feed")?.feed)
                    fixture.controller.loadMore(feed.ticket)
                    await fixture.controller.whenIdle()
                    XCTAssertNotNil(fixture.controller.state.section("feed")?.feed?.failure)
                    XCTAssertEqual(fixture.controller.state.section("feed")?.items.count, 4)
                }
                await snap(HomeSduiScreen(controller: fixture.controller), name: "\(mode)-\(dark ? "dark" : "light")",
                           dark: dark)
                await fixture.close()
            }
        }
    }

    func testGuestAndBasicFixtureAndAdaptations() async throws {
        for name in ["main_v3", "guest_v3"] {
            for dark in [false, true] {
                let fixture = try HomeVisualFixture(page: name)
                await fixture.start()
                XCTAssertEqual(fixture.controller.state.section("scroll")?.items.count, 3)
                XCTAssertEqual(fixture.controller.state.section("grid")?.items.count, 2)
                XCTAssertEqual(fixture.controller.state.section("feed")?.items.count, 4)
                await snap(HomeSduiScreen(controller: fixture.controller), name: "\(name)-\(dark ? "dark" : "light")",
                           dark: dark, expect: ["https://img.example.test/home-v3/0.png"])
                await fixture.close()
            }
        }
        for width: CGFloat in [320, 390, 840] {
            let fixture = try HomeVisualFixture()
            await fixture.start()
            let size: DynamicTypeSize = width == 840 ? .large : .accessibility3
            // accessibility3 的正文约 235%：覆盖至少 200%，并在 UI 层校验真实字体与金额尺寸。
            await snap(HomeSduiScreen(controller: fixture.controller), name: "adapt-w\(Int(width))",
                       width: width, size: size)
            if width == 390 {
                await snap(HomeSduiScreen(controller: fixture.controller), name: "adapt-w390-dark",
                           dark: true, width: width, size: size)
            }
            await fixture.close()
        }
    }

    func testPopupStaticAndShortViewport() async throws {
        for dark in [false, true] {
            let fixture = try HomeVisualFixture(page: "popup")
            await fixture.start()
            let popup = try XCTUnwrap(fixture.controller.state.popup)
            for height: CGFloat in [844, 480, 1189, 1349] {
                await snap(HomePopupView(popup: popup, onClose: {}, onTap: {}),
                           name: "popup-\(Int(height))-\(dark ? "dark" : "light")", dark: dark, height: height,
                           expect: [popup.image])
            }
            await fixture.close()
        }
    }

    private func snap(_ view: some View, name: String, dark: Bool = false, width: CGFloat = 390,
                      height: CGFloat = 3200, size: DynamicTypeSize = .large, expect: [String] = [],
                      file: StaticString = #filePath, testName: String = #function, line: UInt = #line) async {
        let image = await HomeShot.capture(view.background(CouliColor.backgroundCanvas), width: width, height: height,
                                           size: size, expect: expect.map { HomeImageExpectation(url: $0) },
                                           stable: true,
                                           colorScheme: dark ? .dark : .light, file: file, line: line)
        XCTAssertEqual(HomeColorBlockImages.unexpected, [], file: file, line: line)
        withSnapshotTesting(record: ProcessInfo.processInfo
            .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: name,
                               file: file, testName: testName, line: line)
            }
    }
}
