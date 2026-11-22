@testable import Couli
import CouliNetwork
import Foundation
import Router
import SwiftUI
import Wallet
import WalletCore
import XCTest

/// FU-IOS-WITHDRAW-ENTRY-SILENT 评审 r1 补的安全性质（S2-2、S3-6；变异 M5 / M6）：
/// - S2-2(a)：点击前读禁用期已在 → 【提现】被 42901 同步拦下，进行中始终为假、不发 GET /v1/me、不导航（M5：进行中置真挪到禁用期检查之前）；
/// - S2-2(b)：查询在途换号 → 旧查询回 verified 也不导航（不进 Withdraw / RealName），新身份下实名结论不被旧结果写入（M6：删 isCurrent 守卫）；
/// - S3-6：本地取消 / 导航作废的提示文案键是 state.load_failed.desc，【重试】按实名结论进 Withdraw 或 RealName。
final class FuIosWithdrawEntrySilentSafetyTests: FuIosWithdrawEntrySilentTestCase {
    // MARK: - S2-2(a)：同步 42901 不置进行中

    /// 钱包自己的读禁用期（WalletGates.read）点击前已在。
    func testWalletReadGateBeforeTapNeverBusy() async throws {
        let opened = try await openWallet()
        opened.fixture.wallet.gates.read.start(30000)
        await assertGatedTapNeverBusy(opened, "S2-2(a)·钱包读禁用期")
        opened.fixture.wallet.gates.read.reset()
    }

    /// 共享 getMe 截止期（meReadGate：「我的」/ 桥 auth.getUser 的 42901）点击前已在。
    func testSharedMeGateBeforeTapNeverBusy() async throws {
        let opened = try await openWallet()
        let gate = RetryAfterGate()
        opened.fixture.wallet.meReadGate = gate
        gate.start(30000)
        await assertGatedTapNeverBusy(opened, "S2-2(a)·共享 getMe 截止期")
        gate.reset()
    }

    // MARK: - S2-2(b)：换号后到达的 verified 不放行

    /// 不经会话重建的静默换令牌（请求作废标记仍有效、查询序号没变，只剩身份核对能拦）：旧查询回 verified。
    func testSilentTokenSwapVerifiedArrivalDoesNotNavigate() async throws {
        try await assertSwapVerifiedDoesNotNavigate("S2-2(b)·静默换令牌") { fixture in
            try fixture.swapTokensSilently(to: "user-b")
        }
    }

    /// 经 AppLogin 出口通知的换号：旧查询回 verified。
    func testSwitchAccountVerifiedArrivalDoesNotNavigate() async throws {
        try await assertSwapVerifiedDoesNotNavigate("S2-2(b)·换号") { fixture in
            try fixture.switchAccount(to: "user-b")
        }
    }

    // MARK: - S3-6：文案键与【重试】结果

    /// 本地取消（共享 getMe 截止期在途开始 → send_blocked）+ 已实名：键为 state.load_failed.desc，【重试】进 Withdraw。
    func testLocalCancelKeyAndRetryOpensWithdraw() async throws {
        try await assertLocalCancelKeyAndRetry(verified: true)
    }

    /// 同上 + 未实名：【重试】经守卫进 RealName。
    func testLocalCancelKeyAndRetryOpensRealName() async throws {
        try await assertLocalCancelKeyAndRetry(verified: false)
    }

    /// 导航作废（查询在途 inactive→active，发起页一直在栈顶）+ 未实名：键为 state.load_failed.desc；实名已查清，【重试】同步进 RealName、
    /// 不再发 GET /v1/me。
    func testSceneBlipVoidedKeyAndRetryOpensRealNameWithoutRequery() async throws {
        let name = "S3-6·导航作废"
        script.on("GET /v1/me", .hold)
        let opened = try await openWallet()
        tapWithdraw(opened)
        let held = try await heldMe(opened, name)
        opened.fixture.wallet.scenePhaseChanged(.inactive)
        opened.fixture.wallet.scenePhaseChanged(.active)
        release(held, with: Self.unverified)
        await waitUntil("\(name)：结果到达后既没进 RealName 也没有 openError") {
            top(opened) == WalletRoutes.realName || opened.entry.context.openError != nil
        }
        await quietWindow()
        if top(opened) == WalletRoutes.realName {
            // 实现若按 brief §1.1 字面直接导航，本条的文案键与【重试】不适用（第 3 条已核导航）
            XCTAssertEqual(pushed(opened), [WalletRoutes.realName], "\(name)：\(observed(opened))")
            return
        }
        XCTAssertEqual(opened.entry.context.openError?.key, "state.load_failed.desc", "\(name)：文案键。\(observed(opened))")
        opened.entry.context.retryOpen()
        XCTAssertEqual(top(opened), WalletRoutes.realName, "\(name)：【重试】应同步进 RealName。\(observed(opened))")
        await quietWindow()
        XCTAssertEqual(pushed(opened), [WalletRoutes.realName], "\(name)：恰好一次 RealName。\(observed(opened))")
        XCTAssertEqual(meRequests(opened).count, 1, "\(name)：【重试】不再发 GET /v1/me。\(observed(opened))")
    }

    // MARK: - 判据

