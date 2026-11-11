@testable import Couli
import DesignSystem
import Foundation
@testable import Login
import Router
import Session
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-NUM-WRAP（tests v3，评审 r1 S1）：绑手机页「并入原账号」弹窗（BindPhoneMerge，`BindMergeBody`）浅底信息块里的
/// 「手机号账号 138****5678」四档下不在号码中间断（同 `DigitsWrapAbandonTests` 的写法，走生产路径弹出）。
/// 生产路径：第三方新号 → 绑手机页 → 填号 13800005678 + 验证码 → 提交，绑定接口回 30411（reason=mergeable + merge_ticket）
/// → 执行器弹并号确认，号码由执行器脱敏。页面没有测量钩子，判据与 `DigitsWrapBindPendingTests` 同一套（读屏树定位 + 主文字色墨迹：
/// 恰一行、高够一个数字、整段可见，或在横滑条里且条竖向包住墨迹、墨迹铺到可见右缘）。
/// 账号行文案经 `LoginTexts` 下发；这里把它换成只有号码（「手机号账号」前缀同为主文字色，留着会和号码混成两行墨迹），
/// 其余文案照生产。宿主 `BindPhoneLayoutCanvas` 固定浅色。
@MainActor
final class DigitsWrapBindMergeTests: MeTestCase {
    private static let phone = "13800005678"
    private static let masked = "138****5678"

    /// 并号弹窗账号行只剩号码，其余文案照生产。
    private struct AccountOnlyTexts: LoginTexts {
        let base: LoginTexts

        func text(_ key: String) -> String {
            base.text(key)
        }

        func format(_ key: String, _ vars: [String: String]) -> String {
            key == BindPhoneKeys.mergeAccount ? vars["phone"] ?? "" : base.format(key, vars)
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaultsPendingBackend().delete()
        script.ok("POST /v1/auth/oauth-attempts", DigitsBindScript.attempt)
        script.ok("POST /v1/auth/login/wechat", DigitsBindScript.login)
        script.ok("POST /v1/auth/sms-codes", "{\"resend_after_sec\":60,\"expires_in_sec\":300}")
        script.fail("POST /v1/me/phone", 30411, data: "{\"reason\":\"mergeable\",\"merge_ticket\":\"merge-ticket-1\"}")
        script.install()
    }

    override func tearDown() {
        UserDefaultsPendingBackend().delete()
        super.tearDown()
    }

    func testMergeDialogPhoneNeverBreaksAllTiers() async throws {
        try await eachTier { canvas, block, _, tier in
            let pixels = ProductVisualPixels(DigitsWrapBindPendingTests.render(canvas.window))
            return DigitsWrapBindPendingTests.lineProblems(
                pixels, region: block.frame, ink: CouliColor.textPrimary, on: canvas,
                name: "[\(tier)] 并号弹窗账号号码"
            )
        }
    }

    /// tests v3 发现：号码进横滑条后，「并入到 + 账号」组合读屏元素里没有号码（只读「并入到」）。读屏要读全（号码不管排成几行、
    /// 横不横滑都要读出来），所以四档都钉「组合元素的读屏文字含号码」。
    func testMergeDialogSpokenBlockKeepsPhoneAllTiers() async throws {
        try await eachTier { _, block, _, tier in
            block.label.contains(Self.masked) ? []
                : ["[\(tier)] 并号信息块读屏文字「\(block.label)」没有号码 \(Self.masked)（横滑条里的字没并进组合元素）"]
        }
    }

    /// 四档各走一条新的真实链路弹出并号弹窗（30411 并号结局之后同一页再提交不会再弹，不复用上一档的页面），
    /// 找到「并入到 + 账号」组合读屏元素（取面积最小的含「并入到」的元素）交给 `judge`，问题按档汇总断言。
    private func eachTier(_ judge: (BindPhoneLayoutCanvas, DigitsWrapBindPendingTests.Node, String, String)
        async -> [String]) async throws {
        try enableDigitsAccessibilityTree()
        for judgeTier in DigitsRunJudge.tiers {
            let fixture = make(account: nil)
            let entry = try await digitsBindEntry(fixture)
            let intoLabel = fixture.login.texts.text(BindPhoneKeys.mergeInto)
            let tier = BindPhoneLayoutCanvas.Tier(name: judgeTier.name + "（浅）", width: judgeTier.width,
                                                  size: judgeTier.size)
            let page = BindPhoneScreen(entry: entry, texts: AccountOnlyTexts(base: fixture.login.texts))
            let canvas = BindPhoneLayoutCanvas(AnyView(page), tier: tier)
            defer { canvas.close() }
            await canvas.pump()
            let controller = entry.controller
            controller.setPhone(Self.phone)
            controller.setCode("123456")
            controller.submit()
            await waitUntil("[\(tier)] 没有弹并号确认") {
                if case .merge = controller.dialog {
                    return true
                }
                return false
            }
            guard case let .merge(_, shown, _) = controller.dialog else { continue }
            XCTAssertEqual(shown, Self.masked, "[\(tier)] 前提：执行器脱敏后的号码")
            var nodes: [DigitsWrapBindPendingTests.Node] = []
            for _ in 0..<10 {
                await canvas.pump()
                nodes = DigitsWrapBindPendingTests.labelled(canvas.window)
                if nodes.contains(where: { $0.label.contains(intoLabel) }) {
                    break
                }
            }
            // 「并入到」+ 账号是一个组合读屏元素；框内主文字色（账号）墨迹就是号码（「并入到」是次文字色）
            guard let block = DigitsWrapBindPendingTests.smallest(nodes.filter { $0.label.contains(intoLabel) }) else {
                XCTFail("[\(tier)] 读屏树里找不到并号信息块（「\(intoLabel)」）："
                    + "\(nodes.prefix(40).map { $0.id.isEmpty ? $0.label : $0.id })")
                continue
            }
            let problems = await judge(canvas, block, intoLabel, "\(tier)")
            XCTAssertEqual(problems, [], "并号弹窗 \(tier)")
        }
    }
}
