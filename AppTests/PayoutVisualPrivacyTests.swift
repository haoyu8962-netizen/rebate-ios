@testable import Couli
import CouliNetwork
import Foundation
import Wallet
import WalletCore
import XCTest

/// 身份证号 / 银行卡号的脱敏与不外泄（prompt 资金写页硬约束）。全部用 fixture 的明显测试值当哨兵；失败信息不打印哨兵本身。
@MainActor
final class PayoutVisualPrivacyTests: PayoutVisualTestCase {
    private func leak(_ text: String, _ secrets: [String]) -> Bool {
        secrets.contains { text.contains($0) }
    }

    /// 执行器状态的 description 不带明文（崩溃日志、断言信息走这里）。
    func testDescriptionsRedacted() async throws {
        let (host, _) = try await openRealName(needProbes: false)
        let form = try PayoutVisualData.realnameForm()
        let secrets = [form.name, form.idNo.uppercased(), form.idNo]
        let snapshot = try XCTUnwrap(host.realName?.state)
        XCTAssertFalse(leak("\(snapshot)", secrets), "RealNameSnapshot.description 带了明文")
        let bank = try PayoutVisualData.form("bank")
        let payout = PayoutForm(method: WalletJSON.bankCard, cardNo: try XCTUnwrap(bank["cardNo"]),
                                bankName: try XCTUnwrap(bank["bankName"]), payeeName: try XCTUnwrap(bank["payeeName"]))
        XCTAssertFalse(leak("\(payout)", Array(bank.values)), "PayoutForm.description 带了明文")
        let input = RealNameForm.normalize(name: form.name, idNo: form.idNo)
        XCTAssertFalse(leak("\(input)", secrets), "RealNameInput.description 带了明文")
    }

    /// 测量记录（Debug 场景会序列化）不带完整输入。
    func testProbesCarryNoInput() async throws {
        let (host, _) = try await openPayout(needProbes: false)
        try fillBank(host)
        _ = await host.stable { $0.payout?.state.form.cardNo.isEmpty == false }
        let card = try XCTUnwrap(PayoutVisualData.form("bank")["cardNo"])
        XCTAssertFalse(pageTexts.contains { $0.contains(card) }, "测量带了完整卡号")
        try await openRealName(needProbes: false)
        let form = try PayoutVisualData.realnameForm()
        XCTAssertFalse(pageTexts.contains { leak($0, [form.idNo, form.idNo.uppercased()]) }, "测量带了完整身份证号")
    }

    /// 已绑定只显示服务端脱敏字段（标签、大字、读屏来源都是它）。
    func testBoundShowsServerMasksOnly() async throws {
        let (host, _) = try await openPayout("boundBank", needProbes: false)
        let account = try XCTUnwrap(host.payout?.state.account)
        XCTAssertEqual(account.maskedAccount, "尾号 1234")
        XCTAssertEqual(account.maskedPayee, "**三")
    }

    /// 保存成功、实名成功后内存里的完整输入清掉；离开页面也清。
    func testInputClearedAfterFinish() async throws {
        let host = try await openAndSave(.envelope(code: 0, data: PayoutVisualData.payoutBody("boundAlipay"),
                                                   headers: [:]), needProbes: false)
        await waitUntil("保存后表单没清空") { host.payout?.state.form == PayoutForm() }
        let (real, _) = try await openRealName(needProbes: false)
        real.realName?.leave()
        XCTAssertEqual(real.realName?.state.idNo, "", "离开清空身份证号")
        XCTAssertEqual(real.realName?.state.name, "", "离开清空姓名")
    }

    /// 偏好与埋点不含明文（待确认时完整请求体只在未决记录）。
    func testNothingInDefaultsOrAnalytics() async throws {
        let (host, _) = try await openPayout(needProbes: false)
        host.server.script.on("PUT /v1/me/payout-account", .disconnect)
        host.grantStepUp()
        try fillBank(host)
        host.payoutActions?.save()
        await waitUntil("没进待确认") { host.flow?.state.pending != nil }
        let bank = try XCTUnwrap(PayoutVisualData.form("bank")["cardNo"])
        let stored = String(describing: defaults?.dictionaryRepresentation() ?? [:])
        XCTAssertFalse(stored.contains(bank), "完整卡号进了偏好")
        let tracked = String(describing: host.fixture.tracked.events)
        XCTAssertFalse(tracked.contains(bank), "完整卡号进了埋点")
        XCTAssertFalse(host.flow?.state.pending?.summary.contains(bank) ?? true, "完整卡号进了摘要")
    }
}
