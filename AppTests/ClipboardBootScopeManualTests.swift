import ClientCore
import Clipboard
@testable import Couli
import Foundation
import Router
import XCTest

/// FU-IOS-CLIP-COLDSTART-MISSED（D10-1753 ④⑤）：手动粘贴（首页常驻卡、SearchTyping）不读自写账本、照常识别、不写两项计数缓存；
/// 旧格式与取不到开机标识、标识写失败按无记录；撤回同意、DEBUG 重置、隐私变化都删掉 `_boot` 键。组装见 ClipboardBootScopeTests 的 BootRig。
@MainActor
final class ClipboardBootScopeManualTests: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    var directory: URL!

    let selfWrittenKey = "self_written"
    let selfWrittenChangeKey = "self_written_change"

    override func setUp() async throws {
        suiteName = "ClipboardBootScopeManualTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func rig(_ store: ClipboardHashStore, boot: String?) -> BootRig {
        BootRig.make(defaults: defaults, store: store, boot: { boot })
    }

    func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    /// 两项计数缓存的值与 `_boot` 键，外加自写 hash。
    var recordKeys: [String] {
        let suffix = ClipboardBootScopedRecord.bootSuffix
        return [selfWrittenKey, selfWrittenChangeKey, selfWrittenChangeKey + suffix,
                AppClipboard.lastChangeKey, AppClipboard.lastChangeKey + suffix]
    }

    func snapshot(_ store: ClipboardHashStore) -> [String?] {
        recordKeys.map { store.read($0) }
    }

    // MARK: - 7 手动粘贴自写内容照常识别

    func testManualPasteOfSelfWrittenProductIsParsed() async throws {
        for entry in [ManualPasteAction.entryHome, ManualPasteAction.entrySearchTyping] {
            let fixture = rig(MemoryClipboardHashStore(), boot: "boot-A")
            if entry == ManualPasteAction.entrySearchTyping {
                fixture.routing.router.path = [RouteDestination(route: "Search")]
            }
            fixture.clipboard.sceneActive()
            XCTAssertTrue(fixture.clipboard.writer.write(BootRig.link))
            fixture.clipboard.pasted(entry: entry, text: BootRig.link)
            await settle()
            XCTAssertEqual(fixture.api.bodies.count, 1, "\(entry)：App 写过的淘口令手动粘贴照常 1 次 parse")
            XCTAssertTrue(try XCTUnwrap(fixture.api.bodies.first).contains("h.Demo01"), entry)
        }
    }

    func testManualPasteOfSelfWrittenInviteShowsConfirmForGuest() throws {
        let fixture = rig(MemoryClipboardHashStore(), boot: "boot-A")
        fixture.clipboard.sceneActive()
        XCTAssertTrue(fixture.clipboard.writer.write(BootRig.invite))
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: BootRig.invite)
        guard case let .inviteConfirm(code) = try XCTUnwrap(fixture.clipboard.result).kind else {
            return XCTFail("自写纯邀请：游客手动粘贴出邀请确认")
        }
        XCTAssertEqual(code, "K7M2QX")
        XCTAssertEqual(fixture.api.bodies.count, 0)
    }

    /// 对照：提示条（自动任务）里粘贴自写纯邀请 → 按 hash 排除、静默。
    func testPromptPasteOfSelfWrittenInviteStaysSilent() throws {
        let store = MemoryClipboardHashStore()
        let before = rig(store, boot: "boot-A")
        XCTAssertTrue(before.clipboard.writer.write(BootRig.invite))
        let after = rig(store, boot: "boot-B")
        after.system.changeCount = before.system.changeCount
        after.system.detectHit = true
        after.clipboard.sceneActive()
        let prompt = try XCTUnwrap(after.clipboard.prompt)
        after.clipboard.promptPasted(prompt.id, text: BootRig.invite)
        XCTAssertNil(after.clipboard.result, "自动任务读到自写纯邀请：静默")
        XCTAssertEqual(after.api.bodies.count, 0)
    }

    // MARK: - 8 手动粘贴前后两项计数缓存不变

    func testManualPasteLeavesCountRecordsUntouched() async {
        let store = MemoryClipboardHashStore()
        let fixture = rig(store, boot: "boot-A")
        XCTAssertTrue(fixture.clipboard.writer.write(BootRig.link))
        fixture.clipboard.sceneActive()
        let before = snapshot(store)
        XCTAssertEqual(before.compactMap(\.self).count, recordKeys.count, "前提：五个键都已落盘 \(before)")
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: BootRig.link)
        await settle()
        fixture.routing.router.path = [RouteDestination(route: "Search")]
        fixture.clipboard.pasted(entry: ManualPasteAction.entrySearchTyping, text: BootRig.otherLink)
        await settle()
        XCTAssertEqual(fixture.api.bodies.count, 2)
        XCTAssertEqual(snapshot(store), before, "手动粘贴不读不写 self_written*、ios_change_seen*")
    }

    // MARK: - 9 旧格式（无 _boot 键）按无记录

    func testLegacyRecordsWithoutBootKeyAreIgnored() throws {
        for legacy in [selfWrittenChangeKey, AppClipboard.lastChangeKey] {
            let store = MemoryClipboardHashStore()
            try store.write(legacy, "5")
            let fixture = rig(store, boot: "boot-A")
            fixture.system.changeCount = 5
            fixture.system.detectHit = true
            fixture.clipboard.sceneActive()
            XCTAssertEqual(fixture.system.detectCalls, 1, "旧版只有 \(legacy)：照常探测")
            XCTAssertNotNil(fixture.clipboard.prompt, legacy)
        }
    }

    // MARK: - 10 取不到开机标识

    func testNoBootIdentityKeepsCountsInMemoryOnly() async throws {
        let store = MemoryClipboardHashStore()
        let fixture = rig(store, boot: nil)
        XCTAssertTrue(fixture.clipboard.writer.write(BootRig.link))
        fixture.system.detectHit = true
        fixture.clipboard.sceneActive()
        XCTAssertEqual(fixture.system.detectCalls, 0, "同一实例内自写后仍跳过")
        for key in recordKeys.dropFirst() {
            XCTAssertNil(store.read(key), "取不到开机标识：盘上不出现 \(key)")
        }
        XCTAssertNotNil(store.read(selfWrittenKey), "自写 hash 照常落盘")
        let relaunched = rig(store, boot: nil)
        relaunched.system.changeCount = fixture.system.changeCount
        relaunched.system.detectHit = true
        relaunched.clipboard.sceneActive()
        XCTAssertEqual(relaunched.system.detectCalls, 1, "新实例同一存储看不到计数：照常探测")
        let prompt = try XCTUnwrap(relaunched.clipboard.prompt)
        relaunched.clipboard.promptPasted(prompt.id, text: BootRig.link)
        await settle()
        XCTAssertEqual(relaunched.api.bodies.count, 0, "读到正文按 hash 排除自写")
    }

    // MARK: - 11 值写成功、标识写失败 → 作废

    func testBootKeyWriteFailureVoidsCounts() {
        let store = AppBootKeyFailingStore()
        let fixture = rig(store, boot: "boot-A")
        XCTAssertTrue(fixture.clipboard.writer.write(BootRig.link), "自写 hash 已落盘：照常写剪贴板")
        XCTAssertEqual(store.read(selfWrittenChangeKey), "1", "值已写上")
        XCTAssertNil(store.read(selfWrittenChangeKey + ClipboardBootScopedRecord.bootSuffix))
        fixture.system.detectHit = true
        fixture.clipboard.sceneActive()
        XCTAssertEqual(fixture.system.detectCalls, 1, "标识没写上：自写计数作废，照常探测")
        XCTAssertEqual(store.read(AppClipboard.lastChangeKey), "1")
        fixture.clipboard.sceneBackground()
        fixture.clipboard.sceneActive()
        XCTAssertEqual(fixture.system.detectCalls, 2, "ios_change_seen 同样作废：不判「没变化」")
    }

    // MARK: - 12 清理都删掉 _boot 键

    func testPrivacyChangeClearsBootKeys() {
        let store = MemoryClipboardHashStore()
        let fixture = rig(store, boot: "boot-A")
        XCTAssertTrue(fixture.clipboard.writer.write(BootRig.link))
        fixture.clipboard.sceneActive()
        XCTAssertEqual(snapshot(store).compactMap(\.self).count, recordKeys.count)
        fixture.clipboard.privacyChanged(.basicMode)
        XCTAssertEqual(snapshot(store), [String?](repeating: nil, count: recordKeys.count), "撤回 / 基本模式：值与 _boot 键都删")
    }

    func testWithdrawalCleanerDeletesBootKeys() throws {
        let store = fileStore()
        populate(store)
        try ClipboardRecordsCleaner(store: store).cleanForEnvironmentSwitch()
        XCTAssertEqual(snapshot(store), [String?](repeating: nil, count: recordKeys.count))
        let file = directory.appendingPathComponent("com.couli.app/records.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    #if DEBUG
    func testDebugSelfWrittenResetDeletesBootKey() {
        let store = fileStore()
        populate(store)
        defaults.set(true, forKey: ClipboardFileStore.debugSelfWrittenResetArgument)
        store.debugResetSelfWrittenIfRequested(defaults)
        let suffix = ClipboardBootScopedRecord.bootSuffix
        for key in [selfWrittenKey, selfWrittenChangeKey, selfWrittenChangeKey + suffix] {
            XCTAssertNil(store.read(key), "DEBUG 重置删 \(key)")
        }
        XCTAssertEqual(store.read(AppClipboard.lastChangeKey), "3", "ios_change_seen 不动")
        XCTAssertEqual(store.read(AppClipboard.lastChangeKey + suffix), "boot-A")
    }
    #endif

    func fileStore() -> ClipboardFileStore {
        ClipboardFileStore(file: ClientFile(name: "records.json", baseDirectory: directory))
    }

    func populate(_ store: ClipboardHashStore) {
        let ledger = ClipboardWriteLedger(store: store, boot: { "boot-A" })
        XCTAssertTrue(ledger.record(BootRig.link))
        XCTAssertTrue(ledger.recordChangeCount(3))
        let seen = ClipboardBootScopedRecord(key: AppClipboard.lastChangeKey, store: store, boot: { "boot-A" })
        XCTAssertTrue(seen.write("3"))
        XCTAssertEqual(snapshot(store).compactMap(\.self).count, recordKeys.count, "前提：五个键都已落盘")
    }
}

/// 只让 `_boot` 键写入失败的存储（模拟「值写成功、标识写失败」）。
final class AppBootKeyFailingStore: ClipboardHashStore, @unchecked Sendable {
    private let inner = MemoryClipboardHashStore()

    func read(_ key: String) -> String? {
        inner.read(key)
    }

    func write(_ key: String, _ value: String?) throws {
        if key.hasSuffix(ClipboardBootScopedRecord.bootSuffix) {
            throw ClipboardStoreError.writeFailed
        }
        try inner.write(key, value)
    }
}
