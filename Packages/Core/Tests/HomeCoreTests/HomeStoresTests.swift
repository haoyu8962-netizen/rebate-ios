import CryptoKit
import Foundation
@testable import HomeCore
import XCTest

/// 首页本机数据（G11、G16 ②、G17、G30；brief §0「缓存与清理」；cross-platform-lessons 第 8、9、19、23、32、33 条；F-X-17、F-X-19、F-X-21、
/// F-HM-35）。全部用生产存储，故障用真实文件系统权限制造（不加注入点）。
@MainActor
final class HomeStoresTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("home-stores-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        unlockAll(base)
        try? FileManager.default.removeItem(at: base)
    }

    private var root: URL {
        base.appendingPathComponent(HomeLkgStore.directoryName, isDirectory: true)
    }

    private func store() -> HomeLkgStore {
        HomeLkgStore(root: root)
    }

    private func page(_ version: Int) -> Data {
        HomeVectors.data(HomeKit.page(version: version, [HomeKit.activity("a", titles: ["测试"])]))
    }

    private func version(_ data: Data?) -> Int? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? Int
    }

    private func key(_ identity: HomeIdentity) throws -> HomeScopeKey {
        try XCTUnwrap(identity.lkgScope, "\(identity) 没有 LKG 分区")
    }

    // MARK: - 分区（G16 ②、F-HM-35、F-X-21）

    /// 按「环境 + 账号作用域（user_id / guest / basic）」分区；会员再按持久化登录世代分（同账号重登读不回旧世代）。
    func testLkgPartitionedByEnvironmentScopeAndLoginEpoch() throws {
        let lkg = store()
        let memberA = HomeKit.memberA
        XCTAssertTrue(lkg.write(try key(memberA), page(7), ticket: lkg.ticket()))
        XCTAssertEqual(version(lkg.read(try key(memberA))), 7)
        let others: [HomeIdentity] = [
            HomeKit.memberB, HomeKit.guest, HomeKit.basic,
            HomeIdentity(env: "staging", level: .member, userId: "user-a", loginEpoch: "e1"),
            HomeIdentity(env: "test", level: .member, userId: "user-a", loginEpoch: "e2"),
            HomeIdentity(env: "test", level: .member, userId: "guest", loginEpoch: "e1"),
        ]
        for other in others {
            XCTAssertNil(lkg.read(try key(other)), "\(other) 读到了会员 A 的 LKG")
        }
        // 游客、基本模式互不串
        XCTAssertTrue(lkg.write(try key(HomeKit.guest), page(8), ticket: lkg.ticket()))
        XCTAssertNil(lkg.read(try key(HomeKit.basic)))
        XCTAssertEqual(version(lkg.read(try key(HomeKit.guest))), 8)
        XCTAssertEqual(version(lkg.read(try key(memberA))), 7)
    }

    /// 身份暂时未知、会员缺持久化登录世代（升级前登录的合法旧会话）：没有 LKG 分区（不读不写，F-X-19、F-X-21）。
    func testUnknownIdentityAndMemberWithoutEpochHaveNoScope() {
        XCTAssertNil(HomeIdentity(env: "test", level: .member, userId: "user-a", loginEpoch: nil).lkgScope)
        XCTAssertNil(HomeIdentity(env: "test", level: .member, userId: "user-a", loginEpoch: "e1", known: false)
            .lkgScope)
        XCTAssertNil(HomeIdentity(env: "test", level: .guest, userId: nil, loginEpoch: nil, known: false).lkgScope)
        XCTAssertNotNil(HomeKit.guest.lkgScope, "对照：已确认的游客有分区")
        XCTAssertNotNil(HomeKit.basic.lkgScope, "对照：基本模式有分区")
    }

    // MARK: - 清理（G16 ②、G11；共性第 8、33 条）

    /// 退出 / 换账号 / 会话失效只清旧账号作用域；撤回同意 / 切换环境全清，含临时文件。
    func testClearScopeOnlyOldScopeAndClearAllIncludingTemporaryFiles() throws {
        let lkg = store()
        for identity in [HomeKit.memberA, HomeKit.memberB, HomeKit.guest] {
            XCTAssertTrue(lkg.write(try key(identity), page(3), ticket: lkg.ticket()))
        }
        try lkg.clearScope(try key(HomeKit.memberA))
        XCTAssertNil(lkg.read(try key(HomeKit.memberA)))
        XCTAssertEqual(version(lkg.read(try key(HomeKit.memberB))), 3)
        XCTAssertEqual(version(lkg.read(try key(HomeKit.guest))), 3)
        // 写到一半留下的临时文件（原子写：临时文件 + 改名）也在清理范围（APP-03b 第 1 条）
        let stray = root.appendingPathComponent("stray.json.tmp")
        try Data("{".utf8).write(to: stray)
        try lkg.clearAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path), "临时文件没清")
        XCTAssertNil(lkg.read(try key(HomeKit.memberB)))
        XCTAssertNil(lkg.read(try key(HomeKit.guest)))
        XCTAssertFalse(lkg.isPendingClear)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(left.isEmpty, "清完还剩 \(left)")
    }

    /// 删除失败：待清理标记在 LKG 目录之外（确认写入），本进程不再读回；「重启」（新实例）读之前先补清，补清完成才清标记。
    func testFailedDeleteKeepsFlagOutsideAndRestartCompletesBeforeReading() throws {
        let lkg = store()
        XCTAssertTrue(lkg.write(try key(HomeKit.memberA), page(5), ticket: lkg.ticket()))
        let flag = lkg.pendingFlagURL
        XCTAssertFalse(
            flag.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
            "待清理标记必须在 LKG 目录之外：\(flag.path)"
        )
        lockAll(root)
        XCTAssertThrowsError(try lkg.clearAll(), "删不掉必须报失败（交给清理协调器，共性第 8 条）")
        XCTAssertTrue(FileManager.default.fileExists(atPath: flag.path), "标记没落盘")
        XCTAssertTrue(lkg.isPendingClear)
        XCTAssertNil(lkg.read(try key(HomeKit.memberA)), "待清理期间读回了旧 LKG")
        XCTAssertFalse(lkg.write(try key(HomeKit.guest), page(6), ticket: lkg.ticket()), "待清理期间不得写入")
        // 重启：权限恢复后新实例在读之前补清
        unlockAll(root)
        let restarted = store()
        XCTAssertNil(restarted.read(try key(HomeKit.memberA)), "重启后读回了旧 LKG")
        XCTAssertFalse(restarted.isPendingClear)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flag.path), "补清完成后标记没清")
        // 补清之后正常可写可读（对照：不是从此不读不写）
        XCTAssertTrue(restarted.write(try key(HomeKit.memberA), page(9), ticket: restarted.ticket()))
        XCTAssertEqual(version(restarted.read(try key(HomeKit.memberA))), 9)
    }

    /// 补清仍失败：新实例照样不读回，标记保留；`completePendingClear` 报未完成。
    func testRestartWhileStillUndeletableNeverReadsOldPage() throws {
        let lkg = store()
        XCTAssertTrue(lkg.write(try key(HomeKit.guest), page(5), ticket: lkg.ticket()))
        lockAll(root)
        XCTAssertThrowsError(try lkg.clearAll())
        let restarted = store()
        XCTAssertNil(restarted.read(try key(HomeKit.guest)))
        XCTAssertFalse(restarted.completePendingClear())
        XCTAssertTrue(FileManager.default.fileExists(atPath: restarted.pendingFlagURL.path))
        unlockAll(root)
        XCTAssertTrue(restarted.completePendingClear())
        XCTAssertNil(restarted.read(try key(HomeKit.guest)))
    }

    /// 待清理标记写不进（LKG 目录之外的位置不可写）且删除失败：错误上抛给清理协调器，本进程在确认清完之前不读旧 LKG；
    /// 恢复可写后补清完成，读写恢复正常（共性第 8 条；三条通道都失效的边界按鸿蒙 H16 不扩大要求）。
    func testPendingFlagWriteFailureWithDeleteFailureIsReportedAndBlocksReads() throws {
        let lkg = store()
        XCTAssertTrue(lkg.write(try key(HomeKit.memberA), page(5), ticket: lkg.ticket()))
        let flagParent = lkg.pendingFlagURL.deletingLastPathComponent()
        lockAll(root)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: flagParent.path)
        XCTAssertThrowsError(try lkg.clearAll(), "标记写不进、删除也失败，必须报给协调器")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lkg.pendingFlagURL.path), "前提：标记确实没写进")
        XCTAssertNil(lkg.read(try key(HomeKit.memberA)), "没确认清完就读回了旧 LKG")
        XCTAssertTrue(lkg.isPendingClear)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: flagParent.path)
        unlockAll(root)
        XCTAssertTrue(lkg.completePendingClear())
        XCTAssertNil(lkg.read(try key(HomeKit.memberA)), "补清之后旧 LKG 不应还在")
        XCTAssertTrue(lkg.write(try key(HomeKit.memberA), page(6), ticket: lkg.ticket()))
        XCTAssertEqual(version(lkg.read(try key(HomeKit.memberA))), 6)
    }

    /// 只有标记写不进、删除本身成功：清理结果仍是「已清空」（旧 LKG 读不回），之后读写正常。
    func testPendingFlagWriteFailureAloneStillClearsData() throws {
        let lkg = store()
        XCTAssertTrue(lkg.write(try key(HomeKit.guest), page(5), ticket: lkg.ticket()))
        let flagParent = lkg.pendingFlagURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: flagParent.path)
        try? lkg.clearAll()
        XCTAssertNil(lkg.read(try key(HomeKit.guest)), "清理之后读回了旧 LKG")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: flagParent.path)
        XCTAssertTrue(lkg.completePendingClear())
        XCTAssertTrue(lkg.write(try key(HomeKit.guest), page(7), ticket: lkg.ticket()))
        XCTAssertEqual(version(lkg.read(try key(HomeKit.guest))), 7)
    }

    /// 目录在、却枚举失败（不是「目录不存在」）：保留待清理并报失败（共性第 20 条）。
    func testUnlistableDirectoryIsIncompleteNotMissing() throws {
        let lkg = store()
        XCTAssertTrue(lkg.write(try key(HomeKit.guest), page(5), ticket: lkg.ticket()))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try lkg.clearAll())
        XCTAssertTrue(lkg.isPendingClear)
        XCTAssertNil(lkg.read(try key(HomeKit.guest)))
    }

    /// 对照：目录根本不存在 → 清理直接完成（不当作失败）。
    func testMissingDirectoryIsClean() throws {
        let lkg = store()
        try lkg.clearAll()
        XCTAssertFalse(lkg.isPendingClear)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lkg.pendingFlagURL.path))
    }

    // MARK: - 写入世代与接受顺序（共性第 23、32、33 条）

    /// 清理前取的写入票据在清理后被拒（等锁的旧写入不能把文件写回来）。
    func testTicketTakenBeforeClearIsRejected() throws {
        let lkg = store()
        let stale = lkg.ticket()
        try lkg.clearAll()
        XCTAssertFalse(lkg.write(try key(HomeKit.memberA), page(4), ticket: stale))
        XCTAssertNil(lkg.read(try key(HomeKit.memberA)))
        let scoped = lkg.ticket()
        try lkg.clearScope(try key(HomeKit.memberA))
        XCTAssertFalse(lkg.write(try key(HomeKit.memberA), page(4), ticket: scoped), "清旧作用域前的票据写回了旧作用域")
        // 共性第 33 条：迟到的旧作用域清理不让别的作用域（新控制器）一直写不进去
        XCTAssertTrue(lkg.write(try key(HomeKit.guest), page(4), ticket: scoped), "清 A 作用域作废了游客的票据")
    }

    /// 接受顺序：较早接受的结果后到时不覆盖较新的结果。
    func testOlderAcceptedWriteArrivingLaterIsRejected() throws {
        let lkg = store()
        let first = lkg.ticket()
        let second = lkg.ticket()
        XCTAssertTrue(lkg.write(try key(HomeKit.memberA), page(3), ticket: second))
        XCTAssertFalse(lkg.write(try key(HomeKit.memberA), page(2), ticket: first))
        XCTAssertEqual(version(lkg.read(try key(HomeKit.memberA))), 3)
        // 对照：不同作用域互不影响
        XCTAssertTrue(lkg.write(try key(HomeKit.memberB), page(2), ticket: first))
    }

    // MARK: - 工具

    /// 把目录树设成只读（子项删不掉）。
    private func lockAll(_ url: URL) {
        let manager = FileManager.default
        if let children = manager.enumerator(atPath: url.path)?.allObjects as? [String] {
            for child in children {
                let path = url.appendingPathComponent(child).path
                var isDirectory: ObjCBool = false
                if manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    try? manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
                }
            }
        }
        try? manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
    }

    private func unlockAll(_ url: URL) {
        let manager = FileManager.default
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        if let children = manager.enumerator(atPath: url.path)?.allObjects as? [String] {
            for child in children {
                try? manager.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: url.appendingPathComponent(child).path
                )
            }
        }
    }
}
