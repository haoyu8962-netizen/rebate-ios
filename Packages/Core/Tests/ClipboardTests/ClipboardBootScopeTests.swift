@testable import Clipboard
import Foundation
import XCTest

/// FU-IOS-CLIP-COLDSTART-MISSED（D10-1753 ①⑤）：剪贴板变化计数（自写计数 self_written_change、ios_change_seen）连同开机标识存。
/// 包内只测记录层：换开机标识、旧格式（无 `_boot` 键）整条作废；同一次开机内只认最近一次自写计数；取不到开机标识只放内存、
/// 盘上不出现值与 `_boot` 键；值写成功而标识写失败按作废；clear 删掉 `_boot` 键。App 接线见 AppTests/ClipboardBootScope*Tests。
final class ClipboardBootScopeTests: XCTestCase {
    private let seenKey = "ios_change_seen"
    private let changeKey = ClipboardWriteLedger.changeKey
    private let suffix = ClipboardBootScopedRecord.bootSuffix

    // MARK: - ① 换开机标识整条作废

    func testRecordFromAnotherBootReadsAsNoRecord() {
        let store = MemoryClipboardHashStore()
        let first = ClipboardBootScopedRecord(key: seenKey, store: store, boot: { "boot-A" })
        XCTAssertTrue(first.write("5"))
        XCTAssertEqual(first.read(), "5")
        XCTAssertEqual(store.read(seenKey), "5", "值的格式与旧版相同")
        XCTAssertEqual(store.read(seenKey + suffix), "boot-A", "开机标识另存 key_boot")
        XCTAssertEqual(first.bootKey, seenKey + suffix)
        let relaunched = ClipboardBootScopedRecord(key: seenKey, store: store, boot: { "boot-A" })
        XCTAssertEqual(relaunched.read(), "5", "同一次开机的新实例照常读到")
        let rebooted = ClipboardBootScopedRecord(key: seenKey, store: store, boot: { "boot-B" })
        XCTAssertNil(rebooted.read(), "换了开机：同一计数也按没有记录")
    }

    func testSelfWrittenChangeCountVoidAfterBootChangesInSameInstance() {
        let store = MemoryClipboardHashStore()
        let boot = TestBoot("boot-A")
        let ledger = ClipboardWriteLedger(store: store, boot: { boot.value })
        XCTAssertTrue(ledger.recordChangeCount(7))
        XCTAssertTrue(ledger.containsChangeCount(7), "同一次开机内命中")
        boot.value = "boot-B"
        XCTAssertFalse(ledger.containsChangeCount(7), "注入的开机标识先 A 后 B：旧自写计数不再判自写")
        XCTAssertTrue(ledger.recordChangeCount(7))
        XCTAssertTrue(ledger.containsChangeCount(7), "新开机内重新自写后再命中")
        XCTAssertEqual(store.read(changeKey + suffix), "boot-B")
    }

    func testSelfWrittenChangeCountAcrossInstances() {
        let store = MemoryClipboardHashStore()
        XCTAssertTrue(ClipboardWriteLedger(store: store, boot: { "boot-A" }).recordChangeCount(3))
        XCTAssertTrue(ClipboardWriteLedger(store: store, boot: { "boot-A" }).containsChangeCount(3), "同一次开机跨实例仍跳过")
        XCTAssertFalse(ClipboardWriteLedger(store: store, boot: { "boot-B" }).containsChangeCount(3), "换开机不判自写")
    }

    // MARK: - ② 只认最近一次自写计数

    func testOnlyLatestSelfWriteCountMatches() {
        let store = MemoryClipboardHashStore()
        let ledger = ClipboardWriteLedger(store: store, boot: { "boot-A" })
        XCTAssertTrue(ledger.recordChangeCount(3))
        XCTAssertTrue(ledger.recordChangeCount(4))
        XCTAssertTrue(ledger.containsChangeCount(4))
        XCTAssertFalse(ledger.containsChangeCount(3), "更早一次（非最近一次）的自写计数：照常探测")
        XCTAssertFalse(ledger.containsChangeCount(5))
        XCTAssertEqual(store.read(changeKey), "4", "只留最近一次写入的那个计数")
    }

    // MARK: - 旧格式（无 _boot 键）

    func testLegacyRecordsWithoutBootKeyReadAsNoRecord() {
        let store = MemoryClipboardHashStore()
        XCTAssertNoThrow(try store.write(changeKey, "4,5"))
        XCTAssertNoThrow(try store.write(seenKey, "5"))
        let ledger = ClipboardWriteLedger(store: store, boot: { "boot-A" })
        XCTAssertFalse(ledger.containsChangeCount(5), "旧版只有 self_written_change：按没有自写计数")
        XCTAssertFalse(ledger.containsChangeCount(4))
        let seen = ClipboardBootScopedRecord(key: seenKey, store: store, boot: { "boot-A" })
        XCTAssertNil(seen.read(), "旧版只有 ios_change_seen：按没有判定过")
        XCTAssertTrue(seen.write("5"))
        XCTAssertEqual(seen.read(), "5", "按新格式重写后生效")
    }

    // MARK: - 取不到开机标识

