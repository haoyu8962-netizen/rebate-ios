import Clipboard
@testable import Couli
import CouliNetwork
import Foundation
import XCTest

/// FU-IOS-0730 第 1 条（评审 APP-11v-b-ios r1 S2-1；主线裁定：⑤【重试】只对网络失败）：
/// 【重试】（结果种类 `.networkFailed`）只在网络层明确的传输失败（超时 / 断连 / 无网）时出现；服务端成功返回但结果为空、
/// 业务错误码都不出【重试】，按既有对应状态显示（空结果 = 统一错误 error.50001 轻提示，有 trace 带末 6 位；业务码按码分流）。
/// 只经生产入口：首页 / SearchTyping 的 `pasted`（点击 + 交付）、⑤ 卡按钮的 `retryParse`，读界面结果 `result`。
final class FollowupIos0730RetryTests: FollowupIos0730TestCase {
    // MARK: - 传输失败：出【重试】

    func testTimeoutShowsRetryCard() async {
        let fixture = make()
        fixture.api.enqueue(Self.timeout())
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await waitParses(fixture, sent: 1)
        XCTAssertEqual(Self.name(fixture.clipboard.result), "networkFailed", "超时：⑤ 卡带【重试】")
        XCTAssertEqual(
            Self.text(fixture.clipboard.result),
            ClipboardDraftTexts.error(ParseResultAction.genericErrorKey, traceId: nil),
            "⑤ 文案沿用统一错误，没有 trace"
        )
    }

    func testDisconnectAndOfflineShowRetryCardOnBothEntries() async {
        for entry in [ManualPasteAction.entryHome, ManualPasteAction.entrySearchTyping] {
            let fixture = make()
            if entry == ManualPasteAction.entrySearchTyping {
                _ = openSearchTyping(fixture)
            }
            fixture.api.enqueue(Self.disconnect())
            fixture.clipboard.pasted(entry: entry, text: link)
            await waitParses(fixture, sent: 1)
            XCTAssertEqual(Self.name(fixture.clipboard.result), "networkFailed", "断连 / 无网（\(entry)）：⑤ 卡带【重试】")
        }
    }

    /// 【重试】用本次片段再发一次；再次传输失败仍是 ⑤（基线，修改后不能丢）。
    func testRetryAfterTransportFailureResendsAndCanFailAgain() async throws {
        let fixture = make()
        let first = try await showNetworkFailed(fixture, entry: ManualPasteAction.entryHome)
        fixture.api.enqueue(Self.disconnect())
        fixture.clipboard.retryParse(first.id)
        await waitParses(fixture, sent: 2)
        XCTAssertEqual(fixture.api.sent, 2, "【重试】再发一次 parse")
        XCTAssertEqual(Self.name(fixture.clipboard.result), "networkFailed")
    }

    // MARK: - 服务端成功但结果为空：不出【重试】，按统一错误轻提示

