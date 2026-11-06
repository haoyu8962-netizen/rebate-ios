import Foundation
import XCTest

/// DS-02-iOS-1 源码守卫（计划验收 ①③、brief §3.3、计划 ③）：
/// - 手抄深色表、旧尺寸枚举、旧 TODO 在全仓文本里为 0（同 `git grep -nF`，注释也算）；
/// - 组件尺寸不再用 CouliSpacing 加乘拼；DesignSystem 源码（去注释）没有 6 / 8 位色值字面量与写死的遮罩；
/// - 卡内白底按钮不再局部强制外观；昵称输入中描边用 border.active。
/// 被禁的名字在本文件里拆开拼写，自己不命中验收 ① 的 grep。
final class DesignTokenSourceGuardTests: XCTestCase {
    private static let banned = ["Couli" + "DarkTokens", "Couli" + "GuideMetric", "TODO(" + "DS-02-iOS)"]
    private static let textExtensions: Set = ["swift", "py", "sh", "md", "yml", "yaml", "toml", "txt"]
    private static let skippedDirectories: Set = ["__Snapshots__", ".build", ".git", "DerivedData", "Couli.xcodeproj"]

    // 先去掉文件名，再从 DesignSystemTests 向上四级到仓库根。
    private var repoRoot: URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            directory.deleteLastPathComponent()
        }
        return directory
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 仓库里全部文本文件（相对路径），跳过快照图、构建目录与 contracts/ 上游快照。
    private func textFiles(under top: String) throws -> [String] {
        let base = repoRoot.appendingPathComponent(top)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey])
        else {
            return []
        }
        var result: [String] = []
        for case let url as URL in walker {
            if Self.skippedDirectories.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard Self.textExtensions.contains(url.pathExtension) else { continue }
            result.append(top + "/" + url.path.dropFirst(base.path.count + 1))
        }
        return result.sorted()
    }

    private func allTextFiles() throws -> [String] {
        var files = ["AGENTS.md", "CLAUDE.md", "README.md", "project.yml"]
        for top in ["App", "AppTests", "UITests", "Packages", "tools", "specs"] {
            files += try textFiles(under: top)
        }
        return files
    }

    // MARK: - 验收 ①

    /// 计划验收 ①：手抄深色表、旧尺寸枚举、旧 TODO 三个名字的 git grep 为 0（注释、测试、脚本一律算）。
    func testHandCopiedTablesAndOldNamesAreGone() throws {
        let files = try allTextFiles()
        // 扫描范围自检：App/Sources、Features、DesignSystem、AppTests 都在，不能漏扫（brief §3.11 变异「漏扫 App/Sources」）。
        for prefix in [
            "App/Sources/",
            "Packages/Features/Sources/",
            "Packages/DesignSystem/Sources/",
            "AppTests/",
            "tools/",
        ] {
            XCTAssertGreaterThan(files.filter { $0.hasPrefix(prefix) }.count, 3, "扫描范围缺 \(prefix)")
        }
        XCTAssertGreaterThan(files.count, 500)
        var hits: [String] = []
        for file in files {
            let text = try read(file)
            for name in Self.banned where text.contains(name) {
                hits.append("\(file)：\(name)")
            }
        }
        XCTAssertEqual(hits, [], "应为 0 处")
    }

    // MARK: - 验收 ③

    /// 计划验收 ③：组件尺寸（TokenComponents.swift 与待令牌枚举所在文件）不用 CouliSpacing 加乘拼。
    func testComponentMetricsAreNotSpacingArithmetic() throws {
        var files = ["Packages/DesignSystem/Sources/DesignSystem/TokenComponents.swift"]
        for file in try textFiles(under: "Packages/DesignSystem/Sources") where file.hasSuffix(".swift") {
            if try read(file).contains("enum CouliPendingTokenMetric") {
                files.append(file)
            }
        }
        XCTAssertGreaterThanOrEqual(files.count, 2, "应能找到 CouliPendingTokenMetric 的定义")
        let pattern = #"CouliSpacing\.s\d+\s*[-+*/]|[-+*/]\s*CouliSpacing\.s\d+"#
        for file in Set(files) {
            let code = Self.stripComments(try read(file))
            XCTAssertNil(code.range(of: pattern, options: .regularExpression), "\(file) 仍有 CouliSpacing 拼接")
        }
    }

    // MARK: - 深色值只来自生成物

    /// DesignSystem 源码（去注释与 SVG 资源）没有 #RRGGBB / #RRGGBBAA 字面量，也没有写死的遮罩不透明度或纯黑。
    func testDesignSystemSourcesHaveNoHandWrittenColors() throws {
        let sources = try textFiles(under: "Packages/DesignSystem/Sources").filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(sources.count, 10)
        let hex = ##""#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?""##
        for file in sources {
            let code = Self.stripComments(try read(file))
            XCTAssertNil(code.range(of: hex, options: .regularExpression), "\(file) 有手写色值")
            XCTAssertNil(code.range(of: #"UIColor\(named:|\bColor\("[^"]*"\)"#, options: .regularExpression),
                         "\(file) 换成了资源目录颜色（像素会漂，brief §5-3）")
        }
        let components = Self
            .stripComments(try read("Packages/DesignSystem/Sources/DesignSystem/TokenComponents.swift"))
        XCTAssertNil(components.range(of: #"0x[0-9A-Fa-f]{2}\s*/\s*255"#, options: .regularExpression), "遮罩不透明度应由令牌算出")
        XCTAssertFalse(components.contains("UIColor.black"), "深色遮罩应读 overlay.scrim，不写死黑")
    }

    // MARK: - 计划 ③（提交 D）

    /// 卡内白底按钮直接用 `.inverse` 的令牌取值，钱包 / 「我的」主卡不再局部强制浅色或改按钮种类。
    func testCardButtonsHaveNoLocalAppearanceOverride() throws {
        for file in [
            "Packages/Features/Sources/Wallet/WalletScreen+Hero.swift",
            "Packages/Features/Sources/Me/MeHeroCard.swift",
        ] {
            let code = Self.stripComments(try read(file))
            XCTAssertFalse(code.contains(#".environment(\.colorScheme"#), "\(file) 仍局部强制外观")
            XCTAssertTrue(code.contains("kind: .inverse"), "\(file) 的【提现】应仍是 .inverse")
        }
        let wallet = Self.stripComments(try read("Packages/Features/Sources/Wallet/WalletScreen+Hero.swift"))
        XCTAssertFalse(wallet.contains("darkDisabled"), "深色置灰不再改用 .primary")
    }

    /// 昵称输入中描边改用 border.active（语义名 CouliColor.borderActive），旧的「不在锁定令牌里」说明删除。
    func testNicknameFocusUsesBorderActive() throws {
        let raw = try read("Packages/Features/Sources/Me/SettingsSubPages.swift")
        XCTAssertTrue(Self.stripComments(raw).contains("CouliColor.borderActive"))
        XCTAssertFalse(raw.contains("border.active` 不在锁定令牌里"))
    }

    // MARK: - 去注释

    func testStripCommentsKeepsCodeAndStrings() {
        let source = "let a = \"// not comment\" // tail\n/* block\n x */let b = 1 /* c */ + 2\n"
            + "/// doc\nlet c = \"\"\"\n/* s */\n\"\"\"\n"
        let code = Self.stripComments(source)
        XCTAssertTrue(code.contains("\"// not comment\""))
        XCTAssertFalse(code.contains("tail"))
        XCTAssertFalse(code.contains("block"))
        XCTAssertTrue(code.contains("let b = 1"))
        XCTAssertTrue(code.contains("+ 2"))
        XCTAssertFalse(code.contains("doc"))
        XCTAssertTrue(code.contains("/* s */"), "多行字符串里的内容保留")
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// 去掉 // 与 /* */ 注释（支持嵌套块注释），保留字符串字面量（含 """ 多行与转义）。
    static func stripComments(_ source: String) -> String {
        let chars = Array(source)
        var out: [Character] = []
        var index = 0
        var depth = 0
        func at(_ offset: Int) -> Character? {
            index + offset < chars.count ? chars[index + offset] : nil
        }
        while index < chars.count {
            let char = chars[index]
            if depth > 0 {
                if char == "*", at(1) == "/" {
                    depth -= 1
                    index += 2
                } else if char == "/", at(1) == "*" {
                    depth += 1
                    index += 2
                } else {
                    if char == "\n" {
                        out.append(char)
                    }
                    index += 1
                }
            } else if char == "/", at(1) == "/" {
                while index < chars.count, chars[index] != "\n" {
                    index += 1
                }
            } else if char == "/", at(1) == "*" {
                depth = 1
                index += 2
            } else if char == "\"" {
                let multiline = at(1) == "\"" && at(2) == "\""
                let quote = multiline ? 3 : 1
                out.append(contentsOf: chars[index..<index + quote])
                index += quote
                while index < chars.count {
                    if chars[index] == "\\" {
                        out.append(contentsOf: chars[index..<min(index + 2, chars.count)])
                        index += 2
                        continue
                    }
                    if multiline ? (chars[index] == "\"" && at(1) == "\"" && at(2) == "\"") : chars[index] == "\"" {
                        out.append(contentsOf: chars[index..<index + quote])
                        index += quote
                        break
                    }
                    if !multiline, chars[index] == "\n" {
                        break
                    }
                    out.append(chars[index])
                    index += 1
                }
            } else {
                out.append(char)
                index += 1
            }
        }
        return String(out)
    }
    // swiftlint:enable cyclomatic_complexity function_body_length
}
