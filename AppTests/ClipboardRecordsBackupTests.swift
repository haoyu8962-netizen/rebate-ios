import ClientCore
import Clipboard
@testable import Couli
import Foundation
import XCTest

/// D10-1756：剪贴板记录文件不进备份；原子替换生成新文件后仍不备份；撤回同意的删除照常。
final class ClipboardRecordsBackupTests: XCTestCase {
    func testRecordsFileExcludedFromBackupAfterEveryWrite() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let file = ClientFile(name: ClipboardFileStore.fileName, baseDirectory: base)
        let store = ClipboardFileStore(file: file)

        try store.write("self_written", "h1")
        XCTAssertEqual(try excluded(file.url), true, "首次创建后不备份")

        try store.write("self_written", "h2")
        XCTAssertEqual(store.read("self_written"), "h2")
        XCTAssertEqual(try excluded(file.url), true, "原子替换后仍不备份")

        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path), "撤回同意的删除不受影响")
    }

    /// 开关文件 `clipboard-switch.json` 要随备份带走（关闭态本机保留，换机恢复后不能回到默认开）：写入后、原子替换后都不设不备份。
    @MainActor
    func testSwitchFileStaysInBackupAfterEveryWrite() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let url = ClientFile(name: ClipboardAutoSwitch.liveFileName, baseDirectory: base).url
        let autoSwitch = ClipboardAutoSwitch(store: ClipboardAutoSwitch.liveStore(baseDirectory: base))

        XCTAssertTrue(autoSwitch.set(false), "关闭开关落盘")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotEqual(try excluded(url), true, "首次创建后仍随备份（nil 视为 false）")
        XCTAssertFalse(ClipboardAutoSwitch(store: ClipboardAutoSwitch.liveStore(baseDirectory: base)).isOn)

        XCTAssertTrue(autoSwitch.set(true), "再写一次（原子替换）")
        XCTAssertNotEqual(try excluded(url), true, "原子替换后仍随备份（nil 视为 false）")
    }

    private func excluded(_ url: URL) throws -> Bool? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }
}
