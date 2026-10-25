import SnapshotTesting
import XCTest

/// APP-06v-b 购买浮层逐张画板基准（brief §1.1 B 表；ProductJumpHarmonyH5 只鸿蒙；ProductAuthConfirming / JumpUnsupported 按 G-D12 不做）。
/// 真实 App 视口截图（含系统状态栏，须用 tools/testing/product-visual-tests.sh 先把时间固定 9:41）；默认只比对，
/// `TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1` 只录缺图。加载层转圈在动画中途，容差沿用 0.99 / 0.98。
@MainActor
final class PurchaseVisualScreenSnapshotTests: XCTestCase, ProductVisualUITest {
    struct Board {
        let name: String
        let link: String
        var cardID = "tb_coupon_range"
        var extra: [String] = []
        var dark = false
        /// 点购买后等它出现再截（nil = 只等固定时间）。
        var waitFor: String?
        var wait: TimeInterval = 1.2
        /// 截图前再点的按钮（如取消改价后截取消后卡面与轻提示）。
        var then: String?
        /// b v2（T2）：这张图上主 / 次按钮的文字。截图容差拦不住主次对调（橙白互换），对同一张截图另断言：主在上、主按钮取样
        /// 是品牌色、次按钮不是。
        var buttons: (primary: String, secondary: String)?
        /// b v2（评审 r1 S2-3）：截图只守版式和颜色、不守文字；这张图上必须能读到的文字（按 label 包含判断）。
        var texts: [String] = []
    }

    private static let retryPair = (primary: "重试", secondary: "仍去购买（无返利）")

    private static let blocked = (primary: "联系客服", secondary: "仍去购买（无返利）")

    override func setUp() async throws {
        continueAfterFailure = true
    }

    override func tearDown() async throws {
        XCUIDevice.shared.appearance = .light
    }

    func testDialogsAndSheets() throws {
        try shoot([
            Board(name: "ProductAuthSheet-v2-light", link: "t-auth", waitFor: "purchase.authSheet"),
            Board(name: "ProductAuthSheetDark-dark", link: "t-auth", dark: true, waitFor: "purchase.authSheet"),
            Board(
                name: "ProductAuthDeclined-v2-light",
                link: "t-auth",
                waitFor: "purchase.authSheet",
                then: "关闭",
                buttons: Self.retryPair
            ),
            Board(name: "ProductAuthFailed-v2-light", link: "t-auth", extra: ["-CouliFakeWebCodeUnavailable"],
                  waitFor: "purchase.authSheet", then: "purchase.auth.go", buttons: Self.retryPair),
            Board(name: "ProductAuthUnavailable-v2-light", link: "t-unavail", waitFor: "purchase.authUnavailable"),
            Board(
                name: "ProductAuthBlocked-light",
                link: "t-blocked",
                waitFor: "purchase.notice",
                buttons: Self.blocked
            ),
            Board(
                name: "ProductAuthBlocked-dark",
                link: "t-blocked",
                dark: true,
                waitFor: "purchase.notice",
                buttons: Self.blocked
            ),
            Board(name: "state-30103-light", link: "t-norebate", waitFor: "purchase.notice", buttons: Self.blocked),
            Board(name: "ProductPriceUnconfirmed-light", link: "t-503", waitFor: "purchase.notice",
                  buttons: (primary: "稍后再试", secondary: "仍去购买（无返利）")),
            Board(name: "ProductJumpSdkFailed-v2-light", link: "t-sdk", waitFor: "purchase.sdkFailed"),
            Board(name: "ProductJumpTip-v2-light", link: "visual-link", extra: ["-CouliFakeTipsUnread"],
                  waitFor: "purchase.jumpTip"),
            Board(name: "ProductJumpTipDark-dark", link: "visual-link", extra: ["-CouliFakeTipsUnread"], dark: true,
                  waitFor: "purchase.jumpTip"),
        ])
    }

    func testPriceConfirmsAndCancelledCards() throws {
        try shoot([
            Board(name: "ProductPriceChanged-v2-light", link: "t-price", waitFor: "purchase.priceChanged"),
            Board(name: "ProductPriceChangedDark-dark", link: "t-price", dark: true, waitFor: "purchase.priceChanged"),
            Board(name: "ProductCouponGone-light", link: "t-coupon", waitFor: "purchase.priceChanged"),
            Board(name: "ProductRebateGone-v2-light", link: "t-gone", waitFor: "purchase.rebateGone"),
            Board(
                name: "ProductPriceChangedRebateGone-v2-light",
                link: "t-pricegone",
                waitFor: "purchase.priceChanged"
            ),
            Board(name: "ProductPriceCompareNoRebate-v2-light", link: "t-compare", cardID: "pdd_coupon",
                  extra: ["-CouliFakePlatformStatus", "pdd=on"], waitFor: "purchase.compare",
                  buttons: (primary: "看看相似商品", secondary: "仍去购买（无返利）")),
            Board(name: "ProductPriceChangedCancelled-v2-light", link: "t-price", waitFor: "purchase.priceChanged",
                  then: "purchase.dialog.cancel", texts: ["已取消购买，价格已更新为最新"]),
            Board(name: "ProductRebateGoneCancelled-v2-light", link: "t-gone", waitFor: "purchase.rebateGone",
                  then: "purchase.dialog.cancel", texts: ["已取消购买，返利信息已更新"]),
            Board(name: "ProductPriceChangedRebateGoneCancelled-v2-light", link: "t-pricegone",
                  waitFor: "purchase.priceChanged", then: "purchase.dialog.cancel", texts: ["已取消购买，价格和返利信息已更新"]),
            Board(name: "ProductPriceCompareCancelled-v2-light", link: "t-compare", cardID: "pdd_coupon",
                  extra: ["-CouliFakePlatformStatus", "pdd=on"], waitFor: "purchase.compare", then: "关闭"),
        ])
    }

