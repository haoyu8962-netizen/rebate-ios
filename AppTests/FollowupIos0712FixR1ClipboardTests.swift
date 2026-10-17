@testable import Clipboard
@testable import Couli
import CouliNetwork
import Foundation
import XCTest

/// FU-IOS-0712 第 1 轮修复 R1-03：剪贴板识别的整体失败响应 10405，服务（ParseInputService）到页面（AppClipboard 的结果提示）的对照。
/// 整体非强更 10405（refresh_only、刷新暂时失败的通用错误 Effect、刷新被拒的清会话 Effect）→ 统一错误文案（error.50001）+ trace6，
/// 不进强更、不启动禁用期，再次粘贴照常重新识别；整体强更 10405 → 执行层进强更（带最低版本）；行内 10405 照旧主动进强更。
extension ClipboardWiringTests {
    private static let trace6 = "1a2b3c"

    /// 主线程轮询等到条件成立（上限 5 秒只用来判失败；不用固定轮次的 yield）。
    private func until(_ what: String, _ condition: () -> Bool) async {
        await waitUntil(what) { condition() }
    }

    func testWholeNonForced10405ShowsUnifiedErrorWithTrace6AndCanRetry() async throws {
        for kind in [ErrorEffectKind.refreshOnly, .genericError, .clearSessionLogin] {
            let fixture = make()
            fixture.clipboard.sceneActive()
            fixture.api.reply = .whole(code: 10405, kind: kind)
            fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
            await until("\(kind)：结果提示") { fixture.clipboard.result != nil }
            guard case let .notice(text) = try XCTUnwrap(fixture.clipboard.result, "\(kind)：有结果提示").kind else {
                return XCTFail("\(kind)：应为轻提示")
            }
            XCTAssertEqual(
                text,
                ClipboardDraftTexts.error("error.50001", traceId: "trace-00001a2b3c"),
                "\(kind)：统一错误文案"
            )
            XCTAssertTrue(text.contains(Self.trace6), "\(kind)：带 trace6")
            XCTAssertNotEqual(text, ClipboardDraftTexts.error("error.10405", traceId: nil), "\(kind)：不是版本文案")
            XCTAssertEqual(fixture.state.forced, 0, "\(kind)：不进强更")
            XCTAssertEqual(fixture.state.networkForced.count, 0, "\(kind)：不进强更")
            XCTAssertFalse(fixture.clipboard.blocked, "\(kind)：不启动禁用期")
            // 可重试：再次粘贴照常发出识别
            fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
            await until("\(kind)：再次识别") { fixture.api.bodies.count == 2 }
            XCTAssertEqual(fixture.api.bodies.count, 2, "\(kind)：再次粘贴重新识别")
        }
    }

    func testWholeForced10405StillEntersForceUpdateAndInlineStaysServerForced() async {
        let forced = make()
        forced.clipboard.sceneActive()
        forced.api.reply = .whole(code: 10405, kind: .forceUpdate)
        forced.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await until("真强更进强更") { !forced.state.networkForced.isEmpty }
        XCTAssertEqual(forced.state.networkForced, ["9.9.9"], "真强更：执行层进强更（带最低版本）")
        XCTAssertNil(forced.clipboard.result, "真强更不出错误提示")
        let inline = make()
        inline.clipboard.sceneActive()
        inline.api.reply = .inline(code: 10405)
        inline.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await until("行内 10405 进强更") { inline.state.forced == 1 }
        XCTAssertEqual(inline.state.forced, 1, "行内 10405 照旧主动进强更")
        XCTAssertEqual(inline.state.networkForced.count, 0)
    }

    /// 服务层：整体非强更 10405 在进按码分流表之前换成统一错误码。
    func testParseOutcomeConsumesNonForced10405BeforeTheCodeTable() throws {
        for kind in [ErrorEffectKind.refreshOnly, .genericError, .clearSessionLogin] {
            let outcome = ParseInputService.outcome(.failure(
                code: 10405, msg: "", data: nil, traceId: "trace-00001a2b3c",
                effect: ErrorEffect(code: 10405, kind: kind), idempotencyKey: nil
            ))
            let action = try XCTUnwrap(outcome.action)
            XCTAssertEqual(action.actionRaw, ParseResultAction.error, "\(kind)")
            XCTAssertEqual(action.textKey, "error.50001", "\(kind)")
            XCTAssertEqual(action.showTrace6, true, "\(kind)")
            XCTAssertFalse(action.networkForced, "\(kind)")
            XCTAssertFalse(action.inline, "\(kind)")
        }
        let forced = try XCTUnwrap(ParseInputService.outcome(.failure(
            code: 10405, msg: "", data: Data(#"{"min_supported_version":"9.9.9"}"#.utf8), traceId: "t",
            effect: ErrorEffect(code: 10405, kind: .forceUpdate), idempotencyKey: nil
        )).action)
        XCTAssertEqual(forced.actionRaw, ParseResultAction.forceUpdate)
        XCTAssertTrue(forced.networkForced)
        XCTAssertEqual(forced.minSupportedVersion, "9.9.9")
    }
}
