import Clipboard
@testable import Couli
import CouliNetwork
import Foundation
import Router
import XCTest

/// FU-IOS-0730 第 2 条（评审 APP-11v-b-ios r1 S2-2）：① / ⑤ 结果卡去掉【关闭】后，「下一次粘贴就收起」要真成立——
/// 用户开始一次新的手动粘贴（任何商品粘贴入口），旧的 ① / ⑤ 卡就清掉，不论这次粘贴最后有没有新结果。
/// 覆盖评审列的路径：SearchTyping 页粘贴空文本、已登录粘贴纯邀请码（及 App 自写的邀请内容）、parse 被丢弃；外加新 parse 在途期间。
/// 只经生产入口（`pasted` / `beginPaste`），读界面结果 `result`。
final class FollowupIos0730ClearTests: FollowupIos0730TestCase {
    // MARK: - 开始粘贴的那一刻

    /// 点击时（系统交付文本之前）旧卡就收起：「开始一次新的手动粘贴」以点击为准。
    func testBeginPasteClearsOldCardBeforeDelivery() throws {
        for entry in [ManualPasteAction.entryHome, ManualPasteAction.entrySearchTyping] {
            let fixture = make()
            if entry == ManualPasteAction.entrySearchTyping {
                _ = openSearchTyping(fixture)
            }
            _ = try showUnrecognized(fixture, entry: entry)
            let deliver = try XCTUnwrap(fixture.clipboard.beginPaste(entry: entry), "入口可用")
            XCTAssertNil(fixture.clipboard.result, "\(entry)：点了粘贴，旧 ① 卡就收起")
            deliver(plain)
            XCTAssertEqual(Self.name(fixture.clipboard.result), "unrecognized", "交付后照常出新结果")
        }
    }

    // MARK: - 路径 1：SearchTyping 页粘贴空文本（openSearchTyping 只在首页入口导航，这里不出新结果）

    func testEmptyPasteOnSearchTypingClearsUnrecognizedCard() async throws {
        for empty in [nil, ""] as [String?] {
            let fixture = make()
            let search = openSearchTyping(fixture)
            let old = try showUnrecognized(fixture, entry: ManualPasteAction.entrySearchTyping)
            XCTAssertEqual(old.origin, search.id.uuidString, "前置：① 卡挂在 SearchTyping 上")
            fixture.clipboard.pasted(entry: ManualPasteAction.entrySearchTyping, text: empty)
            await settle()
            XCTAssertNil(fixture.clipboard.result, "SearchTyping 粘贴空文本（\(String(describing: empty))）：旧 ① 卡收起")
            XCTAssertEqual(fixture.routing.router.path.map(\.id), [search.id], "仍在本页，不导航")
            XCTAssertEqual(fixture.api.sent, 0)
        }
    }

    func testEmptyPasteOnSearchTypingClearsNetworkFailedCard() async throws {
        let fixture = make()
        _ = openSearchTyping(fixture)
        _ = try await showNetworkFailed(fixture, entry: ManualPasteAction.entrySearchTyping)
        fixture.clipboard.pasted(entry: ManualPasteAction.entrySearchTyping, text: nil)
        await settle()
        XCTAssertNil(fixture.clipboard.result, "SearchTyping 粘贴空文本：旧 ⑤ 卡收起（连同留在结果里的上传片段）")
        XCTAssertEqual(fixture.api.sent, 1, "空文本不发 parse")
    }

    // MARK: - 路径 2：已登录粘贴纯邀请码（G01 静默）/ App 自写的邀请内容（none）

    func testLoggedInPureInvitePasteClearsCards() async throws {
        for entry in [ManualPasteAction.entryHome, ManualPasteAction.entrySearchTyping] {
            let fixture = make()
            fixture.state.guest = false
            if entry == ManualPasteAction.entrySearchTyping {
                _ = openSearchTyping(fixture)
            }
            _ = try showUnrecognized(fixture, entry: entry)
            fixture.clipboard.pasted(entry: entry, text: invite)
            await settle()
            XCTAssertNil(fixture.clipboard.result, "\(entry)：已登录粘贴纯邀请码，旧 ① 卡收起")
            XCTAssertEqual(fixture.api.sent, 0, "纯邀请不上传 parse")
        }
    }

