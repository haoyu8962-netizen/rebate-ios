import XCTest

/// APP-09 iOS 第 3 轮评审 R3-02 的界面用例（Debug 包 + 本机假服务 DebugFakeWallet，verify 每次都跑）：提现记录空态也能下拉刷新
/// （G30、flow-map §16，共性第 82 条）。假服务 `records=empty_once`：第一次列表读取为空，之后每次多一张以读取序号命名的单 W-call-<序号>。
@MainActor
final class WalletReviewR3UITests: XCTestCase, WalletUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        resetFakeSession()
    }

    /// R3-02：真实空态页面（不足一屏）下拉 → 只发一次列表请求（第 2 次读取）→ 成功后进入列表；之后不再自动多读。
    func testEmptyRecordsPullToRefreshLoadsListOnce() {
        let app = openWallet("records=empty_once")
        tapButton(app, "提现记录")
        let empty = element(app, "records.empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 15), "没有进入空态")
        pause(1.5)
        XCTAssertTrue(empty.exists, "空态期间不自动重读")
        XCTAssertFalse(element(app, "records.list").exists)

        let start = empty.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        let end = start.withOffset(CGVector(dx: 0, dy: 420))
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertTrue(element(app, "records.list").waitForExistence(timeout: 15), "空态下拉后没有进入列表")
        XCTAssertTrue(element(app, "record.W-call-2").waitForExistence(timeout: 10), "列表应来自下拉发出的第 2 次读取")
        pause(1.5)
        XCTAssertFalse(element(app, "record.W-call-3").exists, "一次下拉只读一次")
        XCTAssertTrue(element(app, "record.W-call-2").exists)
    }
}