    func testEmptyResultsWithTraceIsGenericNoticeWithoutRetry() async throws {
        let fixture = make()
        fixture.api.enqueue(Self.success(#"{"results":[]}"#, trace: trace))
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await waitParses(fixture, sent: 1)
        XCTAssertEqual(Self.name(fixture.clipboard.result), "notice", "成功但结果为空：不是网络失败，不出【重试】（S2-1）")
        XCTAssertEqual(
            Self.text(fixture.clipboard.result),
            ClipboardDraftTexts.error(ParseResultAction.genericErrorKey, traceId: trace),
            "按既有状态：error.50001，带本次 trace 末 6 位"
        )
        let shown = try XCTUnwrap(fixture.clipboard.result)
        fixture.clipboard.retryParse(shown.id)
        XCTAssertEqual(fixture.clipboard.parseCount, 1, "空结果上没有可用的【重试】，执行层不发起 parse")
        await settle()
        XCTAssertEqual(fixture.api.sent, 1, "空结果上没有可用的【重试】，不再发 parse")
    }

    /// 成功外壳没有 trace（traceId 为 nil）时，空结果在字段上和传输失败长得一样（errorCode、traceId 都是 nil，showTrace6 = false）：
    /// 只能靠网络层的「传输失败」来区分，不能靠「没有码、没有 trace」去猜（评审 S2-1 的退路方案在这里不成立）。
    func testEmptyResultsWithoutTraceIsStillNoticeWithoutRetry() async {
        let fixture = make()
        fixture.api.enqueue(Self.success(#"{"results":[]}"#, trace: nil))
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await waitParses(fixture, sent: 1)
        XCTAssertEqual(Self.name(fixture.clipboard.result), "notice", "无 trace 的空结果也不出【重试】")
        XCTAssertEqual(
            Self.text(fixture.clipboard.result),
            ClipboardDraftTexts.error(ParseResultAction.genericErrorKey, traceId: nil)
        )
    }

    /// 结果全部被过滤（行里既没有 card 也没有 error_code）、data 缺失、data 不是对象：都按空结果，不出【重试】。
    func testFilteredOrMissingResultsAreNoticeWithoutRetry() async {
        let payloads: [(String, String?)] = [
            ("全部被过滤", #"{"results":[{"hit":{"raw":"x"}},{}]}"#),
            ("没有 results", #"{}"#),
            ("data 为空", nil),
            ("data 不是对象", #"[1,2]"#),
        ]
        for (label, json) in payloads {
            let fixture = make()
            fixture.api.enqueue(Self.success(json, trace: trace))
            fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
            await waitParses(fixture, sent: 1)
            XCTAssertEqual(Self.name(fixture.clipboard.result), "notice", "\(label)：不出【重试】")
            XCTAssertEqual(
                Self.text(fixture.clipboard.result),
                ClipboardDraftTexts.error(ParseResultAction.genericErrorKey, traceId: trace),
                "\(label)：统一错误带 trace6"
            )
        }
    }

    /// SearchTyping 入口同一口径。
    func testEmptyResultsOnSearchTypingIsNoticeWithoutRetry() async {
        let fixture = make()
        _ = openSearchTyping(fixture)
        fixture.api.enqueue(Self.success(#"{"results":[]}"#, trace: trace))
        fixture.clipboard.pasted(entry: ManualPasteAction.entrySearchTyping, text: link)
        await waitParses(fixture, sent: 1)
        XCTAssertEqual(Self.name(fixture.clipboard.result), "notice", "SearchTyping 上的空结果也不出【重试】")
    }

    /// ⑤ 上点【重试】，这次服务端成功但结果为空：换成统一错误轻提示，不再带【重试】。
    func testRetryThatReturnsEmptyResultsBecomesNotice() async throws {
        let fixture = make()
        let first = try await showNetworkFailed(fixture, entry: ManualPasteAction.entryHome)
        fixture.api.enqueue(Self.success(#"{"results":[]}"#, trace: trace))
        fixture.clipboard.retryParse(first.id)
        await waitParses(fixture, sent: 2)
        XCTAssertEqual(Self.name(fixture.clipboard.result), "notice", "重试得到空结果：不再出【重试】")
    }

    struct Case {
        let label: String
        let answer: ApiResult
        let expected: String
    }

    // MARK: - 业务错误码：不出【重试】，按码分流（基线，修改后不能丢）

    func testBusinessErrorCodesNeverShowRetry() async {
        let cases: [Case] = [
            Case(label: "整体 50001", answer: businessFailure(50001), expected: "notice"),
            Case(label: "整体 50300", answer: businessFailure(50300), expected: "notice"),
            Case(label: "整体 30131", answer: businessFailure(30131), expected: "notice"),
            Case(label: "整体 30141", answer: businessFailure(30141), expected: "notice"),
            Case(label: "整体 30132", answer: businessFailure(30132), expected: "unrecognized"),
            Case(label: "整体非强更 10405", answer: businessFailure(10405, kind: .refreshOnly), expected: "notice"),
            Case(label: "行内 50001", answer: Self.success(#"{"results":[{"error_code":50001}]}"#, trace: trace),
                 expected: "notice"),
            Case(label: "行内 30131", answer: Self.success(#"{"results":[{"error_code":30131}]}"#, trace: trace),
                 expected: "notice"),
        ]
        for item in cases {
            let fixture = make()
            fixture.api.enqueue(item.answer)
            fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
            await waitParses(fixture, sent: 1)
            XCTAssertEqual(Self.name(fixture.clipboard.result), item.expected, "\(item.label)：按码分流，不出【重试】")
        }
    }

    func testServerErrorNoticeKeepsTrace6() async {
        let fixture = make()
        fixture.api.enqueue(businessFailure(50001))
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await waitParses(fixture, sent: 1)
        XCTAssertEqual(
            Self.text(fixture.clipboard.result),
            ClipboardDraftTexts.error("error.50001", traceId: trace),
            "5xxxx 轻提示带 trace 末 6 位"
        )
    }

    func testRateLimitedIsNoticeAndBlocksWithoutRetry() async {
        let fixture = make()
        fixture.api.enqueue(businessFailure(42901, kind: .disableButton, disableMillis: 60000))
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await waitParses(fixture, sent: 1)
        XCTAssertEqual(Self.name(fixture.clipboard.result), "notice", "42901：限流轻提示，不出【重试】")
        XCTAssertTrue(fixture.clipboard.blocked)
    }
}
