@testable import Couli
import CouliNetwork
import Foundation
import Wallet
@testable import WalletCore
import XCTest

/// 四个 action 的同件回归（`StepUpAloneHost`）。换手机号、注销在 iOS 没有页面，不是真点，见交回 §6。除 `testPhoneAndDeletionShareNewLayout` 属版式（先红）外，
/// 底版应绿，实现后必须仍绿。
@MainActor
final class StepUpVisualActionTests: StepUpVisualTestCase {
    private func alone(_ action: String, canvas: WithdrawVisualHost.Canvas = .init(),
                       file: StaticString = #filePath, line: UInt = #line) async throws -> StepUpAloneHost {
        let (host, _) = try await openWithdraw(needProbes: false, file: file, line: line)
        host.wallet.clock = { Self.frozenMillis }
        host.server.script.on("POST /v1/auth/sms-codes", Self.smsOk())
        let owner = try XCTUnwrap(host.controller?.owner, file: file, line: line)
        host.close()
        let panel = StepUpAloneHost(deps: host.wallet.deps, owner: owner, action: action, probes: host.probes,
                                    canvas: canvas)
        addTeardownBlock { @MainActor in panel.close() }
        await waitUntil("\(action)：面板没就绪", file: file, line: line) {
            panel.controller.state.map(Self.landed) ?? false
        }
        return panel
    }

    /// 发码、验证都带自己的 action；输满不验证；显式一次；token 只交给打开者、只存到这个 action。
    func testEveryActionSendsAndVerifiesItsOwnAction() async throws {
        for action in ["withdraw", "payout_account_change", "phone_change", "account_deletion"] {
            let panel = try await alone(action)
            XCTAssertEqual(smsSends.count, 1, action)
            XCTAssertEqual(smsSends.last?.json["action"] as? String, action)
            XCTAssertEqual(smsSends.last?.json["purpose"] as? String, "step_up")
            page?.server.script.on("POST /v1/auth/step-up", Self.stepOk("t-\(action)"))
            panel.actions?.code("123456")
            await quietWindow(0.6)
            XCTAssertEqual(verifies.count, 0, "\(action)：输满零验证")
            panel.actions?.verify()
            await waitUntil("\(action)：token 没交回") { panel.tokens.count == 1 }
            XCTAssertEqual(verifies.count, 1, action)
            XCTAssertEqual(verifies.first?.json["action"] as? String, action)
            XCTAssertEqual(panel.tokens, ["t-\(action)"], "只交一次")
            XCTAssertEqual(panel.closed, 0, "成功不走关闭回调")
            XCTAssertNil(panel.controller.state, "面板收起")
            panel.close()
        }
    }

    /// 关闭：恰一次 onClosed，零验证，零 token。
    func testEveryActionCloseIsClean() async throws {
        for action in ["phone_change", "account_deletion"] {
            let panel = try await alone(action)
            panel.actions?.code("123456")
            panel.actions?.close()
            await quietWindow(0.3)
            XCTAssertEqual(panel.closed, 1, action)
            XCTAssertEqual(panel.tokens, [], action)
            XCTAssertEqual(verifies.count, 0, action)
            panel.close()
        }
    }

    /// 换号后旧面板：四个 action 都零写入、零 token（`owner` 票据不串）。
    func testEveryActionOwnerGuard() async throws {
        for action in ["phone_change", "account_deletion"] {
            let panel = try await alone(action)
            panel.actions?.code("123456")
            let stale = try XCTUnwrap(panel.actions)
            let before = writes
            try page?.fixture.switchAccount(to: "user-b")
            await settle()
            stale.verify()
            stale.resend()
            await quietWindow(0.4)
            XCTAssertEqual(writes, before, "\(action)：换号零写入")
            XCTAssertEqual(panel.tokens, [], action)
            panel.close()
        }
    }

    /// 版式（先红）：换手机号、注销的 action 下同件也是新版式。
    func testPhoneAndDeletionShareNewLayout() async throws {
        for action in ["phone_change", "account_deletion"] {
            let panel = try await alone(action)
            await waitUntil("\(action)：缺 stepUp.cell.5（§2 测量桥）", timeout: 4) { self.has("stepUp.cell.5") }
            await waitUntil("\(action)：缺 stepUp.handle", timeout: 2) { self.has("stepUp.handle") }
            // 倒计时那一行比格子晚一拍上报（verify4 / v3b 实测 1/25 红），等到了再比措辞
            await waitUntil("\(action)：缺 stepUp.countdown", timeout: 2) { self.has("stepUp.countdown") }
            try assertNear(rect("stepUp.cell.0").height / sheetScale(in: panel.window), 56, 0.5, "\(action)：格高")
            XCTAssertEqual(try text("stepUp.countdown"), "48 秒后可重新获取", action)
            panel.close()
        }
    }
}
