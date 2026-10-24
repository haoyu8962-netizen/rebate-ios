import XCTest

@MainActor
final class HomeVisualAccessibilityTests: HomeVisualUITestCase {
    /// S2-6：从 b 的混合方法拆回 a；用三条可滚公告先证明真实视图会切换，再打开读屏。
    func testNoticeStopsWhenReaderIsOn() throws {
        try launch(.standard(scene: "banner_notice"), overrides: .init(rotatingNotice: true))
        _ = try reveal("home.notice.text")
        XCTAssertEqual(noticeLabels.count, 1, "读屏关闭时必须确实处于轮播状态")
        let first = try XCTUnwrap(noticeLabels.first)
        UIWait.until("真实公告在读屏关闭时换帧", ceiling: 6) {
            self.noticeLabels.count == 1 && self.noticeLabels.first != first
        }
        HomeUITestSignalNames.post("com.couli.app.debug.uitest.home-visual.reader-on")
        UIWait.until("读屏开启后真实公告全部静态呈现", ceiling: 5) {
            self.noticeLabels == HomeVisualRequestOverrides.notices
        }
        let notice = noticeLabels
        HomeUITestSignalNames.post("com.couli.app.debug.uitest.home-visual.advance-10000")
        UIWait.until("手动时钟已推进", ceiling: 5) {
            self.element("home.visual.clock").value as? String == "10000"
        }
        XCTAssertEqual(noticeLabels, notice)
        // HomeNoticeView 的轮播用 Task.sleep，推进 Core 手动时钟不能代替跨过真实 4 秒轮播周期。
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(8500))
        while clock.now < deadline {
            XCTAssertEqual(noticeLabels, notice, "读屏开启后不得恢复轮播或漏掉公告")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        keepTree("notice-reader-on-static")
    }

    /// S2-5：原文来自 listSectionItems 的 ad_label，故意与区块标识不同，不能硬编码默认「推广」。
    func testAllThreeProductCardsSpeakServerAdLabelExactlyOnce() throws {
        for label in ["推广", "商家赞助·限时合作"] {
            try launch(.standard(), overrides: .init(adLabel: label))
            for kind in ["scroll", "grid", "feed"] {
                let card = try reveal("home.product.\(kind).0")
                XCTAssertEqual(card.elementType, .button)
                XCTAssertTrue(card.label.contains(label), "\(kind) 整卡读屏名丢失服务端 item.adLabel 原文")
                XCTAssertEqual(card.label.components(separatedBy: label).count - 1, 1, "推广标识只能读一次")
                XCTAssertFalse(card.label.contains(HomeVisualRequestOverrides.sectionAdLabel), "商品标识优先于区块标识")
                if label != "推广" {
                    XCTAssertFalse(card.label.contains("推广"), "非默认标识不能再拼硬编码的默认推广文案")
                }
                let duplicate = card.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
                XCTAssertEqual(duplicate.count, 0, "整卡合并后不能另留可读的推广角标")
            }
            keepTree("product-ad-label-\(label)")
        }
    }

    private var noticeLabels: [String] {
        app.staticTexts.matching(identifier: "home.notice.text").allElementsBoundByIndex.map(\.label)
    }
}
