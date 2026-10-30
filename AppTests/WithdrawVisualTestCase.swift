@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-c 提现页视觉用例的公共底座。继承记录页底座（几何 / 字号 / 命中区 / 像素 / 分隔线 / 不截断判据同一份），测量改从提现页宿主取。
/// 每个页面一个新的偏好套件与缓存目录；网络是生产 WalletStubProtocol + `WithdrawVisualServer`。
@MainActor
class WithdrawVisualTestCase: RecordsVisualTestCase {
    var page: WithdrawVisualHost?
    /// 同一份未决记录后端（模拟杀进程冷启动：新组合读同一份本机记录）。
    var pendingBackend = MemoryPendingKeyBackend()

    /// 放掉挂起的假请求：组合销毁后 URLSession 才超时的话，迟到的完成回调会读到已销毁的对象（c3 实测崩在下一个用例）。
    func releaseHeld() async {
        WalletStubProtocol.heldIds.forEach { WalletStubProtocol.release($0, with: .disconnect) }
        await settle()
    }

    override func tearDown() async throws {
        await releaseHeld()
        page?.close()
        page = nil
        pendingBackend = MemoryPendingKeyBackend()
        try await super.tearDown()
    }

    /// 新组合。缺省带「提现规则」配置（画板有这条链接），时效句不下发（回落 BR-TEXT-07 = 画板句）。
    func freshPage(help: Bool = true, sla: String? = nil, rules: String = "normal", estimate: String? = nil,
                   payout: String = "bound") async throws -> WithdrawVisualHost {
        await releaseHeld()
        page?.close()
        page = nil
        WalletStubProtocol.reset()
        if !suiteName.isEmpty {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        suiteName = "withdraw-visual-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let server = try WithdrawVisualServer(nowMillis: WithdrawVisualData.nowMillis())
        try server.setRules(rules)
        try server.setEstimate(estimate)
        try server.setPayout(payout)
        server.install()
        let host = WithdrawVisualHost(suiteName: suiteName, defaults: defaults, server: server, pending: pendingBackend)
        page = host
        try await host.configure(help: help, sla: sla)
        return host
    }

    /// 打开提现页并等稳定。就绪 = 执行器到 `phase` 且 `waitFor` 测量已上报（`needProbes` = false 时只等执行器：资金回归守卫不能把
    /// 「测量桥未接」混进来，a 组 v1 经验）。`amount`：与页面同一回调输入金额，并等估算落定；此时 `waitFor` 是**输入之后**才等的
    /// （估算行这类测量输入前本来就不存在，v2 / T1），进页阶段只等余额卡。
    @discardableResult
    func openWithdraw(_ rules: String = "normal", amount: String? = nil, estimate: String? = nil, help: Bool = true,
                      sla: String? = nil, payout: String = "bound", canvas: WithdrawVisualHost.Canvas = .init(),
                      waitFor: String? = "withdraw.balance", needProbes: Bool = true, file: StaticString = #filePath,
                      line: UInt = #line) async throws -> (WithdrawVisualHost, UIImage) {
        let host = try await freshPage(help: help, sla: sla, rules: rules, estimate: estimate, payout: payout)
        try await host.show(WalletRoutes.withdraw, canvas)
        var image = await host.stable(file: file, line: line) { page in
            page.controller?.state.phase == .content && page.controller?.state.rules != nil
                &&
                (!needProbes || (amount == nil ? waitFor : "withdraw.balance")
                    .map { page.probes[$0] != nil } ?? true)
        }
        if let amount {
            image = try await enter(amount, file: file, line: line)
            if needProbes, let waitFor {
                image = await host.stable(file: file, line: line) { $0.probes[waitFor] != nil }
            }
        }
        return try (host, XCTUnwrap(image, "提现页没有截到稳定画面", file: file, line: line))
    }

    /// 与页面同一回调输入金额，等估算落定（显示或隐藏）。
    @discardableResult
    func enter(_ text: String, file: StaticString = #filePath, line: UInt = #line) async throws -> UIImage? {
        let host = try XCTUnwrap(page, file: file, line: line)
        host.actions?.amount(text)
        return await host.stable(file: file, line: line) { page in
            guard let state = page.controller?.state else { return false }
            return state.amountText == text && state.estimate != .calculating
        }
    }

    /// 提交断连 → 结果未知 → 待确认卡（生产路径）。
    func enterPending(amount: String = "10", file: StaticString = #filePath, line: UInt = #line) async throws {
        let host = try XCTUnwrap(page, file: file, line: line)
        host.server.script.on("POST /v1/withdrawals", .disconnect)
        try await enter(amount, file: file, line: line)
        host.actions?.submit()
        await waitUntil("没有进入待确认", timeout: 8, file: file, line: line) {
            host.flow?.state.pending != nil && host.flow?.state.phase == .pending
        }
    }

    // MARK: - 测量（从提现页宿主取）

    override func record(_ id: String, file: StaticString = #filePath,
                         line: UInt = #line) throws -> CouliLayoutProbeRecord {
        try XCTUnwrap(page?.probes[id], "缺测量 \(id)（§4 测量桥）", file: file, line: line)
    }

    override func rect(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        try record(id, file: file, line: line).rect
    }

    func has(_ id: String) -> Bool {
        page?.probes[id] != nil
    }

    var pageTexts: [String] {
        page?.probes.records.values.map(\.text).filter { !$0.isEmpty } ?? []
    }

    func pageViewport(file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        try XCTUnwrap(page?.viewport, "提现页没有可滚动的内容", file: file, line: line)
    }

    func background(_ image: UIImage, _ id: String, _ color: Color, dark: Bool = false, minimum: Double = 0.5,
                    _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try share(image, in: rect(id, file: file, line: line).insetBy(dx: 2, dy: 2),
                              near: pixel(color, dark: dark), tolerance: 6)
        XCTAssertGreaterThan(value, minimum, "\(message)：底色占比 \(value)", file: file, line: line)
    }

    // MARK: - 请求计数

    var submits: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("POST", "/v1/withdrawals")
    }

    var abandons: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("POST", "/v1/idempotency-keys/abandon")
    }

    /// 全部写请求（提现页、收款账号页）。
    var writes: [String] {
        WalletStubProtocol.requests.filter { $0.method != "GET" && $0.path != "/v1/devices" }
            .map { "\($0.method) \($0.path)" }
    }
}
