@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
import WalletCore
import XCTest

/// 应用侧结果归属的两道核对（评审 r1 S2-1，impl handback m07）。网络层按会话世代作废换号前的回包，端到端用例看不出应用侧核对；
/// 这里经 `installBackends(realname:)` 注入不走 ApiClient 的替身（先例 GateRealName，FollowupIos0712ReworkWalletTests），让 A 的
/// 成功回包在换成 B 之后直接到达应用侧：
/// ① RealNameController：结果核对 `state.owner == attempt.owner`（及离页 / 身份核对）——A 的结果不能让 B 的表单完成、出栈或锁住；
/// ② AppWallet.realnameSubmitted：`isCurrent(owner)`——A 的固定身份不再是当前会话时，不记已实名、不复查。
/// 去掉任一道核对的变异应红。
final class RealnameFundsOwnerTests: RealnameFundsTestCase {
    /// ①：提交挂住 → 换 B → 放行 A 的成功：B 的表单不完成、不出栈、仍可填写提交，B 不按已实名。
    func testOldAccountResultNotAdoptedByController() async throws {
        scriptAlwaysUnverified()
        let fixture = make()
        let backend = GateRealName()
        fixture.wallet.installBackends(realname: backend, labor: nil)
        let page = try await openFromWithdraw(fixture)
        fill(page)
        submitWithConsent(page)
        await waitUntil("实名提交没有到替身") { backend.calls == 1 }
        let ownerA = page.state.owner
        try fixture.switchAccount(to: "user-b")
        XCTAssertNotEqual(page.state.owner, ownerA, "换号后表单换上 B 的身份（前提）")
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.realName, "换号后实名页仍在（前提）")
        backend.release()
        await quietWindow(1.0)
        XCTAssertFalse(fixture.wallet.realnameVerified(), "A 的结果让 B 按已实名")
        XCTAssertNil(page.state.done, "A 的结果让 B 的表单完成")
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.realName, "A 的结果让 B 的实名页出栈")
        fill(page)
        XCTAssertTrue(page.submitEnabled, "A 的结果把 B 的表单锁住了")
        XCTAssertEqual(backend.calls, 1, "不重放")
    }

    /// ②：A 的固定身份已不是当前会话时直接调 realnameSubmitted：不记已实名、不发复查。
    func testRealnameSubmittedIgnoresStaleOwner() async throws {
        scriptAlwaysUnverified()
        let fixture = make()
        let ownerA = fixture.wallet.currentOwner()
        try fixture.switchAccount(to: "user-b")
        await quietWindow(0.5)
        let before = meGets.count
        fixture.wallet.realnameSubmitted(ownerA)
        await quietWindow(1.0)
        XCTAssertFalse(fixture.wallet.realnameVerified(), "旧身份的成功记到了当前会话")
        XCTAssertEqual(meGets.count, before, "旧身份的成功触发了复查")
        // 对照：当前身份照常记已实名并复查（证明上面不是因为入口失效而空过）
        fixture.wallet.realnameSubmitted(fixture.wallet.currentOwner())
        XCTAssertTrue(fixture.wallet.realnameVerified(), "当前身份的成功没有记已实名")
        await waitUntil("当前身份的成功没有复查") { self.meGets.count > before }
    }
}
