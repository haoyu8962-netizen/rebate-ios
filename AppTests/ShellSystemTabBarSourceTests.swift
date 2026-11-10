import Foundation
import XCTest

/// FU-IOS-NATIVE-TABBAR 源码守卫（D10-824 / D10-826 / D10-831；方案 plan-ios.md §2.3 T1、T2）。去掉注释后匹配。
/// - 外壳用系统 TabView 标签栏：不隐藏系统标签栏、不画自绘 TabBar，选中绑定的 set 走 onSelect，iOS 26 下滚动收起；
/// - Liquid Glass 不被覆盖：不加 UIDesignRequiresCompatibility（任何配置）、不设标签栏背景、不用 UITabBarAppearance、不在底部垫色条；
/// - 读屏 / 大字 / 长按放大交给系统：设计系统里不再有自绘底栏与它的读屏逻辑，外壳不再自写读屏；
/// - 组件目录页 / 对照页不再用 TabBar 样例。
final class ShellSystemTabBarSourceTests: XCTestCase {
    private static let productRoots = [
        "App/Sources",
        "Packages/Core/Sources",
        "Packages/Features/Sources",
        "Packages/DesignSystem/Sources",
    ]

    // MARK: T1 结构

    func testShellUsesSystemTabBarDrivenBySelectionBinding() throws {
        let shell = try tabShellSource()
        XCTAssertNil(shell.firstMatch(#"toolbar(Visibility)?\(\s*\.hidden\s*,\s*for:\s*\.tabBar"#), "外壳不再隐藏系统标签栏")
        XCTAssertNil(shell.firstMatch(#"(?<![\w.])TabBar\("#), "外壳不再画设计系统的自绘 TabBar")
        XCTAssertNotNil(shell.firstMatch(#"\.tabItem\s*\{"#), "每个 Tab 页用系统 .tabItem")
        XCTAssertNil(shell.firstMatch(#"set:\s*\{\s*_\s+in\s*\}"#), "选中绑定的 set 不能是空操作")
        XCTAssertNotNil(shell.firstMatch(#"set:\s*\{[^}]*onSelect"#), "选中绑定的 set 调 onSelect（过守卫）")
        XCTAssertNil(shell.firstMatch(#"\.id\("#), "外壳不给 TabView / Tab 页加 .id（会重建首页、丢滚动位置）")
    }

    func testMinimizeOnScrollDownOnlyUnderIOS26Availability() throws {
        let code = try stripped("App/Sources/Shell/ShellViews.swift")
        let lines = code.components(separatedBy: "\n")
        let hits = lines.indices.filter { lines[$0].contains("tabBarMinimizeBehavior(.onScrollDown)") }
        XCTAssertFalse(hits.isEmpty, "iOS 26 下标签栏随滚动收起（D10-826 ②）")
        // v2（变异 m4 存活）：只查文件里有这句不够——目录页也用同一个修饰器，外壳不再调用也查不出来。收窄到外壳本体：
        // TabShellView 里要么直接写 tabBarMinimizeBehavior(.onScrollDown)，要么调用同文件里包着它的那个修饰器。
        let carriers = minimizeCarriers(in: code)
        let shell = try tabShellSource()
        let applied = shell.contains("tabBarMinimizeBehavior(.onScrollDown)")
            || carriers.contains { shell.firstMatch(#"(?<![\w.])"# + $0 + #"\(\s*\)"#) != nil }
        XCTAssertTrue(applied, "外壳本体（TabShellView）必须挂上标签栏滚动收起；包着它的修饰器：\(carriers)")
        for index in hits {
            let window = lines[max(0, index - 4)...index].joined(separator: "\n")
            XCTAssertNotNil(window.firstMatch(#"#available\(iOS\s+26"#),
                            "tabBarMinimizeBehavior 必须包在 if #available(iOS 26, *) 里（部署目标 16.0）：第 \(index + 1) 行")
        }
    }

    /// 同文件里 body 含 tabBarMinimizeBehavior(.onScrollDown) 的顶层 struct 名（外壳通过 .modifier(名()) 调用）。
    private func minimizeCarriers(in code: String) -> [String] {
        let pattern = #"\nstruct\s+(\w+)\s*:\s*ViewModifier[\s\S]*?"#
            + #"(?=\n(struct|enum|final class|class|extension)\s|\z)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..., in: code)
        return regex.matches(in: code, range: range).compactMap { match in
            guard let whole = Range(match.range, in: code), let name = Range(match.range(at: 1), in: code),
                  code[whole].contains("tabBarMinimizeBehavior(.onScrollDown)") else { return nil }
            return String(code[name])
        }
    }

    func testBrandTintIsAppliedOnShell() throws {
        let shell = try tabShellSource()
        XCTAssertNotNil(
            shell.firstMatch(#"\.tint\(\s*CouliColor\.brandPrimary\s*\)"#),
            "选中色经 .tint(CouliColor.brandPrimary)"
        )
        XCTAssertNil(shell.firstMatch(#"\.accentColor\("#), "不用已弃用的 accentColor")
    }

    func testDesignSystemNoLongerHasSelfDrawnTabBar() throws {
        let found = try hits(in: ["Packages/DesignSystem/Sources"], patterns: [
            #"struct\s+TabBar\b"#, #"struct\s+TabBarItem\b"#, #"TabBarAccessibilityTrait"#, #"\.isTabBar\b"#,
        ])
        XCTAssertEqual(found, [], "设计系统里的自绘底栏与它的读屏逻辑应删除（D10-826 ④）")
    }

    // MARK: T2 不覆盖系统材质

    func testNoMaterialOverrideOrCompatibilityFlagAnywhere() throws {
        let found = try hits(in: Self.productRoots, patterns: [
            #"UIDesignRequiresCompatibility"#,
            #"toolbarBackground(Visibility)?\([^\n]*\.tabBar"#,
            #"toolbarColorScheme\([^\n]*\.tabBar"#,
            #"UITabBarAppearance"#,
            #"UITabBar\.appearance"#,
            #"UITabBarItem\.appearance"#,
        ])
        XCTAssertEqual(found, [], "不加兼容开关、不覆盖标签栏材质（D10-826 ②）")
    }

    func testEveryConfigurationInfoPlistSourceLacksCompatibilityFlag() throws {
        let root = try repositoryRoot()
        var files = ["project.yml", "App/Info.plist"]
        let config = root.appendingPathComponent("App/Config")
        files += try FileManager.default.contentsOfDirectory(atPath: config.path)
            .filter { $0.hasSuffix(".xcconfig") }.map { "App/Config/" + $0 }
        XCTAssertTrue(files.contains("App/Config/Release.xcconfig"), "应扫到 Release 配置")
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("UIDesignRequiresCompatibility"), "\(file) 不得含 UIDesignRequiresCompatibility")
        }
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "UIDesignRequiresCompatibility"),
                     "本次构建的 Info.plist 不得含 UIDesignRequiresCompatibility")
    }

    func testShellDoesNotPadBottomWithSolidStrip() throws {
        let shell = try tabShellSource()
        XCTAssertNil(shell.firstMatch(#"safeAreaInset\(\s*edge:\s*\.bottom"#), "外壳不在底部另垫一条")
        XCTAssertNil(shell.firstMatch(#"ignoresSafeArea\(\s*edges:\s*\.bottom"#), "外壳不再画只铺底边的背景条")
        XCTAssertNil(shell.firstMatch(#"VStack\(spacing:\s*0\)\s*\{\s*content"#), "不再是 VStack { 内容; 底栏 }")
    }

    // MARK: 读屏交给系统

    func testShellWritesNoOwnTabBarAccessibility() throws {
        let shell = try tabShellSource()
        for needle in [
            "accessibilityRepresentation", "accessibilityShowsLargeContentViewer", "accessibilityAddTraits",
            "accessibilityElement(", "dynamicTypeSize(", "\"shell.tabBar\"",
        ] {
            XCTAssertFalse(shell.contains(needle), "外壳不再自写标签栏的读屏 / 字号逻辑：\(needle)")
        }
        let found = try hits(in: Self.productRoots, patterns: [#""shell\.tabBar""#])
        XCTAssertEqual(found, [], "不保留 shell.tabBar 标识（D10-831 ②）")
    }

    // MARK: 目录页

    func testCatalogAndComparePagesDropSelfDrawnTabBarSamples() throws {
        let found = try hits(in: ["App/Sources/Debug"], patterns: [
            #"(?<![\w.])TabBar\("#, #"\bTabBarItem\b"#, #"\bTabBarMock\b"#,
        ])
        XCTAssertEqual(found, [], "组件目录页 / 对照页去掉自绘 TabBar 样例（或改系统样例，D10-826 ④）")
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

    private func stripped(_ relative: String) throws -> String {
        let text = try String(contentsOf: repositoryRoot().appendingPathComponent(relative), encoding: .utf8)
        return Self.stripComments(text)
    }

    /// ShellViews.swift 里 `struct TabShellView` 到下一个顶层声明之间的源码（外壳本体；不含基本模式页等其他视图）。
    private func tabShellSource() throws -> String {
        let code = try stripped("App/Sources/Shell/ShellViews.swift")
        guard let start = code.range(of: "struct TabShellView") else {
            XCTFail("找不到 TabShellView")
            return ""
        }
        let rest = code[start.upperBound...]
        let end = rest.range(of: #"\n(struct|enum|final class|class|extension|private struct)\s"#,
                             options: .regularExpression)?.lowerBound ?? rest.endIndex
        return String(code[start.lowerBound..<end])
    }

    /// 去掉 /* */ 与 // 注释（字符串里的 "//" 会截断该行余下部分，对本守卫只会更宽松）。
    static func stripComments(_ text: String) -> String {
        let noBlock = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        return noBlock.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let range = line.range(of: "//") else { return line }
            return line[..<range.lowerBound]
        }.joined(separator: "\n")
    }

    /// 命中的「相对路径: 模式」清单（.swift，去注释后按正则匹配）。
    private func hits(in roots: [String], patterns: [String]) throws -> [String] {
        let root = try repositoryRoot()
        var found: [String] = []
        for sub in roots {
            guard let walker = FileManager.default.enumerator(
                at: root.appendingPathComponent(sub), includingPropertiesForKeys: nil
            ) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                let code = Self.stripComments(try String(contentsOf: file, encoding: .utf8))
                for pattern in patterns where code.firstMatch(pattern) != nil {
                    found.append(file.path.replacingOccurrences(of: root.path + "/", with: "") + ": " + pattern)
                }
            }
        }
        return found
    }
}

private extension String {
    func firstMatch(_ pattern: String) -> Range<String.Index>? {
        range(of: pattern, options: .regularExpression)
    }
}
