import CouliNetwork
import Foundation
@testable import HomeCore
import XCTest

/// 公告条（F-HOME-02、BR-TEXT-13 细则；AC-S1-90 ⑧⑨ 客户端部分 = AC-HOME-02 公告；G10、G11；brief §2 第 5 条；共性第 1、9 条）。
@MainActor
final class HomeNoticeTests: HomeRigTestCase {
    private func start(_ page: [String: Any], identity: HomeIdentity = HomeKit.memberA) async -> HomeController {
        // 每次都是没有 LKG 的冷启动（本组只看网络版的渲染）
        try? rig.lkg.clearAll()
        rig.port?.setPage(HomeKit.ok(page))
        let controller = rig.controller(identity)
        await rig.start(controller)
        return controller
    }

    private func visibleIds(_ controller: HomeController, _ section: String = "nb") -> [String] {
        controller.state.section(section)?.items.compactMap { $0.close?.itemId ?? $0.id } ?? []
    }

    /// N1 可关闭：点关闭立即隐藏，重启后不出现；content_version 加 1 后重新出现。
    /// N2 不可关闭、end_at 为 10 分钟后：不重启、推进时钟过 end_at 立即隐藏；两条都没了整卡隐藏。
    func testCloseIsRememberedAcrossRestartVersionBumpReappearsAndExpiryHidesWithoutRestart() async throws {
        let end = HomeKit.noon + 10 * 60 * 1000
        let endIso = ISO8601DateFormatter.shanghai(end)
        let items = [HomeKit.noticeItem("n1"), HomeKit.noticeItem("n2", closable: false, end: endIso)]
        let controller = await start(HomeKit.page(version: 60, [HomeKit.notice("nb", items: items)]))
        let section = try XCTUnwrap(controller.state.section("nb"))
        XCTAssertEqual(section.items.count, 2)
        guard section.items.count == 2 else { return }
        XCTAssertNil(section.items[1].close, "不可关闭的条目没有关闭按钮")
        let close = try XCTUnwrap(section.items[0].close)
        XCTAssertEqual(close.sectionId, "nb")
        XCTAssertEqual(close.itemId, "n1")
        XCTAssertEqual(close.contentVersion, 1)
        controller.closeNotice(close)
        XCTAssertEqual(controller.state.section("nb")?.items.count, 1, "关闭后立即隐藏")
        XCTAssertTrue(rig.prefs.closedKeys().contains(NoticeFilter.closeKey(
            sectionId: "nb",
            itemId: "n1",
            contentVersion: 1
        )))

        // 不重启推进时钟：过 end_at 立即隐藏（不重新拉取），两条都没了整卡隐藏
        rig.clock.advance(10 * 60 * 1000 - 1)
        await controller.whenIdle()
        XCTAssertEqual(controller.state.section("nb")?.items.count, 1)
        rig.clock.advance(1)
        await controller.whenIdle()
        XCTAssertNil(controller.state.section("nb"), "到期要立即隐藏，全空整卡隐藏")
        XCTAssertEqual(rig.port?.pageCalls.count, 1, "到期重算不轮询网络")

        // 重启（新控制器、同一份设备级记录）：N1 仍不出现
        let restarted = await start(HomeKit.page(
            version: 61,
            [HomeKit.notice("nb", items: [HomeKit.noticeItem("n1")])]
        ))
        XCTAssertNil(restarted.state.section("nb"))
        // content_version 加 1：重新出现
        let bumped = await start(HomeKit.page(
            version: 62,
            [HomeKit.notice("nb", items: [HomeKit.noticeItem("n1", version: 2)])]
        ))
        XCTAssertEqual(bumped.state.section("nb")?.items.count, 1)
    }

