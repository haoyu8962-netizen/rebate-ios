import Clipboard
@testable import Couli
import CouliNetwork
import Foundation
import Router
import XCTest

/// APP-07 iOS 第 1 轮评审 R1-01、R1-03、R1-04（共性第 28、30、31 条）。R1-02（整体 10405 迟到）用真实 ApiClient，见
/// ClipboardForceUpdateLateTests。
extension ClipboardWiringTests {
    /// 用户点了系统粘贴控件（此刻 UIKit 调接收方的 paste(itemProviders:)），返回「系统稍后交付文本」的回调。
    func click(_ fixture: Fixture, entry: String) -> @MainActor (String?) -> Void {
        let deliver = fixture.clipboard.beginPaste(entry: entry)
        return { text in deliver?(text) }
    }

    /// 商品提示条里的系统粘贴控件被点了。
    func clickPrompt(_ fixture: Fixture, id: Int64) -> @MainActor (String?) -> Void {
        let deliver = fixture.clipboard.beginPromptPaste(id)
        return { text in deliver?(text) }
    }

    // MARK: - R1-01 系统粘贴的异步交付绑定点击时的页面与世代

    /// 首页点了粘贴，交付前进后台再回来：旧文本丢弃（不 parse、不出提示）；等待期间入口按忙碌置灰，作废后恢复。
    func testR1_01_DeliveryAfterBackgroundRoundTripIsDropped() async {
        let fixture = make()
        fixture.clipboard.sceneActive()
        let deliver = click(fixture, entry: ManualPasteAction.entryHome)
        XCTAssertFalse(fixture.clipboard.pasteEnabled, "读取等待期间入口忙碌（一次点击只读一次）")
        fixture.clipboard.sceneBackground()
        XCTAssertTrue(fixture.clipboard.pasteEnabled, "进后台同步作废读取，忙碌解除")
        fixture.clipboard.sceneActive()
        deliver(link)
        deliver("普通文字，没有链接")
        await settle()
        XCTAssertEqual(fixture.api.bodies.count, 0, "迟到的交付不发 parse")
        XCTAssertNil(fixture.clipboard.result, "也不出 30132 等本地提示")
        XCTAssertFalse(fixture.routing.router.path.contains { $0.route == "ProductDetail" })
    }

    /// 首页点了粘贴，交付前打开 Login：旧文本不归到 Login（不 parse、Login 上不出任何剪贴板结果）。
    func testR1_01_DeliveryAfterOpeningLoginIsDropped() async {
        let fixture = make()
        fixture.clipboard.sceneActive()
        let product = click(fixture, entry: ManualPasteAction.entryHome)
        fixture.routing.router.path = [RouteDestination(route: "Login")]
        product(link)
        await settle()
        XCTAssertEqual(fixture.api.bodies.count, 0, "不把旧输入当成 Login 的输入发 parse")
        XCTAssertNil(fixture.clipboard.result)
        fixture.routing.router.path = []
        let local = click(fixture, entry: ManualPasteAction.entryHome)
        fixture.routing.router.path = [RouteDestination(route: "Login")]
        local("普通文字，没有链接")
        XCTAssertNil(fixture.clipboard.result, "本地 30132 提示也不落到 Login")
        XCTAssertEqual(fixture.routing.router.path.map(\.route), ["Login"])
    }

    /// SearchTyping 点了粘贴，交付前页面出栈（回首页）：丢弃，不在首页上出结果。商品提示条的控件同样绑定点击时的前台轮次。
    func testR1_01_SearchAndPromptDeliveriesBoundToClickTime() async throws {
        let fixture = make()
        fixture.clipboard.sceneActive()
        fixture.routing.router.open(RouteRequest(route: "Search", from: .inApp))
        let search = click(fixture, entry: ManualPasteAction.entrySearchTyping)
        fixture.routing.router.path = []
        search("普通文字，没有链接")
        search(link)
        await settle()
        XCTAssertEqual(fixture.api.bodies.count, 0)
        XCTAssertNil(fixture.clipboard.result)

        fixture.clipboard.sceneBackground()
        fixture.system.changeCount += 1
        fixture.system.detectHit = true
        fixture.clipboard.sceneActive()
        let prompt = try XCTUnwrap(fixture.clipboard.prompt)
        let fromPrompt = clickPrompt(fixture, id: prompt.id)
        fixture.clipboard.sceneBackground()
        fixture.clipboard.sceneActive()
        fromPrompt(link)
        await settle()
        XCTAssertEqual(fixture.api.bodies.count, 0, "提示条的粘贴同样在交付时复核点击时的前台轮次")
    }

