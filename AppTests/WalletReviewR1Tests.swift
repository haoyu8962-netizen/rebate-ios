@testable import Couli
import CouliNetwork
import Foundation
import Router
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09 iOS 第 1 轮评审（ios-review-r1.md R1-01…R1-03；R1-04…R1-11 见
/// WalletReviewR1SettleTests、WalletReviewR1PageTests）的修复用例：经真实 Router、真实 ApiClient
/// 管线、页面渲染时取出的回调与页面渲染时取出的回调，只把传输层换成本地假服务。
final class WalletReviewR1Tests: WalletFlowTestCase {
    // MARK: - R1-01 假服务默认保留未决记录

    /// R1-01（S0）：默认假服务参数下提交结果未知 → 杀进程重启（冷启动准备照默认参数执行，新组合读同一份本机记录）→ 未决记录仍在、
    /// 待确认恢复，【提交】不可用、不生成新键、零新 POST。只有截图夹具显式带清场参数时才清。
    func testColdStartWithDefaultArgumentsKeepsPendingAndBlocksNewKey() async throws {
        let account = DebugFakeWallet.fakeAccount
        let backend = MemoryPendingKeyBackend()
        let draftRoot = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName + ".draft")
        let key: String
        do {
            let first = make(account: account, pending: backend)
            let controller = try await withdraw(first)
            try await enterPending(controller)
            key = try XCTUnwrap(controller.flow.state.pending?.key)
            first.router.path.removeAll()
        }
        XCTAssertEqual(try backend.loadAll(account: account).map(\.key), [key], "前提：结果未知的键已写入本机")

        // 杀进程后冷启动：假服务照默认参数准备（正常启动、冷启动恢复都不带清场参数）
        DebugFakeWallet.prepareColdStart(
            arguments: [DebugFakeLoginServer.launchArgument, DebugFakeTrade.loggedInArgument, "-CouliStartTab", "me"],
            backend: backend, draftRoot: draftRoot
        )
        XCTAssertEqual(try backend.loadAll(account: account).map(\.key), [key], "默认参数下未决记录仍在")

        let second = make(account: account, pending: backend)
        let restored = try await withdraw(second)
        await waitUntil("冷启动后没有恢复待确认") { restored.flow.state.pending?.key == key }
        XCTAssertFalse(restored.flow.state.canSubmit, "待确认期间【提交】不可用")
        let before = posts.count
        await typeAmount(restored, "5")
        actions(restored).submit()
        await settle()
        XCTAssertEqual(posts.count, before, "不能生成新键：零新 POST")
        XCTAssertEqual(restored.flow.state.pending?.key, key)

