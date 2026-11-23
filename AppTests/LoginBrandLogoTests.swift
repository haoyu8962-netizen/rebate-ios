import Foundation
import XCTest

/// FU-IOS-LOGIN-LOGO（D10-2730，D10-2762 改口径）源码守卫：登录页手机号步用组件库应用图标式 Logo
/// `CouliLogo(.appIcon)`（56×56，Login-v2 手机号页首屏），不再在 Features 里自画「狸橙圆角方块 + 品牌字」，
/// 登录页也不再用透明底 `.mark` / 横向 `.horizontal`。去掉注释后匹配（工具同 ShellSystemTabBarSourceTests.stripComments）。
/// 资源本身（浅 / 深取图、底色）见 LoginBrandLogoAssetTests。
///
/// 不做托管断言的原因：旧 BrandMark 本身 `.accessibilityHidden(true)`，读屏树里本来就没有「凑狸」元素，新旧都绿、钉不住；
/// SwiftUI 的 `Image(_:bundle:)` 渲染后 UIKit 层级里没有图片资源名可查，只能靠像素取样，且要先定位 Logo 区域，太脆。
final class LoginBrandLogoTests: XCTestCase {
    private static let loginDirectory = "Packages/Features/Sources/Login"

    /// Features 源码里不得再有自定义品牌方块视图（`struct BrandMark` 之类），也不得用 `LoginKeys.brand` 文案画 Logo。
    func testFeaturesHaveNoHandDrawnBrandMark() throws {
        let root = try repositoryRoot()
        let patterns = [
            #"\bstruct\s+BrandMark\b"#,
            #"(?<![\w.])BrandMark\("#,
            #"\bLoginKeys\.brand\b"#,
        ]
        var found: [String] = []
        let directory = root.appendingPathComponent("Packages/Features/Sources")
        let walker = try XCTUnwrap(
            FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil),
            "读不到 Packages/Features/Sources"
        )
        for case let file as URL in walker where file.pathExtension == "swift" {
            let code = ShellSystemTabBarSourceTests.stripComments(try String(contentsOf: file, encoding: .utf8))
            for pattern in patterns where code.range(of: pattern, options: .regularExpression) != nil {
                found.append(file.path.replacingOccurrences(of: root.path + "/", with: "") + ": " + pattern)
            }
        }
        XCTAssertEqual(found, [], "登录页品牌标识改用组件库 CouliLogo，不自画方块写字（D10-2730）")
    }

    /// LoginView.swift 的手机号步（`var phoneStep`）必须用应用图标式 `CouliLogo(.appIcon)`，并按 Login-v2 稿 56×56 摆放（D10-2762）。
    func testPhoneStepUsesAppIconLogo() throws {
        let step = try phoneStepSource()
        XCTAssertFalse(step.isEmpty, "前提：LoginView.swift 里找得到 var phoneStep")
        XCTAssertNotNil(step.range(of: #"(?<![\w.])CouliLogo\(\s*\.appIcon\s*\)"#, options: .regularExpression),
                        "手机号步要用组件库应用图标式 CouliLogo(.appIcon)（D10-2762）")
        XCTAssertNotNil(
            step.range(of: #"(?<![\w.])CouliLogo\(\s*\.appIcon\s*\)\s*\.frame\(\s*width:\s*56\s*,\s*height:\s*56\s*\)"#,
                       options: .regularExpression),
            "手机号步的 Logo 按 Login-v2 稿 56×56 固定尺寸（D10-2762，旧 72×72 作废）"
        )
        XCTAssertNil(step.range(of: #"\.frame\(\s*width:\s*72\s*,\s*height:\s*72\s*\)"#, options: .regularExpression),
                     "手机号步不再保留旧 72×72 Logo 框")
    }

    /// 登录页（Packages/Features/Sources/Login 下全部源码）不得再用透明底主图形 `.mark`（含默认版式 `CouliLogo()`、
    /// 只给读屏文本的 `CouliLogo(accessibilityText:)`）或横向组合 `.horizontal`；「关于」等其他页的 `.mark` 不在此列。
    func testLoginPagesDoNotUseMarkOrHorizontalLogo() throws {
        let root = try repositoryRoot()
        let patterns = [
            #"(?<![\w.])CouliLogo\(\s*\.mark\b"#,
            #"(?<![\w.])CouliLogo\(\s*\.horizontal\b"#,
            #"(?<![\w.])CouliLogo\(\s*\)"#,
            #"(?<![\w.])CouliLogo\(\s*accessibilityText:"#,
            #"CouliLogoVariant\.(mark|horizontal)\b"#,
        ]
        var found: [String] = []
        let directory = root.appendingPathComponent(Self.loginDirectory)
        let walker = try XCTUnwrap(
            FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil),
            "读不到 \(Self.loginDirectory)"
        )
        for case let file as URL in walker where file.pathExtension == "swift" {
            let code = ShellSystemTabBarSourceTests.stripComments(try String(contentsOf: file, encoding: .utf8))
            for pattern in patterns where code.range(of: pattern, options: .regularExpression) != nil {
                found.append(file.path.replacingOccurrences(of: root.path + "/", with: "") + ": " + pattern)
            }
        }
        XCTAssertEqual(found, [], "登录页 Logo 统一用应用图标式 .appIcon，不用 .mark / .horizontal（D10-2762）")
    }

    // MARK: 工具

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { throw XCTSkip("找不到仓库根（contract.lock）") }
            directory = parent
        }
        return directory
    }

    /// LoginView.swift（去注释）里 `var phoneStep` 到下一个同级成员（4 格缩进的 var / func / @ViewBuilder）之间的源码。
    private func phoneStepSource() throws -> String {
        let file = try repositoryRoot().appendingPathComponent(Self.loginDirectory + "/LoginView.swift")
        let code = ShellSystemTabBarSourceTests.stripComments(try String(contentsOf: file, encoding: .utf8))
        guard let start = code.range(of: "var phoneStep") else { return "" }
        let rest = code[start.upperBound...]
        let end = rest.range(of: #"\n    (var|func|@ViewBuilder|private|static|public)\s"#,
                             options: .regularExpression)?.lowerBound ?? rest.endIndex
        return String(code[start.lowerBound..<end])
    }
}
