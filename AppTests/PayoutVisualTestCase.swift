@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-e 视觉用例底座：继承 c 组底座（真实 App 组装、测量、像素、写请求计数同一份）。
/// 三页都走真实 Router → 生产 `WalletRouteView` → 生产执行器；替身只有传输层与实名 / 劳务两个 Debug 手写后端（G-W24）。
/// 操作走页面同一份渲染时回调（`PayoutActions.make` 等）；真实点击计数在 UITests。
@MainActor
class PayoutVisualTestCase: WithdrawVisualTestCase {
    var payoutServer: PayoutVisualServer?
    var realBackend: VisualRealNameBackend?
    var laborBackend: VisualLaborBackend?

    override func tearDown() async throws {
        realBackend?.release()
        laborBackend?.release()
        await settle()
        try await super.tearDown()
    }

    /// 打开收款账号页。`editing`：已绑定时走一次【更换收款账号】回调进表单。`needProbes` = false：资金守卫只等执行器，不把「测量桥未接」混进来。
    @discardableResult
    func openPayout(_ payout: String = "unbound", editing: Bool = false, method: String? = nil,
                    read: WalletStubProtocol.Reply? = nil, canvas: WithdrawVisualHost.Canvas = .init(),
                    waitFor: String? = nil, needProbes: Bool = true,
                    file: StaticString = #filePath, line: UInt = #line) async throws -> (WithdrawVisualHost, UIImage) {
        let host = try await freshPage(payout: "empty")
        let server = try PayoutVisualServer(base: host.server, payout: payout,
                                            nowMillis: PayoutVisualData.nowMillis())
        server.setRead(read)
        server.install()
        payoutServer = server
        try await host.show(WalletRoutes.payoutAccount, canvas)
        if read != nil, let wanted = waitFor {
            let spinning = await host.stable(motion: true, file: file, line: line) { $0.probes[wanted] != nil }
            return try (host, XCTUnwrap(spinning, "收款账号页没有截到稳定画面", file: file, line: line))
        }
        await waitUntil("收款账号没有读到", file: file, line: line) { host.payout?.state.phase == .content }
        if editing {
            host.payoutActions?.change()
        }
        if let method {
            host.payoutActions?.method(method)
        }
        let bound = payout != "unbound" && !editing
        let wanted = waitFor ?? (bound ? "payout.boundCard" : "payout.intro")
        let image = await host.stable(file: file, line: line) { page in
            page.payout?.state.phase == .content && (!needProbes || page.probes[wanted] != nil)
        }
        return try (host, XCTUnwrap(image, "收款账号页没有截到稳定画面", file: file, line: line))
    }

    /// 与页面同一回调填好支付宝表单。
    func fillAlipay(_ host: WithdrawVisualHost) throws {
        let form = try PayoutVisualData.form("alipay")
        try host.payoutActions?.logon(XCTUnwrap(form["alipayAccount"]))
        try host.payoutActions?.payee(XCTUnwrap(form["payeeName"]))
    }

    func fillBank(_ host: WithdrawVisualHost) throws {
        let form = try PayoutVisualData.form("bank")
        host.payoutActions?.method(WalletJSON.bankCard)
        try host.payoutActions?.card(XCTUnwrap(form["cardNo"]))
        try host.payoutActions?.bank(XCTUnwrap(form["bankName"]))
        try host.payoutActions?.payee(XCTUnwrap(form["payeeName"]))
    }

    /// 未绑定 → 填表 → 保存，回答 `reply`。
    func openAndSave(_ reply: WalletStubProtocol.Reply, needProbes: Bool = true, file: StaticString = #filePath,
                     line: UInt = #line) async throws -> WithdrawVisualHost {
        let (host, _) = try await openPayout(needProbes: needProbes, file: file, line: line)
        host.server.script.on("PUT /v1/me/payout-account", reply)
        host.grantStepUp()
        try fillAlipay(host)
        host.payoutActions?.save()
        return host
    }