        // 截图夹具显式清场时才清（与上面的正常启动、冷启动恢复隔离）
        DebugFakeWallet.prepareColdStart(
            arguments: [DebugFakeLoginServer.launchArgument, DebugFakeWallet.resetPendingArgument],
            backend: backend, draftRoot: draftRoot
        )
        XCTAssertTrue(try backend.loadAll(account: account).isEmpty, "显式清场参数才清假账号的未决记录")
    }

    // MARK: - R1-02 假服务的两种结果未知

    /// R1-02：响应丢失（unknown_created）原子保存建单与幂等结果再丢响应——确认返回原结果、放弃返回 completed，建单数始终 1；
    /// 请求未到达（unknown_lost）在任何业务修改之前按传输失败结束——不建单、不记幂等结果、不核销 token，确认仍未到达、放弃返回 abandoned，
    /// 列表条数不变。
    func testFakeWalletUnknownScenesKeepCreatedCountConsistent() throws {
        let fake = DebugFakeWallet()
        let defaultsKey = DebugFakeWallet.launchArgument
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        let token = try stepUpToken(fake)
        let headers = { (key: String) in ["Idempotency-Key": key, "X-Step-Up-Token": token] }
        let body: [String: Any] = ["amount_fen": 1000]

        UserDefaults.standard.set("submit=unknown_created", forKey: defaultsKey)
        XCTAssertTrue(isOffline(fake.answer(method: "POST", path: "/v1/withdrawals", query: [:], body: body,
                                            headers: headers("K1"))), "响应丢失：按传输失败结束")
        XCTAssertEqual(fake.created.count, 1, "业务结果已保存")
        XCTAssertNotNil(fake.results["K1"], "幂等结果与业务结果一起保存")
        XCTAssertEqual(code(fake.answer(method: "POST", path: "/v1/withdrawals", query: [:], body: body,
                                        headers: headers("K1"))), 0, "确认（原键重发）返回原结果")
        XCTAssertEqual(fake.created.count, 1, "确认不再建单")
        let completed = fake.answer(method: "POST", path: "/v1/idempotency-keys/abandon", query: [:],
                                    body: ["idempotency_key": "K1"], headers: [:])
        XCTAssertTrue(data(completed).contains("\"outcome\":\"completed\""), "放弃返回 completed（原结果）")
        XCTAssertEqual(fake.created.count, 1, "放弃不改变建单数")

        UserDefaults.standard.set("submit=unknown_lost", forKey: defaultsKey)
        XCTAssertTrue(isOffline(fake.answer(method: "POST", path: "/v1/withdrawals", query: [:], body: body,
                                            headers: headers("K2"))), "请求未到达：按传输失败结束")
        XCTAssertEqual(fake.created.count, 1, "请求未到达：不建单")
        XCTAssertNil(fake.results["K2"], "请求未到达：不记幂等结果")
        XCTAssertTrue(fake.validTokens.contains(token), "请求未到达：不核销 token")
        XCTAssertTrue(isOffline(fake.answer(method: "POST", path: "/v1/withdrawals", query: [:], body: body,
                                            headers: headers("K2"))), "确认仍未到达")
        XCTAssertEqual(fake.created.count, 1)
        let abandoned = fake.answer(method: "POST", path: "/v1/idempotency-keys/abandon", query: [:],
                                    body: ["idempotency_key": "K2"], headers: [:])
        XCTAssertTrue(data(abandoned).contains("\"outcome\":\"abandoned\""), "放弃返回 abandoned")
        XCTAssertEqual(fake.created.count, 1, "客户端与服务端结局一致：只有响应丢失那一单")
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let list = data(fake.answer(method: "GET", path: "/v1/withdrawals", query: [:], body: [:], headers: [:]))
        XCTAssertEqual(list.components(separatedBy: "\"withdrawal_id\"").count - 1, 1 + fake.samples().count,
                       "列表 = 1 单新建 + 样例")
    }

    private func stepUpToken(_ fake: DebugFakeWallet) throws -> String {
        let reply = fake.answer(method: "POST", path: "/v1/auth/step-up", query: [:],
                                body: ["action": "withdraw", "code": "123456"], headers: [:])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(data(reply).utf8)) as? [String: Any]
        )
        return try XCTUnwrap(object["step_up_token"] as? String)
    }

    private func isOffline(_ reply: DebugFakeWallet.Reply?) -> Bool {
        if case .offline = reply {
            return true
        }
        return false
    }

    private func code(_ reply: DebugFakeWallet.Reply?) -> Int? {
        if case let .answer(code, _, _) = reply {
            return code
        }
        return nil
    }

    private func data(_ reply: DebugFakeWallet.Reply?) -> String {
        if case let .answer(_, data, _) = reply {
            return data
        }
        return ""
    }

    // MARK: - R1-03 待确认卡独立于读取状态

    /// R1-03：本机已有结果未知的提现键，重新进入时 rules 返回 50001 → 真实提现页同时显示读取错误与待确认卡，【确认上一笔】可用并按原键发出。
    func testWithdrawPendingCardShownWhenRulesReadFails() async throws {
        let fixture = make()
        let first = try await withdraw(fixture)
        try await enterPending(first)
        let key = try XCTUnwrap(first.flow.state.pending?.key)
        fixture.router.path.removeAll()
        script.fail("GET /v1/withdrawals/rules", 50001)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.withdraw))
        let controller = try XCTUnwrap(entry.controller as? WithdrawController)
        controller.start()
        await waitUntil("rules 读取失败与待确认没有同时到位") {
            controller.state.phase == .error && controller.flow.state.pending?.key == key
        }
        // 页面区域的显示（读取错误与待确认卡同时可见、按钮可点）由 UI 用例 WalletReviewR1UITests 在真实界面断言
        XCTAssertFalse(controller.flow.state.pending?.inFlight ?? true, "确认与放弃可用")
        let before = posts.count
        script.ok("POST /v1/withdrawals", WalletSamples.withdrawal("W-confirmed"))
        flowActions(controller.flow).confirm()
        await waitUntil("确认没有发出") { posts.count == before + 1 }
        XCTAssertEqual(posts.last?.header("Idempotency-Key"), key, "原键")
    }

    /// R1-03：收款账号页同样——已有结果未知的保存键，账号读取 50001 时待确认卡仍显示，确认与放弃可用。
    func testPayoutPendingCardShownWhenAccountReadFails() async throws {
        let fixture = make()
        let first = try await payout(fixture)
        let key = try await enterPayoutPending(first)
        fixture.router.path.removeAll()
        script.fail("GET /v1/me/payout-account", 50001)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.payoutAccount))
        let controller = try XCTUnwrap(entry.controller as? PayoutAccountController)
        controller.start()
        await waitUntil("账号读取失败与待确认没有同时到位") {
            controller.state.phase == .error && controller.flow.state.pending?.key == key
        }
        XCTAssertFalse(controller.flow.state.pending?.inFlight ?? true, "确认与放弃可用（界面见 WalletReviewR1UITests）")
        script.ok("PUT /v1/me/payout-account", WalletSamples.alipay)
        let before = saves.count
        flowActions(controller.flow).confirm()
        await waitUntil("确认没有发出") { saves.count == before + 1 }
        XCTAssertEqual(saves.last?.header("Idempotency-Key"), key, "原键")
    }

    /// 收款账号保存进入结果未知（断连），返回未决键。
    private func enterPayoutPending(_ controller: PayoutAccountController) async throws -> String {
        script.on("PUT /v1/me/payout-account", .envelope(code: 10003, data: "null", headers: [:]), .disconnect)
        let owner = controller.owner
        controller.change(version: controller.state.version, shown: controller.state.account ?? .unbound, owner: owner)
        controller.onLogonChange("test@example.com", owner: owner)
        controller.onPayeeChange("测试", owner: owner)
        controller.save(owner: owner)
        try await passStepUp(controller.flow.stepUp)
        await waitUntil("收款账号没有进入待确认") { controller.flow.state.pending != nil }
        return try XCTUnwrap(controller.flow.state.pending?.key)
    }
}
