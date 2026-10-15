@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Me
import MeCore
import Router
import SwiftUI
import WalletCore
import XCTest

/// 第 2 轮评审修复（R2-01…R2-04）：经真实 ApiClient、Router、推送上报执行器与页面宿主。
@MainActor
final class MeReviewR2Tests: MeTestCase {
    private func settings(_ fixture: MeAppFixture) throws -> (MePageEntry, SettingsController) {
        let entry = try XCTUnwrap(fixture.open("Settings"))
        entry.appeared()
        return (entry, try XCTUnwrap(entry.controller() as? SettingsController))
    }

    /// 同步占住主线程（不让出，主线程上的延后任务无法恢复）。
    private func blockMainThread(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private var reports: [WalletStubProtocol.Recorded] {
        requests("POST", "/v1/devices/push-token")
    }

    /// R2-01：挂住 A 会话已发出的 resetTip → 导航栈不变，保存 B 会话并同步身份 → 放行 A 的 10006：不导航、不记「因 10006 进入」、不清栈。
    func testLate10006AfterSameStackAccountSwitchDoesNotNavigate() async throws {
        let fixture = make()
        let (_, controller) = try settings(fixture)
        await waitUntil("Me 没到") { fixture.me.deps.repo.state.me != nil }
        script.on("DELETE /v1/me/tips/jump_tip", .hold)
        let row = try XCTUnwrap(controller.model().groups.flatMap(\.rows).first { $0.id == "重新显示下单须知" })
        SettingsActions.make(controller, controller.state).row(row)
        await waitUntil("resetTip 没发出") { !WalletStubProtocol.heldIds.isEmpty }
        let stack = fixture.router.path.map(\.route)
        XCTAssertEqual(stack, ["Settings"])

        try fixture.switchAccount(to: "user-b")
        fixture.me.syncIdentity()
        await settle()
        XCTAssertEqual(fixture.router.path.map(\.route), stack, "换账号不动导航栈（导航票据不变）")
        XCTAssertEqual(fixture.network.ownershipNow().account, "user-b")

        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first),
                                   with: .envelope(code: 10006, data: "null", headers: [:]))
        await waitUntil("resetTip 没结算") { WalletStubProtocol.heldIds.isEmpty }
        await settle(50)
        XCTAssertEqual(fixture.router.path.map(\.route), stack, "A 的旧 10006 不清 B 的栈、不打开 RiskNotice")
        XCTAssertNil(fixture.me.entered10006, "不把旧响应记成 B 因 10006 进入")
        XCTAssertFalse(fixture.me.enteredBy10006(fixture.me.computeIdentity()))