    /// 关闭记录是设备级：换账号后另一个账号也看不到已关闭的同一版本公告。
    func testClosedRecordIsDeviceLevelAcrossAccounts() async throws {
        let page = HomeKit.page(version: 63, [HomeKit.notice("nb", items: [HomeKit.noticeItem("n1")])])
        let first = await start(page)
        first.closeNotice(try XCTUnwrap(first.state.section("nb")?.items.first?.close))
        let other = await start(page, identity: HomeKit.memberB)
        XCTAssertNil(other.state.section("nb"))
        let guest = await start(page, identity: HomeKit.guest)
        XCTAssertNil(guest.state.section("nb"))
    }

    /// 关闭回调按渲染时的三元组记录（会话换代、控制器作废之后执行也一样，不读执行时状态）；撤回同意清空之后旧回调不再落盘。
    func testCloseCallbackRecordsRenderedTripleAfterInvalidationButNotAfterClearAll() async throws {
        let controller = await start(HomeKit.page(version: 64, [
            HomeKit.notice("nb", items: [HomeKit.noticeItem("n1", version: 3), HomeKit.noticeItem("n9", version: 3)]),
        ]))
        let items = try XCTUnwrap(controller.state.section("nb")?.items)
        guard items.count == 2 else { return XCTFail("应显示两条公告：\(items.count)") }
        let first = try XCTUnwrap(items[0].close)
        let second = try XCTUnwrap(items[1].close)
        controller.invalidate()
        controller.closeNotice(first)
        XCTAssertTrue(rig.prefs.closedKeys().contains(NoticeFilter.closeKey(
            sectionId: "nb",
            itemId: "n1",
            contentVersion: 3
        )))
        try rig.prefs.clearAll()
        controller.closeNotice(second)
        XCTAssertFalse(
            rig.prefs.closedKeys().contains(NoticeFilter.closeKey(sectionId: "nb", itemId: "n9", contentVersion: 3)),
            "撤回同意（清空）之后的旧回调不得落盘"
        )
    }

    /// 基本模式与预览只读：点关闭只在本次页面内隐藏，不写设备级记录（G24 ⑥、G25、H10）。
    func testBasicModeAndPreviewCloseIsInMemoryOnly() async throws {
        let page = HomeKit.page(version: 65, [HomeKit.notice("nb", items: [HomeKit.noticeItem("n1")])])
        let basic = await start(page, identity: HomeKit.basic)
        basic.closeNotice(try XCTUnwrap(basic.state.section("nb")?.items.first?.close))
        XCTAssertNil(basic.state.section("nb"))
        let preview = rig.controller(HomeKit.memberA, preview: true)
        preview.showDraft(HomeVectors.data(page))
        await preview.whenIdle()
        preview.closeNotice(try XCTUnwrap(preview.state.section("nb")?.items.first?.close))
        XCTAssertNil(preview.state.section("nb"))
        XCTAssertTrue(rig.prefs.closedKeys().isEmpty, "只读模式写了关闭记录")
    }

    /// 生效区间本机再过滤：未到 start_at 不显示，到点（页面停留期间）出现。
    func testNotYetStartedNoticeAppearsWhenItStarts() async {
        let startAt = ISO8601DateFormatter.shanghai(HomeKit.noon + 60_000)
        let controller = await start(HomeKit.page(version: 66, [
            HomeKit.notice("nb", items: [HomeKit.noticeItem("n1", start: startAt)]),
        ]))
        XCTAssertNil(controller.state.section("nb"))
        rig.clock.advance(60_000)
        await controller.whenIdle()
        XCTAssertEqual(controller.state.section("nb")?.items.count, 1, "到 start_at 要出现（G10 本机再过滤）")
    }

    /// 条目点击：target 非 null 经 Router 打开（Notice {article_id}），null 不可点。
    func testNoticeTargetOpensAndNullTargetIsNotTappable() async throws {
        let controller = await start(HomeKit.page(version: 67, [HomeKit.notice("nb", items: [
            HomeKit.noticeItem("n1", target: ["route": "Notice", "params": ["article_id": "test_notice_main"]]),
            HomeKit.noticeItem("n2"),
        ])]))
        let items = try XCTUnwrap(controller.state.section("nb")?.items)
        guard items.count == 2 else { return XCTFail("应显示两条公告：\(items.count)") }
        XCTAssertNil(items[1].tap)
        controller.open(try XCTUnwrap(items[0].tap))
        XCTAssertEqual(rig.opened.last?.target.route, "Notice")
        XCTAssertEqual(rig.opened.last?.target.params, ["article_id": .string("test_notice_main")])
    }

