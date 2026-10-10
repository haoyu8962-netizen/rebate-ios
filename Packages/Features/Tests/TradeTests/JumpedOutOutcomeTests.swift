import CouliNetwork
import Foundation
@testable import Trade
import XCTest

/// APP-08 iOS 第 1 轮评审 R1-04（共性第 33 条，BR-ATTR-21）：凡是成功外跳的结局（拉起 App、交浏览器、复制口令，含「平台未安装但
/// 口令已复制」）都触发 `onJumpedOut`，发起页回到前台后才会去拉待跟单卡；没有任何一步成功时不触发。
@MainActor
final class JumpedOutOutcomeTests: XCTestCase {
    private final class Jumps {
        var platforms: [String] = []
        var origins: [String?] = []
        var originReads = 0
    }

    private func run(
        installed: String, launch: [Bool], steps: [TradeObject], card: TradeObject = TradeFixtures.card()
    ) async -> (PurchaseHarness, Jumps) {
        let rig = PurchaseHarness(card: card)
        let jumps = Jumps()
        // 来源不变（同一会话、同一环境、同一 slot）；比较时会再读，交付的必须是获取方案时固定的那一份
        rig.controller.jumpOrigin = {
            jumps.originReads += 1
            return "origin-A"
        }
        rig.controller.onJumpedOut = { platform, origin in
            jumps.platforms.append(platform)
            jumps.origins.append(origin)
        }
        rig.ports.installedValue = installed
        rig.ports.launchResults = launch
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(steps: steps)))
        return (rig, jumps)
    }

    private static let schemeThenCopy: [TradeObject] = [
        ["type": "scheme", "value": "app://x"], ["type": "copy_tpwd", "value": "￥tpwd￥"],
    ]

    /// 原缺陷：明确未安装、拉起失败、口令复制成功 → finalNotInstalled，只显示安装提示、没有回调。
    func testNotInstalledButCopiedCountsAsJumpedOut() async {
        let (rig, jumps) = await run(
            installed: TradeConstants.installedFalse,
            launch: [false],
            steps: Self.schemeThenCopy
        )
        await eventually { rig.controller.state.notInstalled }
        XCTAssertEqual(rig.ports.copied, ["￥tpwd￥"])
        XCTAssertEqual(rig.controller.state.toast?.key, PurchaseTextKeys.notInstalledCopied, "安装提示照旧")
        XCTAssertEqual(jumps.platforms, ["taobao"], "已复制口令算成功外跳：回前台后拉待跟单卡")
    }

    func testCopiedWithUnknownInstallCountsAsJumpedOut() async {
        let (rig, jumps) = await run(installed: TradeConstants.installedUnknown, launch: [false],
                                     steps: Self.schemeThenCopy)
        await eventually { rig.controller.state.toast?.key == PurchaseTextKeys.copied }
        XCTAssertEqual(jumps.platforms, ["taobao"])
    }

    func testOpenedAppCountsAsJumpedOut() async {
        let (rig, jumps) = await run(
            installed: TradeConstants.installedUnknown, launch: [true], steps: [["type": "scheme", "value": "app://x"]],
            card: TradeFixtures.card(key: "jd:cup", platform: "jd")
        )
        await eventually { !rig.ports.launched.isEmpty }
        await eventually { !jumps.platforms.isEmpty }
        XCTAssertEqual(jumps.platforms, ["jd"])
    }

    /// 没有任何一步成功（明确未安装、只有拉起步骤且失败）：不算外跳，不触发。
    func testAllStepsFailedIsNotJumpedOut() async {
        let (rig, jumps) = await run(
            installed: TradeConstants.installedFalse, launch: [false], steps: [["type": "scheme", "value": "app://x"]]
        )
        await eventually { rig.controller.state.notInstalled }
        XCTAssertTrue(rig.ports.copied.isEmpty)
        XCTAssertTrue(jumps.platforms.isEmpty, "没有外跳：不拉待跟单卡")
    }

    /// iOS RC-06（第三次窄修改口径）：来源在发起获取跳转方案（发 open）时固定，随方案与完成事件原样交付；之后的读取只用于比较。
    func testJumpOriginFixedAtPlanFetchAndDelivered() async {
        let (rig, jumps) = await run(
            installed: TradeConstants.installedUnknown, launch: [true], steps: [["type": "scheme", "value": "app://x"]],
            card: TradeFixtures.card(key: "jd:cup", platform: "jd")
        )
        await eventually { !jumps.platforms.isEmpty }
        XCTAssertFalse(rig.ports.launched.isEmpty)
        XCTAssertGreaterThanOrEqual(jumps.originReads, 1)
        XCTAssertEqual(jumps.origins, ["origin-A"], "完成事件带获取方案时固定的来源")
    }
}
