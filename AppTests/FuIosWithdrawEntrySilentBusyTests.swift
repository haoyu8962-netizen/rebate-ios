@testable import Couli
import Foundation
import Router
import Wallet
import WalletCore
import XCTest

/// FU-IOS-WITHDRAW-ENTRY-SILENT brief §3 第 6 条：实名查询在途时【提现】显示进行中（防连点，不像没反应）。依赖实现方在
/// `WalletPageContext` 新增的 `@Published isOpeningWithdraw: Bool`（74b66f3 上没有，本文件编译不过；先红只跑
/// FuIosWithdrawEntrySilentTests）。
/// 每种结局（进 RealName、读取失败、被覆盖丢弃）都要求：点击前为假、查询挂起时为真、查询结束后为假（不留下永远转圈的按钮）。
final class FuIosWithdrawEntrySilentBusyTests: FuIosWithdrawEntrySilentTestCase {
    /// 结果到达、经守卫进 RealName：结束后为假。
    func testBusyWhileQueryInFlightThenClearsOnNavigation() async throws {
        let opened = try await tapAndHold("第 6 条·进 RealName")
        let held = try await heldMe(opened, "第 6 条·进 RealName")
        assertBusy(opened, true, "第 6 条·进 RealName：查询挂起时")
        release(held, with: Self.unverified)
        await waitUntil("第 6 条·进 RealName：没有进 RealName") { top(opened) == WalletRoutes.realName }
        await settle()
        assertBusy(opened, false, "第 6 条·进 RealName：查询结束后")
    }

    /// 读取失败（5xxxx）、发起页显示 openError：结束后为假。
    func testBusyClearsWhenQueryFails() async throws {
        let opened = try await tapAndHold("第 6 条·读取失败")
        let held = try await heldMe(opened, "第 6 条·读取失败")
        assertBusy(opened, true, "第 6 条·读取失败：查询挂起时")
        release(held, with: .envelope(code: 50001, data: "null", headers: [:]))
        await waitUntil("第 6 条·读取失败：发起页没有 openError") { opened.entry.context.openError != nil }
        await settle()
        assertBusy(opened, false, "第 6 条·读取失败：查询结束后")
    }

    /// 查询在途被覆盖、结果按规则丢弃：结束后为假，退回发起页时也为假。
    func testBusyClearsWhenResultDiscardedAfterCover() async throws {
        let opened = try await tapAndHold("第 6 条·覆盖丢弃")
        let held = try await heldMe(opened, "第 6 条·覆盖丢弃")
        assertBusy(opened, true, "第 6 条·覆盖丢弃：查询挂起时")
        opened.fixture.router.open(RouteRequest(route: WalletRoutes.help, from: .inApp))
        release(held, with: Self.unverified)
        await waitUntil("第 6 条·覆盖丢弃：实名结论没有到") { opened.fixture.wallet.realnameState != nil }
        await quietWindow()
        assertBusy(opened, false, "第 6 条·覆盖丢弃：查询结束后（仍被盖着）")
        opened.fixture.router.path.removeLast()
        await quietWindow()
        assertBusy(opened, false, "第 6 条·覆盖丢弃：退回发起页后")
    }

    // MARK: - 搭法

    /// 打开钱包页（GET /v1/me 挂起），核对点击前不在进行中，再点【提现】。
    private func tapAndHold(_ name: String, file: StaticString = #filePath, line: UInt = #line) async throws -> Opened {
        script.on("GET /v1/me", .hold)
        let opened = try await openWallet(file: file, line: line)
        assertBusy(opened, false, "\(name)：点击前", file: file, line: line)
        tapWithdraw(opened)
        return opened
    }

    private func assertBusy(_ opened: Opened, _ expected: Bool, _ name: String, file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertEqual(opened.entry.context.isOpeningWithdraw, expected,
                       "\(name) isOpeningWithdraw 应为 \(expected)。\(observed(opened))", file: file, line: line)
    }
}
