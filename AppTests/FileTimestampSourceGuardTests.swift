import Foundation
import XCTest

/// FU-IOS-PRIVACY-MANIFEST-FILETIMESTAMP（D10-1756 ①）源码守卫：隐私清单按 C617.1 登记 FileTimestamp——只访问本 App 容器内
/// 文件的时间戳、大小或其他元数据。去掉注释后按整词匹配，只扫产品源码（含 Debug 代码与契约生成物）。
/// - 全部产品源码：文件时间戳类 API 只许出现在白名单文件里，且每个文件只许命中登记过的那几个符号（同一文件新加时间戳字段也要报）；
///   白名单里的文件不再命中、或登记的符号不再出现，也要报，免得名单过期。
/// - SessionRevocation：fstat 的结果只取 st_mode（判断是否普通文件）。
/// - MeSystem：attributesOfItem 只取 `.size`（设置页显示的缓存大小）。
/// - 隐私清单里登记了 FileTimestamp + C617.1。
final class FileTimestampSourceGuardTests: XCTestCase {
    /// Apple「NSPrivacyAccessedAPIType」列出的 FileTimestamp API，加上同一数据的其他取法（URL 资源键、FileAttributeKey、
    /// stat 结构的时间字段、64 位变体、FileManager.attributesOfItem 返回的属性字典）。
    private static let needles = [
        "creationDate", "modificationDate", "fileModificationDate", "fileCreationDate",
        "contentModificationDate", "contentModificationDateKey", "creationDateKey",
        "contentAccessDate", "contentAccessDateKey", "attributeModificationDate", "attributeModificationDateKey",
        "addedToDirectoryDate", "addedToDirectoryDateKey",
        "NSFileModificationDate", "NSFileCreationDate", "NSURLContentModificationDateKey", "NSURLCreationDateKey",
        "attributesOfItem",
        "getattrlist", "getattrlistbulk", "fgetattrlist", "getattrlistat",
        "stat", "fstat", "fstatat", "lstat", "stat64", "fstat64", "lstat64",
        "st_mtime", "st_mtimespec", "st_ctime", "st_ctimespec", "st_atime", "st_atimespec",
        "st_birthtime", "st_birthtimespec",
    ]

    /// 产品源码（含契约生成物）。
    private static let productRoots = [
        "App/Sources",
        "Packages/Core/Sources",
        "Packages/Features/Sources",
        "Packages/DesignSystem/Sources",
        "Packages/Generated/Sources",
    ]

    private struct Allowed {
        let symbols: Set<String>
        let reason: String
    }

