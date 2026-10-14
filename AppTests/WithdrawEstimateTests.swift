@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
import WalletCore
import XCTest

/// AC-S2-80（①–⑫）：页头与上限、【全部提现】只填 max_withdrawable_fen、档位、估算只显示对得上的最新一次（BR-WDR-04 细则「估算响应的归属」）、
/// 输入清空不发请求、离页与换号作废。⑨（钱包模块不出现浮点金额与税费计算）由 `testNoFloatingPointMoneyInWalletSources` 静态检查覆盖。
final class WithdrawEstimateTests: WalletFlowTestCase {
    /// ①②③：页头 withdrawable_fen 与剩余次数、上限行（max < withdrawable）、【全部提现】填 12 元、估算 net_only。
    func testHeaderMaxLineFillAllAndEstimate() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        let display = try XCTUnwrap(controller.state.display())
        XCTAssertEqual(display.balanceFen, 1234)
        XCTAssertEqual(display.dailyRemaining, 1)
        XCTAssertEqual(display.monthlyRemaining, 10)
        XCTAssertEqual(display.maxLineFen, 1200)
        XCTAssertEqual(display.quick, [500, 1000])
        actions(controller).fillAll()
        XCTAssertEqual(controller.state.amountText, "12")
        await waitUntil { controller.state.estimate != .calculating }
        XCTAssertEqual(controller.state.estimate, .shown(.netOnly(netFen: 1200), amountFen: 1200))
        XCTAssertTrue(WalletStubProtocol.requests("GET", "/v1/withdrawals/rules")
            .contains { $0.query == "amount_fen=1200" })
        // 档位点按后播报「提现金额 x，预计到账 y」（只读结果）
        XCTAssertEqual(controller.state.announce?.key, "withdraw.spoken.quick")
        actions(controller).quick(500)
        XCTAssertEqual(controller.state.amountText, "5")
        actions(controller).quick(999)
        XCTAssertEqual(controller.state.amountText, "5", "不是服务端给的档位不受理")
    }

    /// ④⑤：输入变化立即「计算中…」；停顿约 0.5 秒才带金额取 rules（连续输入只发最后一次）；清空或不合法隐藏且不发请求。
    func testEstimateDebounceAndClearedInputSendsNothing() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        let before = WalletStubProtocol.requests("GET", "/v1/withdrawals/rules").count
        actions(controller).amount("3")
        XCTAssertEqual(controller.state.estimate, .calculating)
        actions(controller).amount("30")
        await waitUntil { controller.state.estimate != .calculating }
        let sent = WalletStubProtocol.requests("GET", "/v1/withdrawals/rules").dropFirst(before)
        XCTAssertEqual(sent.map(\.query), ["amount_fen=3000"], "只为停顿后的金额发一次")
        actions(controller).amount("")
        XCTAssertEqual(controller.state.estimate, .hidden)
        actions(controller).amount("1.234")
        XCTAssertEqual(controller.state.amountText, "", "小数超过 2 位整段不接受，保持原值")
        actions(controller).amount("0")
        XCTAssertEqual(controller.state.estimate, .hidden)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(WalletStubProtocol.requests("GET", "/v1/withdrawals/rules").count, before + 1, "清空、0 不发请求")
    }

    /// ⑩⑪：估算乱序——旧金额的响应晚到不覆盖新金额的估算，也不覆盖已应用的页头（序号只前进）。
    func testOutOfOrderEstimateOnlyLatestApplies() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        script.on("GET /v1/withdrawals/rules", .hold)
        actions(controller).amount("5")
        await waitUntil { WalletStubProtocol.heldIds.count == 1 }
        let first = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        script.ok("GET /v1/withdrawals/rules", WalletSamples.rules(net: 1000))
        actions(controller).amount("10")
        await waitUntil { controller.state.estimate == .shown(.netOnly(netFen: 1000), amountFen: 1000) }
        let version = controller.state.version
        WalletStubProtocol.release(first, with: .envelope(code: 0, data: WalletSamples.rules(net: 500), headers: [:]))
        await settle()
        XCTAssertEqual(controller.state.estimate, .shown(.netOnly(netFen: 1000), amountFen: 1000), "旧序号不覆盖")
        XCTAssertEqual(controller.state.version, version, "页头不被旧序号覆盖")
    }

    /// ⑫：离页（同步出口）作废在途读请求，迟到响应不改页面；换号后旧页面的估算不显示。
    func testLeavingPageCancelsReadsAndAccountSwitchClearsAmount() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        script.on("GET /v1/withdrawals/rules", .hold)
        actions(controller).amount("8")
        await waitUntil { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        script.ok("GET /v1/withdrawals/rules", WalletSamples.rules())
        try fixture.switchAccount(to: "user-b")
        XCTAssertEqual(controller.state.amountText, "", "会话换代同步清空金额")
        XCTAssertEqual(controller.owner.account, "user-b")
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: WalletSamples.rules(net: 800), headers: [:]))
        await settle()
        if case .shown = controller.state.estimate {
            XCTFail("换号前的估算不得显示")
        }
        fixture.router.path.removeAll()
        XCTAssertFalse(controller.alive, "出栈的同步出口")
    }

    /// ⑨ 静态检查：钱包模块（WalletCore、Features/Wallet）不出现浮点金额运算与税费计算。
    func testNoFloatingPointMoneyInWalletSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let dirs = ["Packages/Core/Sources/WalletCore", "Packages/Features/Sources/Wallet"]
        for dir in dirs {
            let url = root.appendingPathComponent(dir)
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                for banned in ["Double(", "Float(", ": Double", ": Float", "Decimal(", "* 0.", "/ 100.0"] {
                    XCTAssertFalse(text.contains(banned), "\(file.lastPathComponent) 含 \(banned)")
                }
            }
        }
    }
}
