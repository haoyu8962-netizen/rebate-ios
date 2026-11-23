import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-AGREEMENT-CHECK-COMPONENT 组件用例：DesignSystem 协议勾选圆 `CouliCheckGlyph(checked:enabled:)`。
/// 规格来源：任务书「做法 1」——外观逐项等同收款页旧 CheckMark（18pt、@ScaledMetric(relativeTo: .footnote)、未勾 backgroundSurface 填 +
/// borderControl 1.5 描边、勾选 brandPrimary 实心 + backgroundSurface 色粗体勾 size/2），加禁用态（安卓 CheckboxGlyph 的禁用配色映射到
/// CouliColor 令牌），读屏隐藏。
/// 不做像素对比：尺寸用宿主量出的理想尺寸判，读屏隐藏用无障碍树判，颜色令牌与画法用去注释的组件源码判。
/// 524f89e 上组件不存在，本文件编译即红（整个 AppTests 目标随之编译不过）。
@MainActor
final class AgreementCheckComponentGlyphTests: XCTestCase {
    private var canvas: A11yCanvas?

    override func tearDown() {
        canvas?.close()
        canvas = nil
        super.tearDown()
    }

    /// 宿主量出的理想尺寸。
    private func measured(_ glyph: CouliCheckGlyph, _ size: DynamicTypeSize) -> CGSize {
        let host = UIHostingController(rootView: AnyView(glyph.environment(\.dynamicTypeSize, size)))
        return host.sizeThatFits(in: CGSize(width: 400, height: 400))
    }

    /// 默认字号 18×18；随 footnote 档缩放（AX3 按系统 footnote 曲线放大、xSmall 缩小）；勾选 / 未勾 / 禁用三态尺寸一致（换态不跳布局）。
    func testGlyphIsEighteenPointsAndScalesWithFootnote() {
        let states = [
            ("未勾", CouliCheckGlyph(checked: false)),
            ("勾选", CouliCheckGlyph(checked: true)),
            ("未勾禁用", CouliCheckGlyph(checked: false, enabled: false)),
            ("勾选禁用", CouliCheckGlyph(checked: true, enabled: false)),
        ]
        let metrics = UIFontMetrics(forTextStyle: .footnote)
        let ax3 = metrics.scaledValue(for: 18, compatibleWith: UITraitCollection(
            preferredContentSizeCategory: .accessibilityExtraLarge
        ))
        for (name, glyph) in states {
            let base = measured(glyph, .large)
            XCTAssertEqual(base.width, 18, accuracy: 0.5, "\(name)：默认字号直径 18")
            XCTAssertEqual(base.height, 18, accuracy: 0.5, "\(name)：默认字号直径 18（正圆）")
            let large = measured(glyph, .accessibility3)
            XCTAssertEqual(large.width, ax3, accuracy: 1, "\(name)：AX3 按 footnote 曲线放大到 \(ax3)")
            XCTAssertEqual(large.width, large.height, accuracy: 0.5, "\(name)：放大后仍是正圆")
            XCTAssertLessThan(measured(glyph, .xSmall).width, 18, "\(name)：xSmall 随 footnote 缩小")
        }
    }