    func testLoggedInPureInvitePasteClearsNetworkFailedCard() async throws {
        let fixture = make()
        fixture.state.guest = false
        _ = try await showNetworkFailed(fixture, entry: ManualPasteAction.entryHome)
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: invite)
        await settle()
        XCTAssertNil(fixture.clipboard.result, "已登录粘贴纯邀请码：旧 ⑤ 卡收起")
    }

    func testSelfWrittenInvitePasteClearsCard() async throws {
        let fixture = make()
        XCTAssertTrue(fixture.clipboard.ledger.record(invite), "前置：这段邀请内容是本 App 写入的")
        _ = try showUnrecognized(fixture, entry: ManualPasteAction.entryHome)
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: invite)
        await settle()
        XCTAssertNil(fixture.clipboard.result, "粘贴本 App 自写的邀请内容（none）：旧 ① 卡收起")
    }

    // MARK: - 路径 3：parse 被丢弃（dropped）

    func testDroppedParseClearsNetworkFailedCard() async throws {
        let fixture = make()
        _ = try await showNetworkFailed(fixture, entry: ManualPasteAction.entryHome)
        fixture.api.enqueue(Self.dropped())
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await waitParses(fixture, sent: 2)
        XCTAssertEqual(fixture.api.sent, 2, "前置：第二次粘贴发出了 parse")
        XCTAssertNil(fixture.clipboard.result, "parse 被丢弃：不出新结果，旧 ⑤ 卡也收起")
    }

    func testDroppedParseClearsUnrecognizedCardOnSearchTyping() async throws {
        let fixture = make()
        _ = openSearchTyping(fixture)
        _ = try showUnrecognized(fixture, entry: ManualPasteAction.entrySearchTyping)
        fixture.api.enqueue(Self.dropped())
        fixture.clipboard.pasted(entry: ManualPasteAction.entrySearchTyping, text: link)
        await waitParses(fixture, sent: 1)
        XCTAssertEqual(fixture.api.sent, 1)
        XCTAssertNil(fixture.clipboard.result, "SearchTyping 上 parse 被丢弃：旧 ① 卡收起")
    }

    // MARK: - 新 parse 在途期间

    func testOldCardGoneWhileNewParseInFlight() async throws {
        let fixture = make()
        _ = try await showNetworkFailed(fixture, entry: ManualPasteAction.entryHome)
        fixture.api.hold()
        fixture.api.enqueue(Self.card())
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await waitParses(fixture, sent: 2, settled: false)
        XCTAssertTrue(fixture.clipboard.busy, "前置：新 parse 在途")
        XCTAssertNil(fixture.clipboard.result, "新 parse 在途：旧 ⑤ 卡不再显示")
        fixture.api.release()
        await waitParses(fixture, sent: 2)
        XCTAssertEqual(fixture.routing.router.path.last?.route, AppClipboard.productDetailRoute, "新结果照常（1 张卡开详情）")
    }

    // MARK: - 基线

    /// 限流时点粘贴不算开始一次粘贴：执行层拦下、不读剪贴板，只出限流轻提示（共性第 6 条，修改后不能丢）。
    func testBlockedPasteDoesNotRead() async {
        let fixture = make()
        fixture.api.enqueue(businessFailure(42901, kind: .disableButton, disableMillis: 60000))
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await waitParses(fixture, sent: 1)
        let reads = fixture.clipboard.readCount
        XCTAssertNil(fixture.clipboard.beginPaste(entry: ManualPasteAction.entryHome), "限流：这次点击不读")
        XCTAssertEqual(fixture.clipboard.readCount, reads)
        XCTAssertEqual(Self.name(fixture.clipboard.result), "notice")
    }
}