    /// 禁用期已在时点【提现】：同步——不在进行中、发起页 42901、零 GET /v1/me、不导航；观察窗后仍如此。
    private func assertGatedTapNeverBusy(_ opened: Opened, _ name: String, file: StaticString = #filePath,
                                         line: UInt = #line) async {
        let context = opened.entry.context
        XCTAssertFalse(context.isOpeningWithdraw, "\(name) 前提：点击前不在进行中", file: file, line: line)
        tapWithdraw(opened)
        XCTAssertFalse(context.isOpeningWithdraw, "\(name)：点击后立即不应在进行中。\(observed(opened))", file: file, line: line)
        XCTAssertEqual(
            context.openError?.key,
            "error.42901",
            "\(name)：同步 42901。\(observed(opened))",
            file: file,
            line: line
        )
        XCTAssertEqual(meRequests(opened).count, 0, "\(name)：不发 GET /v1/me。\(observed(opened))", file: file, line: line)
        XCTAssertEqual(pushed(opened), [], "\(name)：不导航。\(observed(opened))", file: file, line: line)
        await quietWindow()
        XCTAssertFalse(context.isOpeningWithdraw, "\(name)：观察窗后仍不应在进行中。\(observed(opened))", file: file, line: line)
        XCTAssertEqual(
            meRequests(opened).count,
            0,
            "\(name)：观察窗后零 GET /v1/me。\(observed(opened))",
            file: file,
            line: line
        )
        XCTAssertEqual(pushed(opened), [], "\(name)：观察窗后零导航。\(observed(opened))", file: file, line: line)
        XCTAssertEqual(opened.fixture.router.path.last?.id, opened.origin, "\(name)：停在发起页", file: file, line: line)
    }

    /// 查询挂起时换号，再放行旧查询（verified）：不推 Withdraw / RealName、不提示、实名结论没被写入、进行中收起。
    private func assertSwapVerifiedDoesNotNavigate(_ name: String, file: StaticString = #filePath, line: UInt = #line,
                                                   _ swap: (WalletAppFixture) throws -> Void) async throws {
        script.on("GET /v1/me", .hold)
        let opened = try await openWallet(file: file, line: line)
        let wallet = opened.fixture.wallet
        tapWithdraw(opened)
        let held = try await heldMe(opened, name, file: file, line: line)
        try swap(opened.fixture)
        XCTAssertEqual(wallet.currentOwner().account, "user-b", "\(name) 前提：已换成 user-b", file: file, line: line)
        // 新身份下如有新查询，给未实名（不让它把结论写成 verified、也不挂起）
        script.on("GET /v1/me", Self.unverified)
        WalletStubProtocol.release(held, with: Self.verified)
        await quietWindow()
        let routes = opened.fixture.router.path.map(\.route)
        XCTAssertFalse(routes.contains(WalletRoutes.withdraw), "\(name)：不得进 Withdraw。\(observed(opened))",
                       file: file, line: line)
        XCTAssertFalse(routes.contains(WalletRoutes.realName), "\(name)：不得进 RealName。\(observed(opened))",
                       file: file, line: line)
        XCTAssertNil(opened.entry.context.openError, "\(name)：不提示。\(observed(opened))", file: file, line: line)
        XCTAssertFalse(wallet.realnameVerified(), "\(name)：新身份下不按已实名", file: file, line: line)
        XCTAssertTrue(wallet.realnameState == nil, "\(name)：旧结果不写入实名结论（实得 key 是否为旧身份："
            + "\(wallet.realnameState.map { $0.key != wallet.currentOwner().key } ?? false)）", file: file, line: line)
        XCTAssertFalse(opened.entry.context.isOpeningWithdraw, "\(name)：进行中已收起", file: file, line: line)
    }

    /// 本地取消（同第 4 条的造法）：发起页提示键为 state.load_failed.desc；解除截止期后【重试】按实名结论进 Withdraw / RealName。
    private func assertLocalCancelKeyAndRetry(verified: Bool, file: StaticString = #filePath,
                                              line: UInt = #line) async throws {
        let name = verified ? "S3-6·本地取消（已实名）" : "S3-6·本地取消（未实名）"
        script.on("GET /v1/me", verified ? Self.verified : Self.unverified)
        let opened = try await openWallet(file: file, line: line)
        let gate = RetryAfterGate()
        opened.fixture.wallet.meReadGate = gate
        tapWithdraw(opened)
        gate.start(30000)
        await waitUntil("\(name)：发起页没有 openError", file: file, line: line) {
            opened.entry.context.openError != nil
        }
        XCTAssertEqual(meRequests(opened).count, 0, "\(name) 前提：请求没有写出。\(observed(opened))", file: file, line: line)
        XCTAssertEqual(opened.entry.context.openError?.key, "state.load_failed.desc", "\(name)：文案键。\(observed(opened))",
                       file: file, line: line)
        gate.reset()
        opened.entry.context.retryOpen()
        let target = verified ? WalletRoutes.withdraw : WalletRoutes.realName
        await waitUntil("\(name)：【重试】后没有进 \(target)", file: file, line: line) { top(opened) == target }
        await quietWindow()
        XCTAssertEqual(pushed(opened), [target], "\(name)：【重试】恰好进一次 \(target)。\(observed(opened))",
                       file: file, line: line)
        XCTAssertEqual(meRequests(opened).count, 1, "\(name)：【重试】发一次 GET /v1/me。\(observed(opened))",
                       file: file, line: line)
    }
}