    /// 登录页邀请码【粘贴】：点击后登录页出栈或经过后台，迟到的文本不填码、不出提示；登录页仍在则照常抽码。
    func testR1_01_LoginInvitePasteBoundToLoginPageAndRound() throws {
        let fixture = make()
        fixture.clipboard.sceneActive()
        fixture.routing.router.path = [RouteDestination(route: "Login")]
        let paste = fixture.clipboard.makeLoginInvitePaste()
        let popped = try XCTUnwrap(paste.begin())
        fixture.routing.router.path = [RouteDestination(route: "Login")]
        XCTAssertEqual(popped("邀请码 K7M2QX"), .ignored, "换了登录页实例：旧交付丢弃")
        let backgrounded = try XCTUnwrap(paste.begin())
        fixture.clipboard.sceneBackground()
        fixture.clipboard.sceneActive()
        XCTAssertEqual(backgrounded("邀请码 K7M2QX"), .ignored, "经过后台：旧交付丢弃")
        let live = try XCTUnwrap(paste.begin())
        XCTAssertEqual(live("邀请码 K7M2QX"), .code("K7M2QX"))
    }

    /// 对照：点击后没有任何变化，交付照常处理（恰好 1 次 parse），交付后忙碌随请求结束解除。
    func testR1_01_DeliveryWithoutChangeStillParses() async {
        let fixture = make()
        fixture.clipboard.sceneActive()
        let deliver = click(fixture, entry: ManualPasteAction.entryHome)
        deliver(link)
        deliver(link)
        await settle()
        XCTAssertEqual(fixture.api.bodies.count, 1, "同一次点击只交付一次")
        XCTAssertTrue(fixture.clipboard.pasteEnabled)
    }

    // MARK: - R1-03 整体 30132 用本地抽出的标题预填

    /// 服务端整体 30132、data=null：用请求前本地抽出的「」标题预填【用商品名搜索】，不依赖 data.raw，不存原文。
    func testR1_03_Whole30132PrefillsLocallyExtractedTitle() async throws {
        let fixture = make()
        fixture.clipboard.sceneActive()
        fixture.api.reply = .failure(code: 30132)
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: "https://e.tb.cn/h.Demo01 「降噪蓝牙耳机」")
        await settle()
        let result = try XCTUnwrap(fixture.clipboard.result)
        guard case let .unrecognized(_, prefill) = result.kind else {
            return XCTFail("整体 30132 给【用商品名搜索】")
        }
        XCTAssertEqual(prefill, "降噪蓝牙耳机")
        fixture.clipboard.searchByName(result.id, prefill: prefill)
        let search = try XCTUnwrap(fixture.routing.router.path.last)
        XCTAssertEqual(search.route, "Search")
        XCTAssertEqual(search.params["q"], .string("降噪蓝牙耳机"), "搜索框预填商品名")
    }

    /// 没有「」标题时整体 30132 留空（不拿链接或原文当预填）。
    func testR1_03_Whole30132WithoutTitleLeavesPrefillEmpty() async throws {
        let fixture = make()
        fixture.clipboard.sceneActive()
        fixture.api.reply = .failure(code: 30132)
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: "看看这个 https://e.tb.cn/h.Demo01 好物")
        await settle()
        guard case let .unrecognized(_, prefill) = try XCTUnwrap(fixture.clipboard.result).kind else {
            return XCTFail("整体 30132")
        }
        XCTAssertNil(prefill)
    }

    // MARK: - R1-04 多卡结果的商品按钮受共享限流

    /// 一张正常卡 + 行内 42901：5 秒禁用期内点卡片 / 购买不导航；到期后恢复。
    func testR1_04_CardTapBlockedDuringRateLimitThenRecovers() async throws {
        let clock = ClipboardTestClock()
        let fixture = make(clock: { clock.now })
        fixture.clipboard.sceneActive()
        fixture.api.reply = .multi(errorCode: 42901)
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await settle()
        let result = try XCTUnwrap(fixture.clipboard.result)
        guard case let .cardList(rows, _) = result.kind, let card = rows.first?.card else {
            return XCTFail("多卡弹层")
        }
        XCTAssertTrue(fixture.clipboard.blocked)
        fixture.clipboard.openCard(result.id, card: card)
        XCTAssertTrue(fixture.routing.router.path.isEmpty, "禁用期内点卡片 / 购买不打开详情")
        XCTAssertEqual(fixture.clipboard.result?.id, result.id, "被拦下的点击不关掉弹层")
        clock.now += ErrorActionMapper.defaultRetryAfterMillis + 1
        fixture.clipboard.openCard(result.id, card: card)
        XCTAssertEqual(fixture.routing.router.path.last?.route, "ProductDetail", "到期恢复")
    }
}

/// 可拨动的测试时钟（毫秒）。
final class ClipboardTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_000_000

    var now: Int64 {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
