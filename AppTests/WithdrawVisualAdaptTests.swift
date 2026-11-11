@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// 大字号 / 窄屏（AdaptLargeTextWithdraw、AdaptNarrowWithdraw；brief §2.7「提现页含已选档位、压力值」、验收 6）：字号真放大、不截断、不缩字、
/// 同时比较尺寸与位置（APP-06v-a r2 / APP-11v-b r2）；AX3 × 320 金额框放大；档位换行后命中不重叠；【提交】可达。
@MainActor
final class WithdrawVisualAdaptTests: WithdrawVisualTestCase {
    private let ax = DynamicTypeSize.accessibility3

    private func assertLargeLayout(
        _ rules: String,
        amount: String,
        estimate: String,
        width: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let (_, image) = try await openWithdraw(rules, amount: amount, estimate: estimate,
                                                canvas: .init(width: width, height: 2600, size: ax), file: file,
                                                line: line)
        let card = try rect("withdraw.balance", file: file, line: line)
        let amountItem = try record("withdraw.balance.amount", file: file, line: line)
        XCTAssertGreaterThan(amountItem.fontSize, 34 * 1.3, "大数真放大", file: file, line: line)
        let inner = card.insetBy(dx: 16, dy: 0)
        if amountItem.naturalWidth > inner.width {
            try await assertWrappedAmount("withdraw.balance.amount", inside: card, image: image,
                                          background: pixel(CouliColor.backgroundSurface, dark: false),
                                          "大数放不下：整段一行卡内横滑",
                                          file: file, line: line)
        } else {
            try assertWholeAmount("withdraw.balance.amount", inside: card, "大数整段", file: file, line: line)
        }
        try assertNotTruncated("withdraw.balance.counts", "次数行", file: file, line: line)
        let box = try rect("withdraw.amount.box", file: file, line: line)
        let input = try record("withdraw.amount.input", file: file, line: line)
        XCTAssertGreaterThanOrEqual(input.fontSize, 36, "金额框放大（130% 起 28 → 36）", file: file, line: line)
        assertInside(input.rect, box, "输入在框内", file: file, line: line)
        XCTAssertGreaterThanOrEqual(box.height, input.rect.height, file: file, line: line)
        try XCTAssertLessThanOrEqual(rect("withdraw.all", file: file, line: line).maxX, width - 16, "【全部提现】在屏内",
                                     file: file, line: line)
        try assertDisjoint(
            rect("withdraw.all.hit", file: file, line: line),
            box,
            "放不下时【全部提现】换到框下，不压框",
            file: file,
            line: line
        )
        try assertNotTruncated("withdraw.estimate", "估算句", file: file, line: line)
        try assertNotTruncated("withdraw.sla.text", "时效句", file: file, line: line)
        try assertNotTruncated("withdraw.irrevocable", "不可撤销句", file: file, line: line)
        try assertNotTruncated("withdraw.payout.value", "收款账号", file: file, line: line)
        try assertNotTruncated("withdraw.submit.label", "提交按钮字", file: file, line: line)
        let quick = (page?.probes.records.map(\.key) ?? [])
            .filter { $0.hasPrefix("withdraw.quick.") && $0.hasSuffix(".hit") }.sorted()
        XCTAssertFalse(quick.isEmpty, "有档位", file: file, line: line)
        for (index, first) in quick.enumerated() {
            for second in quick[(index + 1)...] {
                try assertDisjoint(rect(first, file: file, line: line), rect(second, file: file, line: line),
                                   "\(first) / \(second) 换行后不重叠", file: file, line: line)
            }
            let chip = String(first.dropLast(".hit".count))
            try XCTAssertLessThanOrEqual(rect(chip + ".label", file: file, line: line).width,
                                         rect(chip, file: file, line: line).width + 0.5, "档位字不出胶囊", file: file,
                                         line: line)
        }
    }

    func testAX3W390() async throws {
        try await assertLargeLayout("normal", amount: "10", estimate: "estimated", width: 390)
    }

    func testAX3W320() async throws {
        try await assertLargeLayout("normal", amount: "10", estimate: "estimated", width: 320)
    }

    /// 压力值：¥999999999.99、最多 9 位输入、四个档位。
    func testAX3W390Stress() async throws {
        try await assertLargeLayout("stress", amount: "999999999.00", estimate: "stress", width: 390)
    }

    func testAX3W320Stress() async throws {
        try await assertLargeLayout("stress", amount: "999999999.00", estimate: "stress", width: 320)
    }

    /// 待确认卡 AX3 × 320：两按钮纵排、不截断；注释与链接可换行，链接仍可点。
    func testAX3W320PendingCard() async throws {
        let (host, _) = try await openWithdraw(estimate: "estimated", canvas: .init(width: 320, height: 2600, size: ax))
        try await enterPending()
        _ = await host.stable { $0.flow?.state.pending != nil && $0.probes["pending.alert"] != nil }
        let abandon = try rect("pending.abandon")
        let confirm = try rect("pending.confirm")
        XCTAssertFalse(sameRow(abandon, confirm), "放不下时纵排")
        try assertNotTruncated("pending.abandon.label", "放弃字")
        try assertNotTruncated("pending.confirm.label", "确认字")
        try assertNotTruncated("pending.desc", "说明")
        try assertHit("pending.records.hit", covers: "pending.records", "链接")
    }

    /// 弹窗 AX3 × 320：按钮主在上、都不截断、正文可达（放不下才滚）。
    func testAX3W320Dialog() async throws {
        let (host, _) = try await openWithdraw(
            amount: "10",
            estimate: "estimated",
            canvas: .init(width: 320, height: 568, size: ax)
        )
        host.server.script.fail("POST /v1/withdrawals", 44001)
        host.actions?.submit()
        _ = await host.stable { $0.flow?.state.riskDialog != nil && $0.probes["flow.dialog.primary"] != nil }
        let primary = try rect("flow.dialog.primary")
        let secondary = try rect("flow.dialog.secondary")
        XCTAssertLessThan(primary.maxY, secondary.minY + 0.5, "放不下时主按钮在上")
        XCTAssertLessThanOrEqual(secondary.maxY, 568, "按钮在窗口内")
    }
}
