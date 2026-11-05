@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-b 提现记录视觉用例的公共底座。继承钱包 a 组底座（几何 / 字号 / 命中区 / 像素 / 参考图标判据同一份），测量改从记录页宿主取。
/// 每个页面一个新的偏好套件与缓存目录；网络是生产 WalletStubProtocol + `RecordsVisualServer`。
@MainActor
class RecordsVisualTestCase: WalletVisualTestCase {
    var records: RecordsVisualHost?

    override func tearDown() async throws {
        records?.close()
        records = nil
        try await super.tearDown()
    }

    func freshRecords() throws -> RecordsVisualHost {
        records?.close()
        records = nil
        WalletStubProtocol.reset()
        if !suiteName.isEmpty {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        suiteName = "records-visual-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let server = try RecordsVisualServer(nowMillis: RecordsVisualData.nowMillis())
        try server.setDetails(RecordsVisualData.detailsById())
        server.install()
        let page = RecordsVisualHost(suiteName: suiteName, defaults: defaults, server: server)
        records = page
        return page
    }

    /// 用 visualWithdrawRecords 的一份列表打开记录页，按顺序展开 `expand` 里的单并等稳定。
    /// 就绪 = 执行器到 `phase`、`waitFor` 测量已上报、每张展开单的详情已到且 `records.detail.<id>` 已上报（`needProbes` = false 时只等
    /// 执行器：资金回归守卫不能把「测量桥未接」混进来，a 组 v1 经验）。
    @discardableResult
    func openRecords(_ pageName: String = "list", focus: String? = nil, expand: [String] = [],
                     canvas: RecordsVisualHost.Canvas = .init(), waitFor: String? = nil,
                     phase: RecordsSnapshot.Phase = .content, needProbes: Bool = true,
                     file: StaticString = #filePath,
                     line: UInt = #line) async throws -> (RecordsVisualHost, UIImage) {
        let page = try freshRecords()
        try page.server.setPage(RecordsVisualData.page(pageName))
        try await page.show(focus: focus, canvas)
        var image = await page.stable(file: file, line: line) { host in
            host.controller?.state.phase == phase && (waitFor.map { host.probes[$0] != nil } ?? true)
        }
        for id in expand {
            if page.controller?.state.expanded.contains(id) != true {
                try page.toggle(id)
            }
            image = await page.stable(file: file, line: line) { host in
                host.controller?.state.details[id] != nil && (!needProbes || host.probes["records.detail.\(id)"] != nil)
                    && (waitFor.map { host.probes[$0] != nil } ?? true)
            }
        }
        return try (page, XCTUnwrap(image, "记录页没有截到稳定画面", file: file, line: line))
    }

    /// v2 / T1：时效句的期望值 = App 此刻生效配置里的 `texts.withdraw.sla_text`（生产 `AppWallet.configText`，与
    /// `AppWallet+Pages.recordsEntry` 同一来源；宿主经生产路径下发 `RecordsVisualServer.configuredSla`「工作日 24 小时内处理」，#24 升锁
    /// 00deded0ef6f）。
    /// 前提：它与 BR-TEXT-07 回落句不同——这样页面若不按配置取值（回落成默认句或写死），断言才会红。
    func appSla(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let page = try XCTUnwrap(records, "没有记录页宿主", file: file, line: line)
        let value = try XCTUnwrap(page.wallet.configText("withdraw.sla_text"), "App 生效配置里没有 texts.withdraw.sla_text",
                                  file: file, line: line)
        XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "配置的时效句为空", file: file, line: line)
        XCTAssertNotEqual(value, texts.text(WithdrawRulesView.slaDefaultKey),
                          "前提：配置值要与 BR-TEXT-07 回落句不同，才能区分「按配置取值」", file: file, line: line)
        return value
    }

    // MARK: - 测量（从记录页宿主取）

    override func record(_ id: String, file: StaticString = #filePath,
                         line: UInt = #line) throws -> CouliLayoutProbeRecord {
        try XCTUnwrap(records?.probes[id], "缺测量 \(id)（§4 测量桥）", file: file, line: line)
    }

    override func rect(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        try record(id, file: file, line: line).rect
    }

    /// 记录页全部测量里显示的文字。
    var recordTexts: [String] {
        records?.probes.records.values.map(\.text).filter { !$0.isEmpty } ?? []
    }

    /// 某前缀下全部测量（不含前缀本身）。
    func probes(prefix: String) -> [String: CouliLayoutProbeRecord] {
        records?.probes.records.filter { $0.key.hasPrefix(prefix) } ?? [:]
    }

    func viewport(file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        try XCTUnwrap(records?.viewport, "记录页没有可滚动的列表", file: file, line: line)
    }

    /// 可换行文字不截断：自然宽 > 实际宽时，实际高至少容纳 ⌈自然宽 ÷ 实际宽⌉ 行（行高按字号 × 1.1 下限）；字号不缩。
    func assertNotTruncated(_ id: String, _ message: String, file: StaticString = #filePath,
                            line: UInt = #line) throws {
        let item = try record(id, file: file, line: line)
        XCTAssertGreaterThan(item.naturalWidth, 0, "\(message)：要报单行自然宽（couliTextNaturalProbe）", file: file,
                             line: line)
        XCTAssertGreaterThanOrEqual(item.fontSize + 0.01, item.baseFontSize, "\(message)：字号不缩", file: file,
                                    line: line)
        guard item.rect.width > 1 else {
            XCTFail("\(message)：宽为 0", file: file, line: line)
            return
        }
        let lines = (item.naturalWidth / item.rect.width).rounded(.up)
        XCTAssertGreaterThanOrEqual(item.rect.height + 0.5, lines * item.fontSize * 1.1,
                                    "\(message)：自然宽 \(item.naturalWidth) / 宽 \(item.rect.width) 需 \(lines) 行，实际高 "
                                        + "\(item.rect.height)（被截断 / 限行）", file: file, line: line)
    }

    /// 区域里有一条横向的 1pt 分隔线（`border.subtle` 令牌色，覆盖区域宽的一半以上）。
    func hasDivider(_ image: UIImage, between top: CGFloat, and bottom: CGFloat, span: ClosedRange<CGFloat>,
                    dark: Bool = false) -> Bool {
        let pixels = ProductVisualPixels(image)
        let line = pixel(CouliColor.borderSubtle, dark: dark)
        var top = top
        while top <= bottom {
            let row = pixels.row(at: top, from: span.lowerBound, to: span.upperBound)
            if !row.isEmpty, Double(row.filter { $0.near(line, tolerance: 8) }.count) / Double(row.count) > 0.5 {
                return true
            }
            top += 1 / pixels.scale
        }
        return false
    }

    /// 文字的墨迹以某颜色为主（墨迹像素里接近 `color` 的比离 `other` 近的多）。
    func inkMostly(_ image: UIImage, in rect: CGRect, _ color: Color, not other: Color, dark: Bool = false) -> Bool {
        let first = count(image, in: rect, near: pixel(color, dark: dark), tolerance: 30)
        let second = count(image, in: rect, near: pixel(other, dark: dark), tolerance: 30)
        return first > 10 && first > second
    }
}