    // MARK: - api 来源（G10）

    /// api 来源只调 listArticles(category=notice) 第一页（不带 Cursor、不带别的参数），按 NoticeItem 过滤后显示；结果被采用。
    func testApiNoticeUsesListArticlesFirstPageOnly() async throws {
        let controller = await start(try HomeVectors.golden("notice_api"))
        await controller.whenIdle()
        XCTAssertEqual(rig.articles.calls.count, 1)
        let call = try XCTUnwrap(rig.articles.calls.first)
        XCTAssertEqual(call.operationId, "listArticles")
        XCTAssertEqual(call.query, "category=notice")
        XCTAssertNil(call.body)
        let section = try XCTUnwrap(controller.state.section("notice_api"))
        XCTAssertEqual(section.items.compactMap(\.title), ["确认收货后，返利随联盟月度结算入账", "测试公告：国庆期间结算顺延"])
        XCTAssertEqual(section.items.first?.close?.itemId, "api1")
        XCTAssertNil(section.items.last?.close)
    }

    /// api 来源失败或为空 → 隐藏卡片，不提示；失败留在卡片状态里（A28 裁定）。42901 写入共享闸门。
    func testApiNoticeFailureOrEmptyHidesSilently() async {
        for (index, result) in [HomeKit.failure(50001), HomeKit.notices([]), HomeKit.failure(42901, retryAfter: "3")]
            .enumerated() {
            rig.articles.fallback = result
            let controller = await start(HomeKit.page(version: 70 + index, [
                HomeKit.noticeApi("nb"), HomeKit.activity("act", titles: ["测试入口"]),
            ]))
            await controller.whenIdle()
            XCTAssertEqual(controller.state.sectionIds, ["act"], "\(result)")
            XCTAssertNil(controller.state.toast)
        }
        XCTAssertTrue(rig.gate.active, "listArticles 的 42901 也写入共享闸门（共性第 4 条）")
    }

    /// api 来源在 notice_bar 以外的卡片上按解码失败（G03）；data_source 里出现的接口路径一律忽略。
    func testApiSourceOutsideNoticeIsDroppedAndExtraPathsAreIgnored() async {
        let controller = await start(HomeKit.page(version: 75, [
            ["id": "x", "type": "banner", "version": 1, "props": ["height_ratio": 0.4, "autoplay_ms": 0],
             "data_source": ["kind": "api"]],
            ["id": "nb", "type": "notice_bar", "version": 1, "props": [:] as [String: Any],
             "data_source": ["kind": "api", "path": "/v1/other", "category": "help"]],
        ]))
        await controller.whenIdle()
        XCTAssertNil(controller.state.section("x"))
        XCTAssertEqual(rig.articles.calls.map(\.query), ["category=notice"])
        XCTAssertEqual(rig.cardErrors.count, 1)
    }