    var saves: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("PUT", "/v1/me/payout-account")
    }

    /// 打开实名页。`backend` = false：没有实名后端（显式 `installBackends(realname: nil)`，「暂未开放」）。`filled`：填好 fixture 表单。
    @discardableResult
    func openRealName(filled: Bool = true, backend: Bool = true, canvas: WithdrawVisualHost.Canvas = .init(),
                      waitFor: String? = "realname.header", needProbes: Bool = true, file: StaticString = #filePath,
                      line: UInt = #line) async throws -> (WithdrawVisualHost, UIImage) {
        let host = try await freshPage(payout: "empty")
        if backend {
            let fake = VisualRealNameBackend()
            realBackend = fake
            host.wallet.installBackends(realname: fake, labor: nil)
        } else {
            host.wallet.installBackends(realname: nil, labor: nil)
        }
        try await host.show(WalletRoutes.realName, canvas)
        await waitUntil("实名页没有打开", file: file, line: line) { host.realName != nil }
        if filled {
            let form = try PayoutVisualData.realnameForm()
            host.realNameActions?.name(form.name)
            host.realNameActions?.idNo(form.idNo)
        }
        let image = await host.stable(file: file, line: line) { page in
            page.realName != nil && (!needProbes || waitFor.map { page.probes[$0] != nil } ?? true)
        }
        return try (host, XCTUnwrap(image, "实名页没有截到稳定画面", file: file, line: line))
    }

    /// 【提交认证】→ 单独同意半屏打开（默认不勾选）。
    func openConsent(_ host: WithdrawVisualHost, waitFor: String? = "consent.title", needProbes: Bool = true,
                     file: StaticString = #filePath, line: UInt = #line) async throws -> UIImage {
        host.realNameActions?.submit()
        let image = await host.stable(file: file, line: line) { page in
            page.realName?.state.consentId != nil && (!needProbes || waitFor.map { page.probes[$0] != nil } ?? true)
        }
        return try XCTUnwrap(image, "同意半屏没有截到稳定画面", file: file, line: line)
    }

    /// 同意半屏里勾选 + 【同意并继续】，等结果落定。
    func agree(_ host: WithdrawVisualHost, file: StaticString = #filePath, line: UInt = #line) async {
        host.realNameActions?.toggleConsent()
        host.realNameActions?.agree()
        await waitUntil("提交没有结束", file: file, line: line) { host.realName?.state.submitting == false }
    }

    /// 打开劳务协议页。`backend` = false：Release 形态。
    @discardableResult
    func openLabor(backend: Bool = true, canvas: WithdrawVisualHost.Canvas = .init(), waitFor: String? = "labor.intro",
                   needProbes: Bool = true, phase: LaborSnapshot.Phase? = .content, motion: Bool = false,
                   prepare: (VisualLaborBackend) -> Void = { _ in }, file: StaticString = #filePath,
                   line: UInt = #line) async throws -> (WithdrawVisualHost, UIImage) {
        let host = try await freshPage(payout: "empty")
        if backend {
            let fake = try VisualLaborBackend()
            laborBackend = fake
            prepare(fake)
            host.wallet.installBackends(realname: nil, labor: fake)
        }
        try await host.show(WalletRoutes.laborAgreement, canvas)
        await waitUntil("劳务页没有打开", file: file, line: line) { host.laborPage != nil }
        let image = await host.stable(motion: motion, file: file, line: line) { page in
            (phase == nil || page.laborPage?.state.phase == phase)
                && (!needProbes || waitFor.map { page.probes[$0] != nil } ?? true)
        }
        return try (host, XCTUnwrap(image, "劳务页没有截到稳定画面", file: file, line: line))
    }

    // MARK: - 判据

    /// 卡左右 16（`width` = 画布宽）。
    func assertSideInsets(_ id: String, width: CGFloat = 390, _ message: String, file: StaticString = #filePath,
                          line: UInt = #line) throws {
        let box = try rect(id, file: file, line: line)
        assertNear(box.minX, 16, 0.5, "\(message)：左 16", file: file, line: line)
        assertNear(width - box.maxX, 16, 0.5, "\(message)：右 16", file: file, line: line)
    }

    /// INFO 条（brief §2）：卡外、`background.muted` 底、圆角 12 内 12、20 次文字色图标、14 主文字。
    func assertInfoBar(_ id: String, image: UIImage, dark: Bool = false, _ message: String,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        try background(image, id, CouliColor.backgroundMuted, dark: dark, minimum: 0.4, "\(message)：INFO 底",
                       file: file, line: line)
        let icon = try rect("\(id).icon", file: file, line: line)
        assertNear(icon.width, 20, 1, "\(message)：图标 20", file: file, line: line)
        // 浅色 muted #EFEAE2 与画布 #F2EEE6 只差 3、4、4，上面容差 6 分不开（变异 M23 存活）；取图标左侧的内边距带，容差 1
        let strip = try rect(id, file: file, line: line)
        let band = CGRect(x: strip.minX + 3, y: strip.minY + 14, width: 7, height: max(strip.height - 28, 4))
        let fill = share(image, in: band, near: pixel(CouliColor.backgroundMuted, dark: dark), tolerance: 1)
        XCTAssertGreaterThan(fill, 0.9, "\(message)：INFO 底不是 background.muted，占比 \(fill)", file: file, line: line)
        try assertBase("\(id).text", 14, "\(message)：字 14", file: file, line: line)
        let bar = try rect(id, file: file, line: line)
        assertNear(icon.minX - bar.minX, 12, 1, "\(message)：内边距 12", file: file, line: line)
        try XCTAssertTrue(inkMostly(image, in: rect("\(id).text", file: file, line: line), CouliColor.textPrimary,
                                    not: CouliColor.textSecondary, dark: dark), "\(message)：主文字色",
                          file: file, line: line)
    }

    /// 字段：标签 14 → 框间距 8、视觉高 48。
    func assertField(_ name: String, _ prefix: String, _ message: String, file: StaticString = #filePath,
                     line: UInt = #line) throws {
        let label = try rect("\(prefix).field.\(name).label", file: file, line: line)
        let box = try rect("\(prefix).field.\(name).box", file: file, line: line)
        try assertBase("\(prefix).field.\(name).label", 14, "\(message)：标签 14", file: file, line: line)
        assertNear(box.minY - label.maxY, 8, 1, "\(message)：标签与框 8", file: file, line: line)
        assertNear(box.height, 48, 1, "\(message)：框高 48", file: file, line: line)
    }

    /// 圆形判据：实心时外接框四角（内缩 12%）不是填充色、四边中点内缩 2 是填充色。圆角方块的角落仍是填充色，分得开（自证见 Oracle）。
    func assertRound(_ image: UIImage, _ id: String, fill: Color, dark: Bool = false, _ message: String,
                     file: StaticString = #filePath, line: UInt = #line) throws {
        let box = try rect(id, file: file, line: line)
        XCTAssertTrue(PayoutVisualJudges.isRound(image, box, fill: pixel(fill, dark: dark)), "\(message)：不是圆形 \(box)",
                      file: file, line: line)
    }

    /// 勾选行（W94 / W100）：圆 18、14 主文字、视觉行不被命中区撑高、命中 ≥ 44、默认不勾。`prefix` = consent.check / labor.check。
    func assertCheckRow(_ prefix: String, image: UIImage, file: StaticString = #filePath, line: UInt = #line) throws {
        let mark = try rect("\(prefix).mark", file: file, line: line)
        assertNear(mark.width, 18, 1, "\(prefix)：圆 18", file: file, line: line)
        assertNear(mark.height, 18, 1, "\(prefix)：圆 18", file: file, line: line)
        try assertBase("\(prefix).text", 14, "\(prefix)：字 14", file: file, line: line)
        try XCTAssertLessThanOrEqual(rect(prefix, file: file, line: line).height, 26,
                                     "\(prefix)：视觉行不被命中区撑高", file: file, line: line)
        try assertHit("\(prefix).hit", covers: prefix, prefix, file: file, line: line)
        try XCTAssertTrue(inkMostly(image, in: rect("\(prefix).text", file: file, line: line), CouliColor.textPrimary,
                                    not: CouliColor.textSecondary), "\(prefix)：主文字色", file: file, line: line)
    }
}

