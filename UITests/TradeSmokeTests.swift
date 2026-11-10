import XCTest

/// 冒烟（APP-06b）：Debug 包 + 本机假服务（`-CouliFakeLoginServer`，购买场景见 DebugFakeTrade；`-CouliFakeTradeLoggedIn` 冷启动即已登录，
/// `-CouliFakeTradeNoExternal` 不真的拉起外部 App / 浏览器）。详情改价确认 → 取消；列表卡购买 8 秒超时 → 同键重试；「我的」→ 授权管理。
/// 设置环境变量 TEST_RUNNER_COULI_SHOT_DIR 时另跑设计稿比对的截图用例（NATIVE/APP-06b/shots/ios/）。全部假数据。
@MainActor
final class TradeSmokeTests: XCTestCase, TradeUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        resetFakeSession()
    }

    // MARK: - 冒烟（verify.sh 每次都跑）

    func testSmokePriceChangedCancelAndAuthManageEntry() {
        let app = launch(["-CouliFakeTipsRead"])
        product(app, "tb:t-price")
        element(app, "product.buy").tap()
        XCTAssertTrue(element(app, "purchase.priceChanged").waitForExistence(timeout: 10), "改价没有先确认")
        element(app, "purchase.dialog.cancel").tap()
        XCTAssertTrue(app.staticTexts["已取消购买，价格已更新为最新"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "product.buy").isEnabled, "新券后价已知：照常可买（共性第 34 条）")
        app.terminate()

        let me = launch()
        ShellTabBar.tap(me, "我的")
        element(me, "me.authManage").tap()
        XCTAssertTrue(element(me, "authManage.status.taobao").waitForExistence(timeout: 10), "授权管理没有打开")
        XCTAssertTrue(element(me, "authManage.authorize.pdd").exists, "未授权给【去授权】")
    }
}
