import Foundation
import XCTest

/// FU-X-CLIP-DEFAULT-ON-ios 源码守卫（brief §1 C2、C3、C4；变更记录 §2 第 1、2、4、5 行）。只扫产品源码（App/Sources、
/// Packages/{Core,Features,DesignSystem}/Sources；Generated 是契约生成物，枚举 clipboard_auto_import 按契约保留），去掉注释后匹配。
/// - C2：首次用途说明弹层整套移除（`ClipboardConsentSheet.swift`、`ClipboardConsentNotice`、`clipboardConsentSheet`、`consentNotice`），
///   `clipboard.consent.*` 文案键不再被任何界面引用（字符串字面量 `"clipboard.consent.`）。规划侧的键与设计稿保留，不在本仓库。
/// - C3：客户端不为剪贴板写 consent：不出现 `clipboardAutoImport` / `clipboard_auto_import`（iOS 本来就没写，回归守卫）。
/// - C4：不以 `config.clipboard.consent_version` 作门槛：不出现 `consent_version`（iOS 本来就没用，回归守卫）。
final class ClipDefaultOnSourceGuardTests: XCTestCase {
    private static let roots = [
        "App/Sources",
        "Packages/Core/Sources",
        "Packages/Features/Sources",
        "Packages/DesignSystem/Sources",
    ]

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { throw XCTSkip("找不到仓库根（contract.lock）") }
            directory = parent
        }
        return directory
    }

    /// 去掉 /* */ 与 // 注释（字符串里的 "//" 会截断该行余下部分，对本守卫的匹配只会更宽松）。
    private func stripComments(_ text: String) -> String {
        let noBlock = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        return noBlock.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let range = line.range(of: "//") else { return line }
            return line[..<range.lowerBound]
        }.joined(separator: "\n")
    }

    /// 命中的「相对路径: 词」清单。
    private func hits(_ needles: [String]) throws -> [String] {
        let root = try repositoryRoot()
        var found: [String] = []
        for sub in Self.roots {
            let base = root.appendingPathComponent(sub)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                let code = stripComments(try String(contentsOf: file, encoding: .utf8))
                for needle in needles where code.contains(needle) {
                    found.append(file.path.replacingOccurrences(of: root.path + "/", with: "") + ": " + needle)
                }
            }
        }
        return found
    }

    func testConsentSheetRemovedAndConsentTextKeysUnreferencedC2() throws {
        let root = try repositoryRoot()
        XCTAssertFalse(
            FileManager.default
                .fileExists(atPath: root.appendingPathComponent("App/Sources/Clipboard/ClipboardConsentSheet.swift")
                    .path),
            "ClipboardConsentSheet.swift 应删除"
        )
        let found = try hits([
            "ClipboardConsentNotice", "clipboardConsentSheet", "ClipboardConsentSheet", "consentNotice",
            "\"clipboard.consent.",
        ])
        XCTAssertEqual(found, [], "用途说明弹层与 clipboard.consent.* 仍被产品代码引用")
    }

    func testNoClipboardAutoImportConsentWriteC3() throws {
        XCTAssertEqual(try hits(["clipboardAutoImport", "clipboard_auto_import"]), [], "客户端不再为剪贴板调 POST /v1/consents")
    }

    func testConsentVersionIsNotAGateC4() throws {
        XCTAssertEqual(try hits(["consent_version"]), [], "config.clipboard.consent_version 不参与判定")
    }
}
