@testable import Couli
import Foundation
import Wallet
import WalletCore
import XCTest

/// 单独同意半屏的线程崩溃（e3 实测，`~/Library/Logs/DiagnosticReports/Couli-2026-10-31-155725.ips`）：半屏出入场动画期间 SwiftUI 在
/// `com.apple.SwiftUI.AsyncRenderer` 线程求值 `ForEach` 内容闭包，闭包继承 `@MainActor`，Swift 6 运行时隔离检查 SIGTRAP。
/// 底版既有问题，不是视觉改动引入。崩溃时整个测试进程退出，所以单独成类，不和资金守卫混跑结论。
@MainActor
final class PayoutVisualConsentCrashTests: PayoutVisualTestCase {
    /// 逐字照 `testDeclineWritesNothingKeepsInput` 的时序（e3、e4 都在那条用例崩）：勾选、关闭、只等 0.2 秒（= 退场动画时长）、再打开。
    /// 0.08 秒连开 40 次、关闭后等 0.4 秒都崩不了，时序窗口很窄。
    /// **绿不等于修好**：实现者 M39（ForEach 放回内层）跑 1 轮也绿。修法要靠 v3 交回 §2 的多轮对照证明，这条只是探针。
    func testConsentReopenRightAfterClose() async throws {
        let (host, _) = try await openRealName(needProbes: false)
        for _ in 0..<5 {
            _ = try await openConsent(host, needProbes: false)
            host.realNameActions?.toggleConsent()
            host.realNameActions?.decline()
            await quietWindow(0.2)
        }
        XCTAssertNil(host.realName?.state.consentId)
        XCTAssertEqual(realBackend?.calls.count, 0, "开关半屏零提交")
    }

    /// 字面守卫：实名页源码（含抽出去的 helper）不用 `ForEach`：半屏内容在出入场动画里会被异步渲染线程求值，闭包继承主线程隔离就会崩。
    /// v3：范围从 `consentSheet` 函数体放宽到整份实名页文件，要点挪进 helper 也查得到。
    func testConsentSheetHasNoForEachClosure() throws {
        let url = WalletVisualData.repo().appendingPathComponent("Packages/Features/Sources/Wallet")
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { $0.hasPrefix("Identity") || $0.hasPrefix("RealName") }
        XCTAssertFalse(names.isEmpty)
        let source = try names.map { try String(contentsOf: url.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(source.contains("func consentSheet"), "consentSheet 不见了")
        XCTAssertFalse(source.contains("ForEach("), "半屏内 ForEach 闭包会在异步渲染线程崩溃")
    }
}