    func testLoadingTimeoutToastsAndBanners() throws {
        try shoot([
            Board(name: "ProductBuyOpening-v2-light", link: "t-slow", waitFor: "purchase.opening", wait: 0.5),
            Board(name: "ProductBuyTimeout-v2-light", link: "t-slow", waitFor: "product.buyTimeout", wait: 0.4),
            Board(name: "ProductJumpBrowser-v2-light", link: "t-browser", cardID: "jd_no_coupon_single",
                  waitFor: "purchase.browser", wait: 0.3),
            Board(name: "ProductConvertPaused-v2-light", link: "t-maint"),
            Board(name: "ProductRequoteCached-light", link: "t-requote", texts: ["暂时无法确认最新价格，以下单页为准"]),
            Board(name: "ProductJumpNotInstalled-v2-light", link: "visual-link",
                  extra: ["-CouliFakeInstalled", "taobao=false"], waitFor: "purchase.notInstalled", wait: 0.3,
                  texts: ["安装淘宝后下单才有返利", "复制淘口令", "已复制淘口令"]),
            Board(name: "ProductOffShelf-v3-light", link: "t-offshelf", wait: 1.5),
        ])
    }

    private func shoot(_ boards: [Board], file: StaticString = #filePath, testName: String = #function,
                       line: UInt = #line) throws {
        for board in boards {
            XCUIDevice.shared.appearance = board.dark ? .dark : .light
            let extra = board.extra + (board.dark ? ["-CouliFollowSystemAppearance", "YES"] : [])
            let app = try launchProduct(visualCard(board.cardID, overrides: ["link_id": board.link]), extra: extra)
            node(app, "product.buy").tap()
            if let id = board.waitFor {
                XCTAssertTrue(node(app, id).waitForExistence(timeout: 12), "\(board.name)：没等到 \(id)", file: file,
                              line: line)
            }
            if let then = board.then {
                Thread.sleep(forTimeInterval: 0.6)
                let target = node(app, then).exists ? node(app, then) : app.buttons[then].firstMatch
                target.tap()
            }
            Thread.sleep(forTimeInterval: board.wait)
            let image = app.screenshot().image
            for text in board.texts {
                let hit = app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS %@", text))
                XCTAssertTrue(hit.firstMatch.exists, "\(board.name)：画面上要能读到「\(text)」", file: file, line: line)
            }
            if board.buttons != nil {
                assertPrimaryOnTop(app, image, board, file: file, line: line)
            }
            withSnapshotTesting(record: ProcessInfo.processInfo
                .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                    assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98),
                                   named: board.name, file: file, testName: testName, line: line)
                }
            app.terminate()
        }
    }

    /// T2：主按钮在上；同一张截图里主按钮取样是品牌色、次按钮不是（与基准图同一帧，主次对调必红）。
    private func assertPrimaryOnTop(_ app: XCUIApplication, _ image: UIImage, _ board: Board, file: StaticString,
                                    line: UInt) {
        guard let buttons = board.buttons else { return }
        let name = board.name
        let primary = app.buttons[buttons.primary].firstMatch
        let secondary = app.buttons[buttons.secondary].firstMatch
        guard primary.exists, secondary.exists else {
            return XCTFail("\(name)：缺「\(buttons.primary)」或「\(buttons.secondary)」", file: file, line: line)
        }
        XCTAssertLessThan(primary.frame.minY, secondary.frame.minY, "\(name)：纵排，主「\(buttons.primary)」在上",
                          file: file, line: line)
        let top = PurchaseVisualButtonPixels.sample(image, at: primary.frame)
        let bottom = PurchaseVisualButtonPixels.sample(image, at: secondary.frame)
        XCTAssertTrue(PurchaseVisualButtonPixels.isBrand(top), "\(name)：「\(buttons.primary)」是主按钮（品牌色底）：\(top)",
                      file: file, line: line)
        XCTAssertFalse(PurchaseVisualButtonPixels.isBrand(bottom),
                       "\(name)：「\(buttons.secondary)」是次按钮（不是品牌色）：\(bottom)", file: file, line: line)
    }
}
