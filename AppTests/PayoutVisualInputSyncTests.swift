@testable import Couli
import Foundation
import SwiftUI
import UIKit
@testable import Wallet
import XCTest

/// 输入框对回读「执行器当前值」，不读渲染快照（c 组评审 S2-1；实现变异 M38 存活）。真实竞态只有不到一帧，这里把两个值人为错开，
/// 不靠抢时序：`value` 固定是旧快照，`current` 给更新的值。对回读快照时框里停在旧值，判据分得开。
extension PayoutVisualMoneyTests {
    @MainActor
    private final class Model {
        var seen: [String] = []
    }

    private func textField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField {
            return field
        }
        for child in view.subviews {
            if let field = textField(in: child) {
                return field
            }
        }
        return nil
    }

    /// 被拒的输入对回到执行器当前值，不是渲染时的旧值。
    func testRejectedInputSyncsToCurrentNotSnapshot() async throws {
        let model = Model()
        let input = WalletInputField(
            placeholder: "", label: "sync", identifier: "sync", probe: "sync", value: "12", current: { "123" },
            hasError: false, hint: "", set: { model.seen.append($0) }, reveal: {}
        )
        let host = UIHostingController(rootView: input.padding())
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        window.windowLevel = .alert + 2
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        await waitUntil("没有渲染出输入框") {
            window.layoutIfNeeded()
            return self.textField(in: window) != nil
        }
        let field = try XCTUnwrap(textField(in: window))
        XCTAssertTrue(field.becomeFirstResponder(), "前提：拿到第一响应者")
        await settle()
        field.insertText("x")
        // 写入口会收到重复调用（e8 实测 ["123", "123", "123x", "123x"]：对回后系统回写一次、每次输入 SwiftUI 回调两次），次数不是这条的判据
        await waitUntil("输入没有到达写入口（判据通道不通，不是实现问题）") { model.seen.contains { $0.hasSuffix("x") } }
        await waitUntil("框内没有对回执行器当前值") { field.text == "123" }
        XCTAssertEqual(field.text, "123", "读当前值，不读渲染快照")
    }

    /// G-W21：缺 `change_remaining_this_month` 的账号走读取失败：没有【更换】、不开表单、零写（iOS 替代 UI 用例 testNullRemainingStaysEnabled）。
    func testMissingRemainingFailsRead() async throws {
        let raw = try PayoutVisualData.payoutBody("boundAlipay")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        object["change_remaining_this_month"] = nil
        let body = try WithdrawVisualData.json(object)
        let (host, _) = try await openPayout(read: .envelope(code: 0, data: body, headers: [:]),
                                             waitFor: "payout.error")
        XCTAssertEqual(host.payout?.state.phase, .error, "缺必填字段按读取失败")
        XCTAssertFalse(has("payout.change"), "没有【更换】")
        XCTAssertFalse(has("payout.intro"), "不当成未绑定开表单")
        XCTAssertEqual(writes, [], "零写")
    }
}
