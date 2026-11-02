@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// 关于页版式（brief §2 第 9–12 条，G-P10、G-P11、G-P23）。数值实量自 About-v2（头部上 24 下 8；块间 16）。
@MainActor
final class PrivacyVisualAboutTests: PrivacyVisualTestCase {
    private typealias Board = PrivacyVisualData.Board

    /// 头部：内容上 8 + 头部上 24 → 图标 80 → 8 → 名字 17/600 → 8 → 版本 14；下 8。
    func testHeader() async throws {
        try await openAbout(waitFor: "about.versionText")
        let icon = try rect("about.icon")
        let name = try rect("about.name")
        let version = try record("about.versionText")
        assertNear(icon.width, Board.aboutIcon, 1, "图标 80（现状 80）")
        assertNear(icon.height, Board.aboutIcon, 1, "图标 80")
        assertNear(icon.midX, 195, 1, "居中")
        try assertNear(icon.minY - navBottom(), 32, 2, "8 + 24")
        assertNear(name.minY - icon.maxY, 8, 1.5, "图标到名字 8")
        assertNear(name.midX, 195, 1.5, "名字居中")
        assertNear(version.rect.minY - name.maxY, 8, 1.5, "名字到版本 8")
        try assertBase("about.name", 17, "名字 17（现状 22）")
        try assertBase("about.versionText", 14, "版本 14")
        // v2：真实组装取 Bundle（工程 CFBundleVersion = 1，`AppMe+Env` 被钉），fixture 的构建号 100 进不来；版本号仍比 fixture，文字形状比生产模板
        XCTAssertEqual(try about.version, try PrivacyVisualData.about("version") as? String, "版本号")
        XCTAssertEqual(version.text, "版本 \(try about.version)（\(try about.build)）")
        XCTAssertNotNil(version.text.range(of: #"^版本 \d+\.\d+\.\d+（\d+）$"#, options: .regularExpression), "全角括号")
    }

    /// G-P10：品牌色块 + 反白主图形（不再是 muted 底 + 品牌色文字），深色不变色。圆角 16 或 18 都算（令牌无 18，compare 记）。
    func testIconIsBrandBlock() async throws {
        let image = try await openAbout(waitFor: "about.icon")
        let icon = try rect("about.icon")
        let brand = pixel(CouliColor.brandPrimary, dark: false)
        let edge = CGRect(x: icon.minX + 20, y: icon.minY + 2, width: 40, height: 6)
        assertFill(image, edge, brand, "品牌色底", tolerance: 6)
        let white = ProductVisualPixels.RGB(red: 255, green: 255, blue: 255)
        XCTAssertGreaterThan(count(image, in: icon.insetBy(dx: 12, dy: 12), near: white, tolerance: 12), 200, "白色主图形")
        let corner = CGRect(x: icon.minX, y: icon.minY, width: 3, height: 3)
        assertFill(image, corner, pixel(CouliColor.backgroundCanvas, dark: false), "圆角外是页底", tolerance: 8)
    }

    /// G-P11：分组名 12 次文字在卡外（缩进 4、到卡 8），卡内 12/16、正文 14 主文字原样。
    func testFilingSection() async throws {
        let image = try await openAbout(waitFor: "about.filing.text")
        let heading = try rect("about.filing.title")
        let card = try rect("about.filing.card")
        let body = try record("about.filing.text")
        XCTAssertEqual(body.text, try PrivacyVisualData.about("filed") as? String, "原样，不拼接")
        assertNear(heading.minX, 20, 1, "分组名缩进 4")
        XCTAssertLessThanOrEqual(heading.maxY, card.minY + 0.5, "分组名在卡外")
        assertNear(card.minY - heading.maxY, 8, 1.5, "名到卡 8")
        assertNear(card.minX, Board.side, 1, "卡左 16")
        assertNear(card.width, Board.width, 1, "通栏")
        assertNear(body.rect.minX - card.minX, 16, 1, "卡内左 16")
        assertNear(body.rect.minY - card.minY, 12, 2, "卡内上 12")
        assertNear(card.maxY - body.rect.maxY, 12, 2, "卡内下 12")
        try assertBase("about.filing.title", 12, "分组名 12（现状 17）")
        try assertBase("about.filing.text", 14, "正文 14（现状 12）")
        try assertInk(image, "about.filing.text", CouliColor.textPrimary, "正文主文字（现状次文字）")
        try assertInk(image, "about.filing.title", CouliColor.textSecondary, "分组名次文字")
    }

    /// 通栏次按钮带 20 复制图标（间距 8）→ 8 → 居中说明 12；块间 16。
    func testCopyBlock() async throws {
        let image = try await openAbout(waitFor: "about.copy.desc")
        let card = try rect("about.filing.card")
        let button = try rect("about.copy.button")
        let icon = try rect("about.copy.icon")
        let label = try record("about.copy.label")
        let desc = try rect("about.copy.desc")
        assertNear(button.minY - card.maxY, 16, 2, "块间 16")
        assertNear(button.width, Board.width, 1, "通栏")
        XCTAssertGreaterThanOrEqual(button.height, 47.5, "min 48")
        assertNear(icon.width, 20, 1, "图标 20")
        assertNear(label.rect.minX - icon.maxX, 8, 1.5, "图标到文字 8")
        XCTAssertEqual(label.text, "复制诊断信息")
        assertNear((icon.minX + label.rect.maxX) / 2, 195, 2, "图标 + 文字整体居中")
        assertNear(desc.minY - button.maxY, 8, 1.5, "按钮到说明 8")
        assertNear(desc.midX, 195, 1.5, "说明居中（现状靠左）")
        try assertBase("about.copy.desc", 12, "说明 12（现状 14）")
        try assertSecondary(image, "about.copy.button", "【复制诊断信息】")
        let found = await nearestSymbol(image, in: icon, candidates: ["doc.on.doc", "link", "info.circle"],
                                        background: CouliColor.backgroundSurface, ink: CouliColor.textPrimary)
        XCTAssertEqual(found, "doc.on.doc", "系统图标集（D10-559）")
    }

    /// 登记前：AI 公示整节不显示，按钮块直接接头部；备案号行不显示（G-P23）。
    func testBeforeFilingHidesSection() async throws {
        try await openAbout(filed: false, waitFor: "about.copy.button")
        XCTAssertFalse(has("about.filing.title"), "整节不显示")
        XCTAssertFalse(has("about.filing.card"))
        XCTAssertFalse(has("about.icp"), "G-P23")
        try assertNear(rect("about.copy.button").minY - rect("about.versionText").maxY, 8 + 16, 2.5, "头部下 8 + 块间 16")
    }
}