    func testNoBootIdentityKeepsCountsInMemoryOnly() {
        let store = MemoryClipboardHashStore()
        let ledger = ClipboardWriteLedger(store: store, boot: { nil })
        XCTAssertTrue(ledger.record("自写口令"))
        XCTAssertTrue(ledger.recordChangeCount(9), "记在内存也算记下")
        XCTAssertTrue(ledger.containsChangeCount(9), "同一实例内自写后仍跳过")
        let seen = ClipboardBootScopedRecord(key: seenKey, store: store, boot: { nil })
        XCTAssertTrue(seen.write("9"))
        XCTAssertEqual(seen.read(), "9")
        for key in [changeKey, changeKey + suffix, seenKey, seenKey + suffix] {
            XCTAssertNil(store.read(key), "取不到开机标识：盘上不出现 \(key)")
        }
        XCTAssertTrue(ledger.contains("自写口令"), "hash 照常落盘（最终判据）")
        XCTAssertFalse(ClipboardWriteLedger(store: store, boot: { nil }).containsChangeCount(9), "新实例同一存储看不到")
        XCTAssertNil(ClipboardBootScopedRecord(key: seenKey, store: store, boot: { nil }).read())
    }

    func testNoBootIdentityIgnoresRecordsOnDisk() {
        let store = MemoryClipboardHashStore()
        XCTAssertTrue(ClipboardWriteLedger(store: store, boot: { "boot-A" }).recordChangeCount(2))
        XCTAssertFalse(ClipboardWriteLedger(store: store, boot: { nil }).containsChangeCount(2), "拿不准就照常探测")
    }

    // MARK: - 值写成功、标识写失败

    func testBootKeyWriteFailureAfterValueVoidsRecord() {
        let store = BootKeyFailingStore()
        let before = ClipboardWriteLedger(store: store, boot: { "boot-A" })
        XCTAssertTrue(before.recordChangeCount(1))
        store.failBootWrites = true
        let after = ClipboardWriteLedger(store: store, boot: { "boot-B" })
        XCTAssertFalse(after.recordChangeCount(2), "标识没写上：返回没记下")
        XCTAssertEqual(store.read(changeKey), "2", "值已写上")
        XCTAssertEqual(store.read(changeKey + suffix), "boot-A", "标识仍是旧开机")
        XCTAssertFalse(after.containsChangeCount(2), "旧标识顶不了新值：作废")
        XCTAssertFalse(after.containsChangeCount(1))
    }

    func testBootKeyWriteFailureOnFreshStoreVoidsRecord() {
        let store = BootKeyFailingStore()
        store.failBootWrites = true
        let seen = ClipboardBootScopedRecord(key: seenKey, store: store, boot: { "boot-A" })
        XCTAssertFalse(seen.write("6"))
        XCTAssertEqual(store.read(seenKey), "6")
        XCTAssertNil(store.read(seenKey + suffix))
        XCTAssertNil(seen.read(), "没有标识：按没有判定过")
    }

    // MARK: - clear 删 _boot 键

    func testLedgerClearDeletesBootKey() throws {
        let store = MemoryClipboardHashStore()
        let ledger = ClipboardWriteLedger(store: store, boot: { "boot-A" })
        XCTAssertTrue(ledger.record("自写口令"))
        XCTAssertTrue(ledger.recordChangeCount(8))
        XCTAssertNotNil(store.read(changeKey + suffix))
        try ledger.clear()
        for key in [ClipboardWriteLedger.hashKey, changeKey, changeKey + suffix] {
            XCTAssertNil(store.read(key), "撤回同意：\(key) 删掉")
        }
        XCTAssertFalse(ledger.containsChangeCount(8))
    }

    func testRecordClearDeletesMemoryAndBootKey() throws {
        let store = MemoryClipboardHashStore()
        let boot = TestBoot(nil)
        let seen = ClipboardBootScopedRecord(key: seenKey, store: store, boot: { boot.value })
        XCTAssertTrue(seen.write("4"))
        boot.value = "boot-A"
        XCTAssertTrue(seen.write("5"))
        try seen.clear()
        XCTAssertNil(store.read(seenKey))
        XCTAssertNil(store.read(seenKey + suffix))
        XCTAssertNil(seen.read())
        boot.value = nil
        XCTAssertNil(seen.read(), "内存里那份也清掉")
    }

    func testClearThrowsWhenBootKeyDeleteFails() {
        let store = BootKeyFailingStore()
        let ledger = ClipboardWriteLedger(store: store, boot: { "boot-A" })
        XCTAssertTrue(ledger.recordChangeCount(8))
        store.failBootWrites = true
        XCTAssertThrowsError(try ledger.clear(), "_boot 键删除失败要抛错（清理器据此保留待清理标记）")
    }
}

/// 可改的开机标识（模拟换开机或取不到）。
private final class TestBoot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(_ value: String?) {
        stored = value
    }

    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// 只让 `_boot` 键写入失败的存储（模拟「值写成功、标识写失败」）。
private final class BootKeyFailingStore: ClipboardHashStore, @unchecked Sendable {
    private let inner = MemoryClipboardHashStore()
    var failBootWrites = false

    func read(_ key: String) -> String? {
        inner.read(key)
    }

    func write(_ key: String, _ value: String?) throws {
        if failBootWrites, key.hasSuffix(ClipboardBootScopedRecord.bootSuffix) {
            throw ClipboardStoreError.writeFailed
        }
        try inner.write(key, value)
    }
}
