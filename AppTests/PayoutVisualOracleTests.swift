@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// 判据与宿主自证（底版绿）：宿主是真实组装、fixture 真到达执行器、圆形 / 粗环判据分得开。
@MainActor
final class PayoutVisualOracleTests: PayoutVisualTestCase {
    /// 收款账号页真实路由：五份报文都到达执行器，显示字段 = 报文。
    func testPayoutReachesController() async throws {
        let (unbound, _) = try await openPayout(needProbes: false)
        XCTAssertEqual(unbound.payout?.state.editing, true, "未绑定直接表单")
        let cases = [("boundAlipay", "138****5678"), ("boundBank", "尾号 1234"), ("boundExhausted", "138****5678")]
        for (name, masked) in cases {
            let (host, _) = try await openPayout(name, needProbes: false)
            XCTAssertEqual(host.payout?.state.account?.maskedAccount, masked, name)
            XCTAssertEqual(host.payout?.state.editing, false, name)
        }
        XCTAssertEqual(writes, [], "只读")
    }

    /// 实名 / 劳务的测试后端确实接在生产执行器上；没装时是 Release 形态（G-W24）。
    func testBackendsWired() async throws {
        let (real, _) = try await openRealName(needProbes: false)
        XCTAssertEqual(real.realName?.available, true)
        XCTAssertEqual(real.realName?.submitEnabled, true, "fixture 表单可提交")
        let (labor, _) = try await openLabor(needProbes: false)
        XCTAssertEqual(labor.laborPage?.state.version, "v1")
        XCTAssertEqual(labor.laborPage?.state.phase, .content)
        let (bare, _) = try await openLabor(backend: false, needProbes: false, phase: .unavailable)
        XCTAssertEqual(bare.laborPage?.state.phase, .unavailable)
    }

    /// 圆形判据：实心圆放行、圆角方块（底版 CheckMark 的形状）拦下。
    func testRoundJudge() async {
        let brand = pixel(CouliColor.brandPrimary, dark: false)
        let box = CGRect(x: 20, y: 20, width: 18, height: 18)
        func draw(_ shape: some View) async -> UIImage {
            let view = ZStack(alignment: .topLeading) {
                Color.white
                shape.frame(width: 18, height: 18).offset(x: 20, y: 20)
            }
            return await ProductVisualRender.standalone(view, size: CGSize(width: 80, height: 80)).0
        }
        let circle = await draw(Circle().fill(CouliColor.brandPrimary))
        XCTAssertTrue(PayoutVisualJudges.isRound(circle, box, fill: brand), "圆形应放行")
        let square = await draw(RoundedRectangle(cornerRadius: 4.5).fill(CouliColor.brandPrimary))
        XCTAssertFalse(PayoutVisualJudges.isRound(square, box, fill: brand), "圆角方块应拦下")
    }

    /// 粗环判据：描边 7 放行；底版 RadioMark（实心 + 小白点）与细环拦下。
    func testRingJudge() async {
        let brand = pixel(CouliColor.brandPrimary, dark: false)
        let white = pixel(CouliColor.backgroundSurface, dark: false)
        let box = CGRect(x: 20, y: 20, width: 24, height: 24)
        func draw(_ mark: some View) async -> UIImage {
            let view = ZStack(alignment: .topLeading) {
                Color.white
                mark.frame(width: 24, height: 24).offset(x: 20, y: 20)
            }
            return await ProductVisualRender.standalone(view, size: CGSize(width: 80, height: 80)).0
        }
        let ring = await draw(Circle().strokeBorder(CouliColor.brandPrimary, lineWidth: 7)
            .background(Circle().fill(CouliColor.backgroundSurface)))
        XCTAssertTrue(PayoutVisualJudges.isThickRing(ring, box, ring: brand, center: white), "描边 7 应放行")
        let thin = await draw(Circle().strokeBorder(CouliColor.brandPrimary, lineWidth: 2))
        XCTAssertFalse(PayoutVisualJudges.isThickRing(thin, box, ring: brand, center: white), "细环应拦下")
        let solid = await draw(ZStack {
            Circle().fill(CouliColor.brandPrimary)
            Circle().fill(.white).frame(width: 8, height: 8)
        })
        XCTAssertFalse(PayoutVisualJudges.isThickRing(solid, box, ring: brand, center: white), "实心 + 小白点（底版）应拦下")
    }
}
