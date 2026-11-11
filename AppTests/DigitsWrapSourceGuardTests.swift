@testable import Couli
import Foundation
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-NUM-WRAP 源码守卫（D10-1230「不缩字硬塞」）与 QA-11 截图命名核对（编排追加项）。
@MainActor
final class DigitsWrapSourceGuardTests: XCTestCase {
    /// 缩字手段只允许留在现有三处**非数字**装饰文字（品牌方块字、订单图「商品图」占位、首页无图格的首字）；
    /// 数字串（订单号、金额、手机号 / 脱敏账号、流水号）一律不得用 minimumScaleFactor / adjustsFontSizeToFitWidth /
    /// allowsTightening 硬塞。新增任何一处都红（要用就在本表登记并说明不是数字串）。
    func testNoShrinkToFitOutsideKnownDecorativeText() throws {
        let allowed: [String: Int] = [
            "Packages/Features/Sources/Login/LoginPieces.swift": 1,
            "Packages/Features/Sources/Orders/OrderComponents.swift": 1,
            "Packages/Features/Sources/Home/HomeSectionView.swift": 1,
        ]
        let root = try repositoryRoot()
        var hits: [String: Int] = [:]
        for sub in [
            "App/Sources",
            "Packages/Core/Sources",
            "Packages/Features/Sources",
            "Packages/DesignSystem/Sources",
        ] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(sub),
                                                              includingPropertiesForKeys: nil) else {
                XCTFail("读不到 \(sub)")
                continue
            }
            for case let file as URL in walker where file.pathExtension == "swift" {
                let code = ShellSystemTabBarSourceTests.stripComments(try String(contentsOf: file, encoding: .utf8))
                let count = ["minimumScaleFactor", "adjustsFontSizeToFitWidth", "allowsTightening"]
                    .map { code.components(separatedBy: $0).count - 1 }.reduce(0, +)
                if count > 0 {
                    hits[file.path.replacingOccurrences(of: root.path + "/", with: ""), default: 0] += count
                }
            }
        }
        for (path, count) in hits.sorted(by: { $0.key < $1.key }) {
            XCTAssertLessThanOrEqual(count, allowed[path] ?? 0, "\(path) 用了 \(count) 处缩字（数字串不准缩字硬塞）")
        }
    }

    /// 编排追加（QA-11 证据问题 #7）：审查报告说 UITests `matrix-overlays.Main-font200-*` 用的 `accessibilityExtraLarge` 约 112%、名不副实。
    /// 核对结论：`accessibilityExtraLarge` 是**辅助字号第 3 档 AX3**（约 235%，不是非辅助档 `extraLarge` 约 112%）；
    /// 调试场景 `DebugHomeVisual.categorySuffix` 把它映射成 `UICTContentSizeCategoryAccessibilityXL`，与 AppTests 里全部 font200 截图用的
    /// `DynamicTypeSize.accessibility3`、二次验证半屏的 `ax3` 同一档——名字是对的，不改名、不改档。
    /// 这里把「font200 = AX3」钉住：home-visual-cases.json 里名字带 font200 的每一条都必须是 AX3，带 font200 却用别的档（含真 112% 的
    /// extraLarge）一律红。
    func testFont200HomeCasesAreReallyAccessibility3() throws {
        let raw = UIContentSizeCategory(rawValue: "UICTContentSizeCategoryAccessibilityXL")
        XCTAssertEqual(raw, .accessibilityExtraLarge, "调试场景的映射名就是系统 AX3 档")
        XCTAssertEqual(
            DynamicTypeSize(raw),
            .accessibility3,
            "accessibilityExtraLarge = DynamicTypeSize.accessibility3"
        )
        let data = try Data(contentsOf: repositoryRoot().appendingPathComponent("specs/home-visual-cases.json"))
        let json = try JSONSerialization.jsonObject(with: data)
        var cases: [[String: Any]] = []
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                if object["name"] is String, object["category"] is String {
                    cases.append(object)
                }
                object.values.forEach(walk)
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(json)
        let font200 = cases.filter { ($0["name"] as? String)?.contains("font200") == true }
        XCTAssertGreaterThanOrEqual(font200.count, 3, "前提：Main-font200-w320-light / w390-light / w390-dark 都在")
        for item in font200 {
            XCTAssertEqual(item["category"] as? String, "accessibilityExtraLarge",
                           "\(item["name"] ?? "")：名字写 font200，档位必须是 AX3（accessibilityExtraLarge）")
        }
    }

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw NSError(domain: "DigitsWrap", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到仓库根"])
            }
            directory = parent
        }
        return directory
    }
}
