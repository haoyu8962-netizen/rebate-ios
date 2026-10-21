import Foundation
import ImageIO
import XCTest

/// V3：从运行时资源包读字节，不读工作树里的 PNG；manifest 不能给自己作证。
final class PlatformIconResourceTests: XCTestCase {
    func testManifestPinsTheReviewedSourceAndRequiredPlatforms() throws {
        let manifest = try PlatformIconTestFixtures.manifest()
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.sourceRepository, "couli")
        XCTAssertEqual(manifest.sourceCommit, PlatformIconTestFixtures.sourceCommit)
        let files = manifest.files.map(\.file)
        XCTAssertEqual(files.count, Set(files).count, "同一文件不能重复登记")
        let codes = Set(manifest.files.map(\.platformCode))
        XCTAssertTrue(Set(PlatformIconTestFixtures.requiredCodes).isSubset(of: codes))
        XCTAssertTrue(Set(PlatformIconTestFixtures.missingCodes).isDisjoint(with: codes))
    }

    func testEveryPackagedImageMatchesIndependentSourceSHA256AndDimensions() throws {
        let directory = try PlatformIconTestFixtures.directory()
        let manifest = try PlatformIconTestFixtures.manifest()
        XCTAssertFalse(manifest.files.isEmpty)
        for entry in manifest.files {
            let expected = try XCTUnwrap(PlatformIconTestFixtures.sources[entry.file],
                                         "未知素材 / 自有品牌 / 派生图不得悄悄混入：\(entry.file)")
            XCTAssertEqual(entry.platformCode, expected.code)
            XCTAssertEqual(entry.sourcePath, "design/icons/platform/" + entry.file)
            XCTAssertEqual(entry.sha256, expected.digest)
            XCTAssertEqual(entry.bytes, expected.bytes)
            XCTAssertEqual(entry.width, 224)
            XCTAssertEqual(entry.height, 224)
            let data = try Data(contentsOf: directory.appendingPathComponent(entry.file))
            XCTAssertEqual(PlatformIconTestFixtures.digest(data), expected.digest, entry.file)
            XCTAssertEqual(data.count, expected.bytes, entry.file)
            XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10], entry.file)
            let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetCount(image), 1)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 224)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 224)
        }
    }

    func testPlatformDirectoryContainsOnlyRegisteredOriginalsAndDocumentation() throws {
        let directory = try PlatformIconTestFixtures.directory()
        let manifest = try PlatformIconTestFixtures.manifest()
        let allowed = Set(manifest.files.map(\.file) + ["manifest.json", "README.md"])
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ))
        var found = Set<String>()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            XCTAssertEqual(values.isRegularFile, true, "不接受隐藏目录或资源目录混入")
            XCTAssertEqual(values.isSymbolicLink, false)
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            XCTAssertTrue(allowed.contains(relative), "平台目录混入未登记文件：\(relative)")
            found.insert(relative)
        }
        XCTAssertTrue(Set(manifest.files.map(\.file) + ["manifest.json"]).isSubset(of: found))
    }
}
