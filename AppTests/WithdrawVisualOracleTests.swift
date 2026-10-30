@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// 判据 / 宿主自证（底版应全绿）：宿主真的走生产组装、visualWithdraw 数据真的到了执行器、配置注入生效且能区分「按配置取值」。
/// 这组红了说明后面的「缺实现」红因不可信。
@MainActor
final class WithdrawVisualOracleTests: WithdrawVisualTestCase {
    func testHostReachesProductionPageWithFixtureRules() async throws {
        let (host, image) = try await openWithdraw(needProbes: false)
        let state = try XCTUnwrap(host.controller?.state)
        XCTAssertEqual(state.rules?.withdrawableFen, 1234)
        XCTAssertEqual(state.rules?.maxWithdrawableFen, 1200)
        XCTAssertEqual(state.rules?.quickAmountsFen, [500, 1000])
        XCTAssertEqual(state.payout?.line(texts), "支付宝 138****5678")
        XCTAssertEqual(state.helpTarget?.params["article_id"], WithdrawVisualData.articleId, "配置注入走生产 AppConfig")
        XCTAssertEqual(host.fixture.router.path.last?.route, WalletRoutes.withdraw)
        XCTAssertEqual(WalletStubProtocol.requests("POST", "/v1/withdrawals").count, 0, "进页零写请求")
        let canvas = share(
            image,
            in: CGRect(x: 0, y: 10, width: 390, height: 40),
            near: pixel(CouliColor.backgroundCanvas, dark: false)
        )
        XCTAssertGreaterThan(canvas, 0.9, "真实页面画出了画布色")
    }

    /// 时效句：配置给了用配置；不给回落 BR-TEXT-07（两者不同，断言才区分得开，b v2 T1 教训）。
    func testSlaFollowsConfigOrFallback() async throws {
        let (fallback, _) = try await openWithdraw(needProbes: false)
        XCTAssertEqual(
            fallback.controller?.state.display(slaDefault: texts)?.slaText,
            texts.text("withdraw.sla_default")
        )
        let (configured, _) = try await openWithdraw(sla: "预计几分钟内到账", needProbes: false)
        XCTAssertEqual(configured.controller?.state.display(slaDefault: texts)?.slaText, "预计几分钟内到账")
    }

    /// 未配 help_links.withdraw_rules 时执行器没有目标（G26）。
    func testHelpTargetAbsentWithoutConfig() async throws {
        let (host, _) = try await openWithdraw(help: false, needProbes: false)
        XCTAssertNil(host.controller?.state.helpTarget)
    }

    /// v2 / T3 判据自证：全黑、纯白判红，超过渲染上限判红；真实页面（深色、最暗的画布）放行。
    func testRenderJudgeRejectsBlankImages() async throws {
        func solid(_ color: UIColor, height: CGFloat) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            return UIGraphicsImageRenderer(size: CGSize(width: 320, height: height), format: format).image {
                color.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 320, height: height))
            }
        }
        XCTAssertFalse(WithdrawVisualRenderJudge.problems(solid(.black, height: 844)).isEmpty, "全黑判红")
        XCTAssertFalse(WithdrawVisualRenderJudge.problems(solid(.white, height: 844)).isEmpty, "纯白判红")
        XCTAssertFalse(WithdrawVisualRenderJudge.problems(solid(.black, height: 2800)).isEmpty, "超限判红")
        let (_, image) = try await openWithdraw(canvas: .init(dark: true), needProbes: false)
        XCTAssertEqual(WithdrawVisualRenderJudge.problems(image), [], "真实深色页面放行")
    }

    /// 全部 PageStates 规则名都有报文，经生产解析进入执行器。
    func testPageStatesAllReachController() async throws {
        for name in try WithdrawVisualData.pageStates() {
            let (host, _) = try await openWithdraw(name, needProbes: false)
            XCTAssertEqual(host.controller?.state.rules?.canWithdraw, false, name)
            XCTAssertEqual(WithdrawVisualFixtureCheck.code(name), host.controller?.state.rules?.blockCode, name)
        }
    }
}

enum WithdrawVisualFixtureCheck {
    static func code(_ name: String) -> Int? {
        let tail = name.replacingOccurrences(of: "blocked_", with: "")
        return Int(tail) ?? 30303
    }
}