    /// 读屏隐藏：勾选态的勾（SF Symbol）不得冒出「勾号」之类的读屏项；与文字合并时只读文字。
    func testGlyphIsHiddenFromVoiceOver() async throws {
        try A11yTree.enable(self)
        let page = VStack(spacing: 12) {
            CouliCheckGlyph(checked: true)
            CouliCheckGlyph(checked: false)
            CouliCheckGlyph(checked: true, enabled: false)
            CouliCheckGlyph(checked: false, enabled: false)
            Text(verbatim: "锚点")
            HStack {
                CouliCheckGlyph(checked: true)
                Text(verbatim: "整句")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("glyph.combined")
        }
        let canvas = A11yCanvas(AnyView(page))
        self.canvas = canvas
        await canvas.pump(0.6)
        let elements = A11yTree.elements(canvas.root)
        XCTAssertNotNil(elements.first { $0.label == "锚点" }, "前提：无障碍树已建出\n\(A11yTree.dump(elements))")
        let combined = try XCTUnwrap(A11yTree.node("glyph.combined", in: canvas.root), A11yTree.dump(elements))
        XCTAssertEqual(combined.label, "整句", "合并后只读文字，勾选圆不贡献读屏文字")
        let extra = elements.filter { $0.label != "锚点" && $0.id != "glyph.combined" }
        XCTAssertEqual(extra.map(\.description), [], "勾选圆自身不是读屏项（accessibilityHidden）")
    }

    /// 外观参数（去注释源码）：18pt footnote 缩放、圆形、三个颜色令牌、1.5 描边、粗体勾 size/2、读屏隐藏。
    func testGlyphSourceUsesSpecTokens() throws {
        let body = try AgreementCheckComponentSource.glyphSource()
        let required: [(String, String)] = [
            (#"@ScaledMetric\(\s*relativeTo:\s*\.footnote\s*\)"#, "@ScaledMetric(relativeTo: .footnote)"),
            (#"=\s*18(\.0)?\b"#, "基准直径 18"),
            (#"\bCircle\(\)"#, "圆形"),
            (#"CouliColor\.backgroundSurface\b"#, "未勾底色 / 勾色 backgroundSurface"),
            (#"CouliColor\.borderControl\b"#, "未勾描边 borderControl"),
            (#"CouliColor\.brandPrimary\b"#, "勾选实心 brandPrimary"),
            (#"\b1\.5\b"#, "描边 1.5"),
            (#"systemName:\s*"checkmark""#, "勾用 SF Symbol checkmark"),
            (#"weight:\s*\.bold"#, "勾粗体"),
            (#"\bsize\s*/\s*2\b"#, "勾字号 size/2"),
            (#"\.accessibilityHidden\(\s*true\s*\)"#, "读屏隐藏"),
        ]
        for (pattern, what) in required {
            XCTAssertNotNil(
                body.range(of: pattern, options: .regularExpression),
                "CouliCheckGlyph 缺：\(what)（\(pattern)）"
            )
        }
        XCTAssertNil(body.range(of: #"\bRoundedRectangle\b"#, options: .regularExpression), "勾选是圆，不是圆角方框")
        XCTAssertNil(body.range(of: #""checkmark\.(square|circle)"#, options: .regularExpression), "不用系统方框 / 圆勾符号")
    }

    /// 禁用态：源码里 `enabled` 真参与配色（不只是声明），且只用 CouliColor 令牌，不写死颜色。
    func testGlyphDisabledStateUsesDesignTokens() throws {
        let body = try AgreementCheckComponentSource.glyphSource()
        let uses = body.components(separatedBy: "enabled").count - 1
        XCTAssertGreaterThanOrEqual(uses, 2, "enabled 要参与禁用配色（声明之外至少再用一次）")
        let raw = [
            #"Color\(\s*(red|white|hue|uiColor|\.sRGB)"#,
            #"\bColor\.(white|black|gray|red|blue|orange|green|secondary|primary)\b"#,
            #"\.(foregroundColor|foregroundStyle|fill|strokeBorder)\(\s*\.(white|black|gray|secondary|primary)\b"#,
            #"\bUIColor\b"#,
            #"\.opacity\("#,
        ]
        for pattern in raw {
            XCTAssertNil(body.range(of: pattern, options: .regularExpression),
                         "禁用态用 CouliColor 令牌映射安卓 CheckboxGlyph 的禁用配色，不写死颜色 / 透明度：\(pattern)")
        }
    }
}

/// 组件源码定位（测试辅助）。
enum AgreementCheckComponentSource {
    static let designSystem = "Packages/DesignSystem/Sources"

    static func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw NSError(domain: "AgreementCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到仓库根"])
            }
            directory = parent
        }
        return directory
    }

    /// 去注释的源码（相对仓库根）。
    static func code(_ path: String) throws -> String {
        let file = try repositoryRoot().appendingPathComponent(path)
        return ShellSystemTabBarSourceTests.stripComments(try String(contentsOf: file, encoding: .utf8))
    }

    /// 目录下所有 .swift：相对路径 → 去注释源码。
    static func files(under directory: String) throws -> [(path: String, code: String)] {
        let root = try repositoryRoot()
        guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(directory),
                                                          includingPropertiesForKeys: nil) else {
            throw NSError(domain: "AgreementCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "读不到 \(directory)"])
        }
        var out: [(path: String, code: String)] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            let code = ShellSystemTabBarSourceTests.stripComments(try String(contentsOf: file, encoding: .utf8))
            out.append((file.path.replacingOccurrences(of: root.path + "/", with: ""), code))
        }
        return out
    }

    /// `struct <name>` 起到下一个顶格 `}` 的源码；找不到返回 nil。
    static func typeSource(_ name: String) throws -> String? {
        for file in try files(under: designSystem) {
            guard let start = file.code.range(of: #"\bstruct\s+"# + name + #"\b"#, options: .regularExpression) else {
                continue
            }
            let rest = file.code[start.lowerBound...]
            let end = rest.range(of: "\n}")?.upperBound ?? rest.endIndex
            return String(file.code[start.lowerBound..<end])
        }
        return nil
    }

    static func glyphSource() throws -> String {
        guard let body = try typeSource("CouliCheckGlyph") else {
            throw NSError(domain: "AgreementCheck", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "DesignSystem 里找不到 struct CouliCheckGlyph"])
        }
        return body
    }
}
