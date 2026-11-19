import ClientCore
import CouliNetwork
import Foundation
import Generated
@testable import MeCore
import WalletCore
import XCTest

/// APP-13a-1-ios 写测 r4（独立写测方）：首轮评审补的执行器用例（底座与夹具同 App13a1DeleteAccountControllerTests）。
///
/// - S2-1：撤回结果未知 → 核对读取查明已撤回（cancelled, cancel_reason=user）走同一成功结算：「暂时没有收到结果」提示清掉，
///   与直接成功同一结局（共性第 14、33 条）；
/// - S3-4：受限会话（deletion_only）只发 BR-ID-01 受限表内的操作：申请结局带共用引导路由（绑手机号 / 实名 / 收款账号）时不导航，
///   只留结局提示；full 会话照常打开引导页（对照）。
@MainActor
final class App13a1DeleteAccountReviewTests: App13a1ControllerTestCase {
    private func coolingPage(source: DeletionSource) async -> App13a1ControllerFixture {
        let fixture = make(source: source)
        fixture.api.on("getDeletion", App13a1Replies.ok(App13a1Replies.cooling(true)))
        await open(fixture)
        XCTAssertTrue(fixture.controller.view.showCancel, "前提：\(source.rawValue) 冷静期可撤回")
        return fixture
    }

    // MARK: - S2-1 撤回未知后核对查明已撤回

    /// 其他来源、风险提示来源：撤回无响应 → 先显示「暂时没有收到结果」→ 核对读到 cancelled(user) → 提示清掉、回初始态、
    /// 本页轻提示「已撤回」（与直接成功同一结局）；不离页、不自动重发撤回。
    func testCancelUnknownReconciledClearsUnknownNotice() async {
        for source in [DeletionSource.other, .riskNotice] {
            let label = source.rawValue
            let fixture = await coolingPage(source: source)
            fixture.api.on("cancelDeletion", App13a1Replies.transport)
            fixture.api.hold("getDeletion")
            cancel(fixture)
            await waitFor("\(label)：撤回未知后没有发核对读取") { fixture.api.heldCount("getDeletion") == 1 }
            XCTAssertEqual(fixture.controller.state.notice?.key, DeletionCancelOutcome.unknownKey,
                           "\(label)：前提：核对返回前显示「暂时没有收到结果」")

            fixture.api.release("getDeletion", App13a1Replies.ok(App13a1Replies.cancelled))
            await waitFor("\(label)：核对后没有轻提示") { fixture.controller.state.toast != nil }
            await fixture.idle()
            XCTAssertNil(fixture.controller.state.notice, "\(label)：核对查明已撤回：清掉结果未知提示（S2-1）")
            XCTAssertEqual(fixture.controller.view.kind, .initial, "\(label)：回到初始态")
            XCTAssertEqual(fixture.controller.state.toast?.key, DeletionCancelOutcome.withdrawnKey, "\(label)：已撤回轻提示")
            XCTAssertEqual(fixture.ports.toSettings + fixture.ports.toForceUpdate, 0, "\(label)：不离页")
            XCTAssertEqual(fixture.api.calls("cancelDeletion").count, 1, "\(label)：不自动重发撤回")
        }
    }

    // MARK: - S3-4 受限会话不导航共用引导

    private struct GuideCase {
        let code: Int
        let data: String?
        let route: String
    }

    private let guideCases = [
        GuideCase(code: 10005, data: nil, route: WalletRoutes.bindPhone),
        GuideCase(code: 10004, data: "{\"consent_type\":\"id_verification\"}", route: WalletRoutes.realName),
        GuideCase(code: 30304, data: nil, route: WalletRoutes.realName),
        GuideCase(code: 30307, data: nil, route: WalletRoutes.payoutAccount),
    ]

    private func applyWithGuide(_ item: GuideCase, scope: String, source: DeletionSource) async
        -> App13a1ControllerFixture {
        let fixture = make(scope: scope, source: source)
        fixture.api.on("requestDeletion", App13a1Replies.fail(item.code, data: item.data))
        await open(fixture)
        check(fixture)
        apply(fixture)
        await waitFor("\(scope) / \(item.code)：结局没有落到页面") {
            fixture.controller.flow.state.error?.key == "error.\(item.code)"
        }
        await fixture.idle()
        return fixture
    }

    /// deletion_only（从强更进入）：10005 / 10004 / 30304 / 30307 的共用引导一律不打开页面（受限表外），结局提示照留。
    func testRestrictedSessionDoesNotOpenGuideRoutes() async {
        for item in guideCases {
            let fixture = await applyWithGuide(item, scope: DeletionScope.deletionOnly, source: .forceUpdate)
            await quiet()
            XCTAssertTrue(fixture.ports.opened.isEmpty, "deletion_only / \(item.code)：不导航 \(fixture.ports.opened)")
            XCTAssertEqual(fixture.api.calls("requestDeletion").count, 1, "deletion_only / \(item.code)：不重放")
        }
    }

    /// 对照：full（从设置进入）同一结局照常打开对应引导页（只开一次）。
    func testFullSessionOpensGuideRoutes() async {
        for item in guideCases {
            let fixture = await applyWithGuide(item, scope: DeletionScope.full, source: .settings)
            await waitFor("full / \(item.code)：没有打开引导页") { !fixture.ports.opened.isEmpty }
            XCTAssertEqual(fixture.ports.opened, [item.route], "full / \(item.code)：打开 \(item.route)")
        }
    }
}