    /// api 公告的迟到隔离：旧渲染的 listArticles 挂起，下拉换来同一 section id 的新公告后，旧响应迟到不覆盖新内容（共性第 1 条，brief §0）。
    func testLateApiNoticeFromReplacedRenderDoesNotOverwriteNewNotices() async {
        let old = Hold()
        rig.articles.queue(.held(old), .now(HomeKit.notices([HomeKit.noticeItem("new1", text: "测试新公告")])))
        try? rig.lkg.clearAll()
        rig.port?.setPage(HomeKit.ok(HomeKit.page(version: 80, [HomeKit.noticeApi("nb")])))
        let controller = rig.controller()
        controller.start()
        await waitFor("旧公告请求没发出") { rig.articles.calls.count == 1 }
        rig.port?.setPage(HomeKit.ok(HomeKit.page(version: 81, [HomeKit.noticeApi("nb")])))
        controller.refresh(controller.state.render)
        await waitFor("新公告没显示") { controller.state.section("nb")?.items.compactMap(\.title) == ["测试新公告"] }
        old.release(HomeKit.notices([HomeKit.noticeItem("old1", text: "测试旧公告")]))
        await controller.whenIdle()
        XCTAssertEqual(controller.state.section("nb")?.items.compactMap(\.title), ["测试新公告"], "旧响应覆盖了新公告")
        XCTAssertTrue(rig.events.isEmpty)
        XCTAssertTrue(rig.prefs.closedKeys().isEmpty)
    }

    /// 控制器作废（换账号 / 撤回同意）后旧的 listArticles 才回来：不显示、不写闸门（旧会话的 42901 不限流新会话）、不发事件。
    func testApiNoticeArrivingAfterInvalidationHasNoEffect() async {
        for late in [HomeKit.notices(), HomeKit.failure(42901, retryAfter: "30")] {
            let rig = HomeRig(name: "notice-late")
            defer { rig.tearDown() }
            let old = Hold()
            rig.articles.queue(.held(old))
            rig.port?.setPage(HomeKit.ok(HomeKit.page(version: 82, [HomeKit.noticeApi("nb")])))
            let controller = rig.controller()
            controller.start()
            await waitFor("公告请求没发出") { rig.articles.calls.count == 1 }
            controller.invalidate()
            old.release(late)
            await controller.whenIdle()
            XCTAssertTrue(controller.state.sections.isEmpty)
            XCTAssertFalse(rig.gate.active, "作废后的旧响应写了闸门")
            XCTAssertTrue(rig.events.isEmpty)
        }
    }

    /// 同一会话里旧渲染的 listArticles 迟到并返回 42901：新公告不变，但共享闸门按 Retry-After 启动、之后的发送被拦
    /// （共性第 4 条：42901 一律写闸门；对照 testApiNoticeArrivingAfterInvalidationHasNoEffect：作废后的旧 42901 不写；评审 T-19）。
    func testLate42901FromReplacedRenderStillStartsTheSharedGate() async {
        let old = Hold()
        rig.articles.queue(.held(old), .now(HomeKit.notices([HomeKit.noticeItem("new1", text: "测试新公告")])))
        try? rig.lkg.clearAll()
        rig.port?.setPage(HomeKit.ok(HomeKit.page(version: 83, [HomeKit.noticeApi("nb")])))
        let controller = rig.controller()
        controller.start()
        await waitFor("旧公告请求没发出") { rig.articles.calls.count == 1 }
        rig.port?.setPage(HomeKit.ok(HomeKit.page(version: 84, [HomeKit.noticeApi("nb")])))
        controller.refresh(controller.state.render)
        await waitFor("新公告没显示") { controller.state.section("nb")?.items.compactMap(\.title) == ["测试新公告"] }
        old.release(HomeKit.failure(42901, retryAfter: "30"))
        await controller.whenIdle()
        XCTAssertEqual(controller.state.section("nb")?.items.compactMap(\.title), ["测试新公告"], "旧 42901 改了新公告")
        XCTAssertTrue(rig.gate.active, "旧渲染的 42901 没写共享闸门")
        XCTAssertEqual(rig.gate.remainingMillis, 30000)
        let pages = rig.port?.pageCalls.count
        controller.refresh(controller.state.render)
        await controller.whenIdle()
        XCTAssertEqual(rig.port?.pageCalls.count, pages, "闸门启动后下拉仍发出")
        XCTAssertEqual(controller.state.toast?.message, "error.42901")
    }
}

extension ISO8601DateFormatter {
    /// 绝对毫秒 → 带 +08:00 的时刻文字（测试数据用）。
    static func shanghai(_ millis: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }
}