        // 同一会话的 10006 照常落到 RiskNotice（归属一致）
        script.fail("DELETE /v1/me/tips/jump_tip", 10006)
        let (_, fresh) = try settings(fixture)
        let again = try XCTUnwrap(fresh.model().groups.flatMap(\.rows).first { $0.id == "重新显示下单须知" })
        SettingsActions.make(fresh, fresh.state).row(again)
        await waitUntil("同会话 10006 没落到 RiskNotice") { fixture.router.path.map(\.route) == ["RiskNotice"] }
        XCTAssertTrue(fixture.me.enteredBy10006(fixture.me.computeIdentity()))
    }

    /// R2-02：T1 上报 42901（Retry-After=1）→ 禁用期内令牌变为 T2（延后补发）→ 禁用期已到、延后任务还没恢复时令牌变为 T3：T3 立即上报，
    /// 旧延后任务被消费，不再登记待报；T3 只上报一次。
    func testExpiredGateNewTokenBeforeDeferredTaskResumesReportsOnce() async {
        script.fail("POST /v1/devices/push-token", 42901, headers: ["Retry-After": "1"])
        let fixture = make(pushToken: "t1")
        await waitUntil("强更检查没结果") { fixture.me.updateRaw() == "supported" }
        fixture.me.syncIdentity()
        await waitUntil("42901 没结算") { fixture.me.push.limited }
        await settle()
        script.ok("POST /v1/devices/push-token", "{}")
        let before = reports.count
        fixture.push.change("t2")
        await settle()
        XCTAssertEqual(reports.count, before, "禁用期内不发")

        // 主线程不让出：禁用期按时钟到期，但延后任务（主线程上恢复）还没执行
        let remaining = fixture.me.push.gate.remainingMillis
        blockMainThread(Double(remaining) / 1000 + 0.3)
        XCTAssertFalse(fixture.me.push.limited, "禁用期已到")
        fixture.push.change("t3")

        await waitUntil("T3 没上报") { self.reports.count == before + 1 }
        await waitUntil("T3 没结算") { !fixture.me.push.inFlight }
        try? await Task.sleep(nanoseconds: 600_000_000)
        await settle(50)
        let tokens = reports.dropFirst(before).map { $0.json["token"] as? String }
        XCTAssertEqual(tokens, ["t3"], "同一令牌只上报一次（旧延后任务不再登记待报）")
        XCTAssertFalse(fixture.me.push.pending)
    }

    /// R2-03：封禁说明页的进行中提现保留提现记录页同一份显示结论（状态标题 + 副文案），SLA 与提现记录页同源（Config texts.withdraw.sla_text），
    /// 用 WithdrawalText.render 与统一金额格式化展示。
    func testBannedWithdrawalsKeepSubLinesWithSharedSla() async throws {
        var config = (try JSONSerialization.jsonObject(with: Data(MeSamples.config.utf8))) as? [String: Any] ?? [:]
        var texts = config["texts"] as? [String: Any] ?? [:]
        texts["withdraw.sla_text"] = "测试审核时限说明"
        config["texts"] = texts
        script.ok("GET /v1/config", MeSamples.json(config))
        let paying = WalletSamples.withdrawal("W-pay", status: "PAYING")
        let manual = WalletSamples.withdrawal("W-review", status: "PENDING_REVIEW")
        let auto = WalletSamples.withdrawal("W-auto", status: "APPROVED")
            .replacingOccurrences(of: "\"review_mode\":\"manual\"", with: "\"review_mode\":\"auto\"")
        let paid = WalletSamples.withdrawal("W-paid", status: "PAID_API")
        script.ok("GET /v1/withdrawals", "{\"items\":[\(paying),\(manual),\(auto),\(paid)],\"next_cursor\":null}")
        script.ok("GET /v1/me", MeSamples.me(risk: "banned", reason: "fraud_invite"))
        let fixture = make()
        await fixture.loadConfig()
        let entry = try XCTUnwrap(fixture.open("RiskNotice"))
        entry.appeared()
        let controller = try XCTUnwrap(entry.controller() as? RiskNoticeController)
        await waitUntil("提现没到") { controller.state.withdrawals.count == 3 }
        XCTAssertEqual(controller.slaText(), "测试审核时限说明", "SLA 与提现记录页同源（Config texts）")

        let wallet = WalletDraftTexts()
        let money: (Int64) -> String = { CouliFormat.money(fen: $0) }
        let rendered = controller.state.withdrawals.map {
            WithdrawalText.render($0.display, texts: wallet, money: money)
        }
        let items = try XCTUnwrap(WalletJSON.withdrawalList(WalletJSON.parse(
            Data("{\"items\":[\(paying),\(manual),\(auto)],\"next_cursor\":null}".utf8)
        )))
        let expected = items.items.map { WithdrawalText.of($0, slaText: "测试审核时限说明", texts: wallet) }
        XCTAssertEqual(controller.state.withdrawals.map(\.display), expected, "与提现记录页同一份显示结论")
        XCTAssertEqual(rendered[0], [wallet.text("withdrawal.draft.processing")], "PAYING 的副文案")
        XCTAssertTrue(rendered[1].contains { $0.contains("测试审核时限说明") }, "manual 用配置的 SLA：\(rendered[1])")
        XCTAssertTrue(rendered[1].contains { $0.contains(money(1000)) }, "已冻结金额用统一金额格式：\(rendered[1])")
        XCTAssertEqual(rendered[2].first, wallet.text("withdraw.sla_text_auto"), "auto 的副文案")
        XCTAssertEqual(controller.state.withdrawals.map(\.titleKey), [
            "withdrawal_status.PAYING.title", "withdrawal_status.PENDING_REVIEW.title",
            "withdrawal_status.APPROVED.title",
        ])
    }

    /// R2-04：本地校验错误（清空、超过 16 字素）进入统一错误事件流程：页面播报一次、布局后焦点移到错误节点，同一错误持续不重复播报；
    /// 改回合法输入错误消失。
    func testNicknameLocalErrorAnnouncedOnceAndFocused() async throws {
        let fixture = make()
        let (entry, controller) = try settings(fixture)
        await waitUntil("Me 没到") { fixture.me.deps.repo.state.me != nil }
        let row = try XCTUnwrap(controller.model().groups.flatMap(\.rows).first { $0.id == "昵称" })
        SettingsActions.make(controller, controller.state).row(row)
        let nickname = try XCTUnwrap(controller.nickname)
        let spoken = SpokenLog()
        let focused = SpokenLog()
        MeAnnounceProbe.observe = { text, _ in spoken.lines.append(text) }
        MeAnnounceProbe.focused = { focused.lines.append($0) }
        defer {
            MeAnnounceProbe.observe = nil
            MeAnnounceProbe.focused = nil
        }
        let host = HostedPage(entry.screen())
        defer { host.close() }
        await host.pump()
        XCTAssertTrue(spoken.lines.isEmpty)
        let texts = fixture.me.deps.texts

        NicknameActions.make(nickname, nickname.state).clear()
        await host.pump(until: { focused.lines.count == 1 })
        XCTAssertEqual(nickname.state.error?.key, NicknameController.emptyKey)
        XCTAssertTrue(nickname.state.fieldError, "错误关联到输入框")
        XCTAssertEqual(spoken.lines, [texts.text("nickname.empty")], "清空即播报一次")
        XCTAssertEqual(focused.lines, ["nickname.error"], "布局后焦点移到错误节点")

        let long = String(repeating: "长", count: 17)
        NicknameActions.make(nickname, nickname.state).input(long)
        await host.pump(until: { focused.lines.count == 2 })
        XCTAssertEqual(nickname.state.error?.key, NicknameController.tooLongKey)
        XCTAssertEqual(spoken.lines.last, texts.text("nickname.too_long"), "错误变化再播报一次")
        let event = nickname.state.errorEvent

        NicknameActions.make(nickname, nickname.state).input(long + "长")
        await host.pump(rounds: 10)
        XCTAssertEqual(nickname.state.errorEvent, event, "同一错误持续不推进事件")
        XCTAssertEqual(spoken.lines.count, 2, "不重复播报")
        XCTAssertEqual(focused.lines.count, 2)

        NicknameActions.make(nickname, nickname.state).input("好名字")
        await host.pump()
        XCTAssertNil(nickname.state.error)
        XCTAssertTrue(nickname.state.check.saveEnabled)
    }
}