/// 可独立自证的像素判据。
@MainActor
enum PayoutVisualJudges {
    static func isRound(_ image: UIImage, _ box: CGRect, fill: ProductVisualPixels.RGB) -> Bool {
        let pixels = ProductVisualPixels(image)
        let dx = box.width * 0.12
        let dy = box.height * 0.12
        let corners = [
            CGPoint(x: box.minX + dx, y: box.minY + dy), CGPoint(x: box.maxX - dx, y: box.minY + dy),
            CGPoint(x: box.minX + dx, y: box.maxY - dy), CGPoint(x: box.maxX - dx, y: box.maxY - dy),
        ]
        let edges = [
            CGPoint(x: box.midX, y: box.minY + 2), CGPoint(x: box.midX, y: box.maxY - 2),
            CGPoint(x: box.minX + 2, y: box.midY), CGPoint(x: box.maxX - 2, y: box.midY),
        ]
        return corners.allSatisfy { !pixels.color(at: $0).near(fill, tolerance: 40) }
            && edges.allSatisfy { pixels.color(at: $0).near(fill, tolerance: 40) }
    }

    /// 选中单选圈（W71）：外径 24、品牌描边 7、圈心白：外缘内缩 5 仍是品牌色，内缩 7.6 与圆心是 `center` 色（白心半径 5；底版小白点半径约 3.7，此处仍是品牌色）。
    static func isThickRing(_ image: UIImage, _ box: CGRect, ring: ProductVisualPixels.RGB,
                            center: ProductVisualPixels.RGB) -> Bool {
        let pixels = ProductVisualPixels(image)
        let points = [
            CGPoint(x: box.midX, y: box.minY + 5), CGPoint(x: box.midX, y: box.maxY - 5),
            CGPoint(x: box.minX + 5, y: box.midY), CGPoint(x: box.maxX - 5, y: box.midY),
        ]
        return points.allSatisfy { pixels.color(at: $0).near(ring, tolerance: 40) }
            && pixels.color(at: CGPoint(x: box.midX, y: box.midY)).near(center, tolerance: 40)
            && pixels.color(at: CGPoint(x: box.midX, y: box.minY + 7.6)).near(center, tolerance: 40)
    }
}