    /// 允许出现相关符号的文件、只许命中的符号与理由。
    private static let allowlist: [String: Allowed] = [
        "Packages/Core/Sources/Session/SessionRevocation.swift": Allowed(
            symbols: ["stat", "fstat"],
            reason: "读撤销标记文件（Application Support/com.couli.app/session.revoked 与 .tmp）时 fstat 只取 st_mode 判断普通文件"
        ),
        "App/Sources/Me/MeSystem.swift": Allowed(
            symbols: ["attributesOfItem"],
            reason: "设置页「清除缓存」显示 Caches 下 WebKit 目录大小：attributesOfItem 只取 .size，只在本机显示"
        ),
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

    /// 相对路径下的全部 .swift（目录递归，文件直接取）；路径不存在则失败，免得改名后守卫悄悄落空。
    private func swiftFiles(_ relative: String, root: URL) throws -> [URL] {
        let url = root.appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            XCTFail("扫描路径不存在：\(relative)")
            return []
        }
        guard isDirectory.boolValue else { return [url] }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func relativePath(_ file: URL, root: URL) -> String {
        file.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    /// 整词命中（`stat` 不命中 `status` / `state`，`modificationDate` 不命中 `contentModificationDate`）。
    private func matchedNeedles(in code: String) -> Set<String> {
        Set(Self.needles.filter { needle in
            code.range(of: "\\b\(needle)\\b", options: .regularExpression) != nil
        })
    }

    /// 文件相对路径 → 命中的符号。
    private func hits() throws -> [String: Set<String>] {
        let root = try repositoryRoot()
        var found: [String: Set<String>] = [:]
        for path in Self.productRoots {
            for file in try swiftFiles(path, root: root) {
                let matched = matchedNeedles(in: stripComments(try String(contentsOf: file, encoding: .utf8)))
                if !matched.isEmpty {
                    found[relativePath(file, root: root)] = matched
                }
            }
        }
        return found
    }

    private func code(_ relative: String) throws -> String {
        let root = try repositoryRoot()
        let url = root.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("文件不存在：\(relative)")
            return ""
        }
        return stripComments(try String(contentsOf: url, encoding: .utf8))
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testFileTimestampSymbolsOnlyInAllowlistedFiles() throws {
        let found = try hits()
        let unexpected = found.keys.filter { Self.allowlist[$0] == nil }.sorted()
        XCTAssertEqual(unexpected.map { "\($0): \(found[$0]?.sorted() ?? [])" }, [],
                       "新的文件时间戳 / 元数据读取：核对是否只访问本 App 容器内的文件（C617.1），确认后加白名单并同步隐私清单注释")
        let stale = Self.allowlist.keys.filter { found[$0] == nil }.sorted()
        XCTAssertEqual(stale, [], "白名单里的文件已不再命中，删掉对应条目")
    }

    func testAllowlistedFilesHitOnlyRegisteredSymbols() throws {
        let found = try hits()
        for (path, allowed) in Self.allowlist.sorted(by: { $0.key < $1.key }) {
            let matched = found[path] ?? []
            XCTAssertEqual(matched.subtracting(allowed.symbols).sorted(), [],
                           "\(path) 新命中了未登记的文件时间戳符号（登记理由：\(allowed.reason)）")
            XCTAssertEqual(allowed.symbols.subtracting(matched).sorted(), [],
                           "\(path) 已不再用登记的符号，收窄白名单")
        }
    }

    func testSessionRevocationReadsOnlyFileType() throws {
        let text = try code("Packages/Core/Sources/Session/SessionRevocation.swift")
        XCTAssertEqual(occurrences(of: "fstat(", in: text), 1, "只在读撤销标记时 fstat 一次")
        XCTAssertEqual(occurrences(of: "info.", in: text), 1, "fstat 的结果只取一个字段")
        XCTAssertTrue(text.contains("(info.st_mode & S_IFMT) == S_IFREG"), "fstat 只用来判断是否普通文件")
        XCTAssertTrue(text.contains(".applicationSupportDirectory, in: .userDomainMask"), "撤销标记文件在本 App 容器内")
    }

    func testMeSystemReadsOnlyFileSize() throws {
        let text = try code("App/Sources/Me/MeSystem.swift")
        let calls = occurrences(of: "attributesOfItem(", in: text)
        XCTAssertEqual(calls, 1, "attributesOfItem 只用于目录大小")
        XCTAssertEqual(occurrences(of: "attributesOfItem(atPath: url.path)[.size]", in: text), calls,
                       "attributesOfItem 只取 .size，不取时间戳")
        XCTAssertTrue(text.contains(".cachesDirectory, in: .userDomainMask"), "统计的是本 App 容器 Caches 下的目录")
    }

    func testPrivacyManifestDeclaresFileTimestamp() throws {
        let root = try repositoryRoot()
        let url = root.appendingPathComponent("App/Resources/PrivacyInfo.xcprivacy")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("隐私清单不存在：App/Resources/PrivacyInfo.xcprivacy")
            return
        }
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        )
        let types = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let entry = types.first {
            $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryFileTimestamp"
        }
        XCTAssertEqual(entry?["NSPrivacyAccessedAPITypeReasons"] as? [String], ["C617.1"],
                       "FileTimestamp 按 C617.1 登记（访问本 App 容器内文件的元数据）")
    }
}
