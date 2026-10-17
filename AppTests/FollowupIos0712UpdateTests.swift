import CouliNetwork
import Foundation
import MeCore
@testable import OrderCore
import ProductSearch
import Trade
import WalletCore
import XCTest

/// FU-IOS-0712 第 4 项（F-X-09）：非强更的 10405（网络层 Effect 为 refresh_only）在各页面落点按「统一错误文案 error.50001 + trace6 + 可重试、
/// 不进强更」；Effect 为 force_update 的照旧进强更。对照用例：同一码、两种 Effect。
@MainActor
final class FollowupIos0712UpdateTests: XCTestCase {
    private static let trace = "trace-0000-a1b2c3"

    private static func failure(_ kind: ErrorEffectKind) -> ApiResult {
        .failure(
            code: 10405, msg: "", data: Data("{}".utf8), traceId: trace,
            effect: ErrorEffect(code: 10405, kind: kind), idempotencyKey: "key-1"
        )
    }

    private let refreshOnly = failure(.refreshOnly)
    private let forced = failure(.forceUpdate)

    func testHelperOnlyTreatsForceUpdateEffectAsForced() {
        XCTAssertTrue(NonForcedUpdate.applies(code: 10405, effect: ErrorEffect(code: 10405, kind: .refreshOnly)))
        XCTAssertFalse(NonForcedUpdate.applies(code: 10405, effect: ErrorEffect(code: 10405, kind: .forceUpdate)))
        XCTAssertEqual(
            NonForcedUpdate.pageCode(code: 10405, effect: ErrorEffect(code: 10405, kind: .refreshOnly)),
            50001
        )
        XCTAssertEqual(
            NonForcedUpdate.pageCode(code: 42901, effect: ErrorEffect(code: 42901, kind: .disableButton)),
            42901
        )
    }

    /// 钱包 / 我的 / 设置 / 隐私中心 / 实名 / 收款账号 / 提现记录 / 二次验证的读写失败都经 WalletErrors（我的经 MeErrors 复用）。
    func testWalletAndMeReadsShowUnifiedErrorWithTrace6NotForceUpdate() {
        let error = WalletErrors.of(refreshOnly)
        XCTAssertEqual(error.kind, .server, "可重试的服务端错误，不进强更")
        XCTAssertEqual(error.textKey, "error.50001")
        XCTAssertTrue(error.showTrace6)
        XCTAssertEqual(error.traceId, Self.trace)
        XCTAssertEqual(MeErrors.of(refreshOnly).kind, .server)
        XCTAssertEqual(WalletErrors.of(forced).kind, .forceUpdate, "强更照旧")
        XCTAssertEqual(WalletErrors.of(forced).textKey, "error.10405")
    }

    /// 钱包敏感写（结局表三端共用、不改）：首次提交按统一错误 + trace6、键结束可再提交；确认 / 放弃保留待确认「稍后再试」。
    func testWalletSensitiveWritesUseUnifiedErrorAndRetryLater() {
        let input = WalletErrors.outcomeInput(refreshOnly)
        XCTAssertEqual(input.code, 50001)
        let submit = SensitiveOutcome.of(op: SensitiveOutcome.withdraw, phase: SensitiveOutcome.submit,
                                         keyEverUnknown: false, input: input)
        XCTAssertEqual(submit.textKey, "error.50001")
        XCTAssertTrue(submit.showTrace6)
        XCTAssertTrue(submit.keyEnds, "可重试（再点用新键）")
        XCTAssertNotEqual(submit.actionRaw, SensitiveOutcome.forceUpdate)
        let confirm = SensitiveOutcome.of(op: SensitiveOutcome.withdraw, phase: SensitiveOutcome.confirm,
                                          keyEverUnknown: true, input: input)
        XCTAssertEqual(confirm.textKey, SensitiveOutcome.retryLaterKey)
        XCTAssertFalse(confirm.keyEnds, "保留待确认")
        XCTAssertEqual(WalletErrors.outcomeInput(forced).code, 10405)
        XCTAssertEqual(
            SensitiveOutcome.of(op: SensitiveOutcome.withdraw, phase: SensitiveOutcome.submit, keyEverUnknown: false,
                                input: WalletErrors.outcomeInput(forced)).actionRaw,
            SensitiveOutcome.forceUpdate
        )
    }

    /// 我的：昵称 / 申诉等写操作的结果输入。
    func testMeWriteInputUsesUnifiedServerCode() {
        XCTAssertEqual(MeResultInput.of(refreshOnly)["code"] as? Int, 50001)
        XCTAssertEqual(MeResultInput.of(forced)["code"] as? Int, 10405)
    }

    /// 订单列表首屏 / 翻页 / 详情、待跟单关闭。
    func testOrdersUseUnifiedErrorWithTrace6AndRetry() {
        for target in [OrderErrorAction.listFirst, OrderErrorAction.listNext, OrderErrorAction.detail] {
            let view = OrderErrorAction.view(target: target, result: refreshOnly, hasCache: true, filtered: false)
            XCTAssertNotEqual(view.actionRaw, OrderErrorKind.forceUpdate, target)
            XCTAssertNotEqual(view.actionRaw, OrderErrorKind.showStale, "\(target)：不用缓存冒充")
            XCTAssertEqual(view.textKey, "error.50001", target)
            XCTAssertTrue(view.showTrace6, target)
            XCTAssertEqual(view.traceId, Self.trace, target)
            XCTAssertEqual(
                OrderErrorAction.view(target: target, result: forced, hasCache: true, filtered: false).actionRaw,
                OrderErrorKind.forceUpdate, "\(target)：强更照旧"
            )
        }
        XCTAssertEqual(PendingTrackService.dismissAction(refreshOnly)?.0, PendingDismissAction.errorToast)
        XCTAssertEqual(PendingTrackService.dismissAction(forced)?.0, PendingDismissAction.forceUpdate)
    }

    /// 搜索首屏 / 翻页、商品详情（都经 SearchResults.envelope → SearchResultState）。
    func testSearchAndProductDetailShowUnifiedErrorNotVersionText() throws {
        let view = SearchResultState.map(try XCTUnwrap(SearchResults.envelope(refreshOnly)))
        XCTAssertEqual(view.textKey, "error.50001")
        XCTAssertEqual(view.traceId, Self.trace)
        XCTAssertEqual(SearchResultState.map(try XCTUnwrap(SearchResults.envelope(forced))).textKey, "error.10405")
    }

    /// 购买 open / 授权管理（open 错误表三端共用、不改；交表前换码）。
    func testTradeOpenUsesUnifiedServerErrorNotForceUpdate() {
        let code = NonForcedUpdate.pageCode(code: 10405, effect: ErrorEffect(code: 10405, kind: .refreshOnly))
        let outcome = OpenErrorAction.map(code: code, data: [:])
        XCTAssertNotEqual(outcome.actionRaw, OpenErrorActions.forceUpdate)
        XCTAssertTrue(outcome.showTrace6)
        XCTAssertEqual(OpenErrorAction.map(code: 10405, data: [:]).actionRaw, OpenErrorActions.forceUpdate)
    }
}
