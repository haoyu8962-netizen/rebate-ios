import XCTest

/// 设计稿比对截图（APP-06b）：只在设置 TEST_RUNNER_COULI_SHOT_DIR 时跑，截图写到 NATIVE/APP-06b/shots/ios/。全部假数据。
@MainActor
final class TradeShotTests: XCTestCase, TradeUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        // 截图用例只在给了截图目录时跑；跳过时不必收尾
        if let dir = ProcessInfo.processInfo.environment["COULI_SHOT_DIR"], !dir.isEmpty {
            resetFakeSession()
        }
    }

    // MARK: - 截图（设计稿比对）

    func testShotsBuyFlow() throws {
        try requireShots()
        let app = launch(["-CouliFakeTipsRead"])
        product(app, "tb:t-slow")
        pause()
        save(app, "Product")
        element(app, "product.buy").tap()
        XCTAssertTrue(element(app, "purchase.opening").waitForExistence(timeout: 5))
        pause(0.5)
        save(app, "ProductBuyOpening")
        XCTAssertTrue(element(app, "product.buyTimeout").waitForExistence(timeout: 12), "8 秒没有超时提示")
        pause(0.4)
        save(app, "ProductBuyTimeout")
        app.terminate()

        let cases = [
            ShotCase(key: "tb:t-price", board: "ProductPriceChanged", cancelled: "ProductPriceChangedCancelled"),
            ShotCase(key: "tb:t-pricegone", board: "ProductPriceChangedRebateGone",
                     cancelled: "ProductPriceChangedRebateGoneCancelled"),
            ShotCase(key: "tb:t-gone", board: "ProductRebateGone", cancelled: "ProductRebateGoneCancelled"),
            ShotCase(key: "tb:t-coupon", board: "ProductCouponGone", cancelled: "ProductCouponGoneCancelled"),
        ]
        for item in cases {
            let app = launch(["-CouliFakeTipsRead"])
            product(app, item.key)
            element(app, "product.buy").tap()
            pause(1.6)
            save(app, item.board)
            if let cancelled = item.cancelled {
                element(app, "purchase.dialog.cancel").tap()
                pause(0.8)
                save(app, cancelled)
            }
            app.terminate()
        }
    }

    func testShotsCompareAndJumpTip() throws {
        try requireShots()
        // 包内配置里拼多多是 not_launched：假服务改成 on 才能买
        var app = launch(["-CouliFakeTipsRead", "-CouliFakePlatformStatus", "pdd=on"])
        product(app, "pdd:t-compare")
        element(app, "product.buy").tap()
        XCTAssertTrue(element(app, "purchase.compare").waitForExistence(timeout: 10))
        pause()
        save(app, "ProductPriceCompareNoRebate")
        app.buttons["关闭"].firstMatch.tap()
        pause(0.8)
        save(app, "ProductPriceCompareCancelled")
        app.terminate()

        // 下单须知（用户 × 平台首次）
        app = launch()
        product(app, "tb:t-ok")
        element(app, "product.buy").tap()
        XCTAssertTrue(element(app, "purchase.jumpTip").waitForExistence(timeout: 10))
        pause()
        save(app, "ProductJumpTip")
        element(app, "purchase.jumpTip.go").tap()
        pause(1.0)
        save(app, "ProductJump-copied")
        app.terminate()
    }

    func testShotsJumpResults() throws {
        try requireShots()
        let jumps = [
            JumpCase(
                key: "tb:t-noinst",
                name: "ProductJumpNotInstalled",
                extra: ["-CouliFakeInstalled", "taobao=false"]
            ),
            JumpCase(key: "jd:t-browser", name: "ProductJumpBrowser", wait: 1.0),
            JumpCase(key: "tb:t-sdk", name: "ProductJumpSdkFailed"),
            JumpCase(key: "tb:t-unavail", name: "ProductAuthUnavailable"),
            JumpCase(key: "tb:t-blocked", name: "ProductNotice-30153"),
            JumpCase(key: "tb:t-503", name: "ProductNotice-50303-trace6"),
            JumpCase(key: "tb:t-maint", name: "ProductConvertPaused-maintenance-tap", wait: 1.2),
            JumpCase(key: "tb:t-notlaunched", name: "ProductCardDegrade-notLaunched-tap"),
            JumpCase(key: "tb:t-offshelf", name: "Product-offShelf-30141-tap"),
            JumpCase(key: "tb:t-requote", name: "ProductRequoteNotice", wait: 1.2),
        ]
        for item in jumps {
            let app = launch(["-CouliFakeTipsRead"] + item.extra)
            product(app, item.key)
            element(app, "product.buy").tap()
            pause(item.wait)
            save(app, item.name)
            app.terminate()
        }
    }

    func testShotsAuth() throws {
        try requireShots()
        var app = launch(["-CouliFakeTipsRead"])
        product(app, "tb:t-auth")
        element(app, "product.buy").tap()
        XCTAssertTrue(element(app, "purchase.authSheet").waitForExistence(timeout: 10))
        pause()
        save(app, "ProductAuthSheet")
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(element(app, "purchase.authDeclined").waitForExistence(timeout: 5))
        pause()
        save(app, "ProductAuthDeclined")
        element(app, "purchase.auth.retry").tap()
        XCTAssertTrue(element(app, "purchase.authSheet").waitForExistence(timeout: 10), "用户主动重试仍弹授权")
        element(app, "purchase.auth.go").tap()
        pause(2.5)
        save(app, "ProductAuth-resumed")
        app.terminate()

        app = launch(["-CouliFakeTipsRead", "-CouliFakeWebCodeUnavailable"])
        product(app, "tb:t-auth")
        element(app, "product.buy").tap()
        XCTAssertTrue(element(app, "purchase.auth.go").waitForExistence(timeout: 10))
        element(app, "purchase.auth.go").tap()
        XCTAssertTrue(element(app, "purchase.authFailed").waitForExistence(timeout: 5))
        pause()
        save(app, "ProductAuthFailed")
        app.terminate()
    }

    func testShotsSearchAndAuthManage() throws {
        try requireShots()
        var app = launch(["-CouliFakeTipsRead"])
        search(app, "buy")
        pause()
        save(app, "Search-buy-cards")
        // 列表卡购买：8 秒超时条（共性第 29 条）
        cardBuy(app, 3).tap()
        XCTAssertTrue(element(app, "search.buyTimeout").waitForExistence(timeout: 12), "列表卡没有超时提示")
        pause(0.4)
        save(app, "Search-buyTimeout")
        app.terminate()

        app = launch(["-CouliFakeTipsRead", "-CouliFakePlatformStatus", "pdd=on"])
        search(app, "pdd:t-compare")
        cardBuy(app, 0).tap()
        XCTAssertTrue(element(app, "purchase.compare").waitForExistence(timeout: 10))
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(element(app, "search.compareReason").waitForExistence(timeout: 5))
        pause()
        save(app, "Search-PriceCompareCancelled")
        app.terminate()

        for (extra, name) in [
            ([String](), "AuthManage"),
            (["-CouliFakeTaobaoBinding", "blocked"], "AuthManageBlocked"),
        ] {
            app = launch(extra)
            ShellTabBar.tap(app, "我的")
            pause()
            save(app, "Me-AuthManageEntry")
            element(app, "me.authManage").tap()
            XCTAssertTrue(element(app, "authManage.status.taobao").waitForExistence(timeout: 10))
            if name == "AuthManageBlocked" {
                // 列表直接回 blocked：不给【去授权】，行下方停用说明 +【联系客服】
                XCTAssertTrue(element(app, "authManage.blocked.taobao").waitForExistence(timeout: 10))
            }
            pause()
            save(app, name)
            app.terminate()
        }
    }

    /// 200% 字号、320 窄屏、短屏的 AuthSheet 与改价确认（AdaptShortAuthSheet 在 667pt 高的机型上另截，见 compare-ios.md）。
    func testShotsAdaptAuthSheet() throws {
        try requireShots()
        let variants: [([String], String)] = [
            (["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"], "AdaptLargeText200"),
            (["-CouliDebugLayoutWidth", "320"], "AdaptNarrow"),
            (["-CouliDebugLayoutWidth", "320", "-UIPreferredContentSizeCategoryName",
              "UICTContentSizeCategoryAccessibilityL"], "AdaptNarrow320-200"),
        ]
        for (extra, prefix) in variants {
            var app = launch(["-CouliFakeTipsRead"] + extra)
            product(app, "tb:t-auth")
            element(app, "product.buy").tap()
            XCTAssertTrue(element(app, "purchase.authSheet").waitForExistence(timeout: 10))
            pause()
            save(app, prefix + "AuthSheet")
            let go = element(app, "purchase.auth.go")
            XCTAssertTrue(go.exists && app.frame.contains(go.frame), "放大 / 窄屏下【去授权】在屏幕内")
            app.buttons["关闭"].firstMatch.tap()
            pause()
            save(app, prefix + "AuthDeclined")
            app.terminate()

            app = launch(["-CouliFakeTipsRead"] + extra)
            product(app, "tb:t-pricegone")
            element(app, "product.buy").tap()
            XCTAssertTrue(element(app, "purchase.priceChanged").waitForExistence(timeout: 10))
            pause()
            save(app, prefix + "PriceChanged")
            let button = element(app, "purchase.dialog.continue")
            XCTAssertTrue(button.exists && app.frame.contains(button.frame), "放大 / 窄屏下【继续购买】在屏幕内")
            app.terminate()
        }
    }

    /// AdaptShortAuthSheet：在 667pt 高的机型（iPhone SE 3）上跑：常规字号与 200% 字号的授权半屏（头部与【去授权】固定、正文滚动）。
    func testShotsShortAuthSheet() throws {
        try requireShots()
        let variants = [
            JumpCase(key: "tb:t-auth", name: "AdaptShortAuthSheet"),
            JumpCase(key: "tb:t-auth", name: "AdaptShortAuthSheet-200",
                     extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]),
        ]
        for item in variants {
            let app = launch(["-CouliFakeTipsRead"] + item.extra)
            product(app, item.key)
            element(app, "product.buy").tap()
            XCTAssertTrue(element(app, "purchase.authSheet").waitForExistence(timeout: 10))
            pause()
            let go = element(app, "purchase.auth.go")
            XCTAssertTrue(go.exists && app.frame.contains(go.frame), "短屏【去授权】固定在屏幕内")
            save(app, item.name)
            app.terminate()
        }
    }

    /// 读屏顺序（A11yFocusAuthSheet）：半屏打开后，可访问元素依次为 标题 → 关闭 → 三条要点 → 去授权；底层页面对读屏隐藏。
    /// 把顺序写进附件与截图目录（compare-ios.md 引用）。
    func testAuthSheetAccessibilityOrder() throws {
        try requireShots()
        let app = launch(["-CouliFakeTipsRead"])
        product(app, "tb:t-auth")
        element(app, "product.buy").tap()
        let sheet = element(app, "purchase.authSheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        pause()
        let labels = sheet.descendants(matching: .any).allElementsBoundByIndex
            .filter { !$0.label.isEmpty && ($0.elementType == .staticText || $0.elementType == .button) }
            .map { "\($0.elementType == .button ? "按钮" : "文字")：\($0.label)" }
        var order: [String] = []
        for label in labels where order.last != label {
            order.append(label)
        }
        if let dir = ProcessInfo.processInfo.environment["COULI_SHOT_DIR"], !dir.isEmpty {
            try? order.joined(separator: "\n").write(
                to: URL(fileURLWithPath: dir).appendingPathComponent("A11yFocusAuthSheet-order.txt"),
                atomically: true, encoding: .utf8
            )
        }
        save(app, "A11yFocusAuthSheet")
    }
}

private struct ShotCase {
    let key: String
    let board: String
    let cancelled: String?
}

private struct JumpCase {
    let key: String
    let name: String
    var extra: [String] = []
    var wait: Double = 1.6
}
