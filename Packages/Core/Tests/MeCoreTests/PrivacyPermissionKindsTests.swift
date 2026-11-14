import Foundation
@testable import MeCore
import XCTest

/// LOCK-ios 段 1（D10-1606 ①、D10-1612 2；与 Android LockPermissionKindsTest 同意图）：隐私中心「系统权限」一节的判据是
/// `PrivacyCenterView.permissionKinds` 这张显式表，只列 userRequested 类型；看类型、不看 purpose_key。
/// 契约 d47f660e5 的权限清单新增了安装即授予的 vibrate / network / dynamic_receiver，表里没有归类的新类型一出现就报红。
final class PrivacyPermissionKindsTests: XCTestCase {
    private struct RootNotFound: Error {}

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { throw RootNotFound() }
            directory = parent
        }
        return directory
    }

    /// 快照 specs/system-permissions.json 的 permissions（全部端）。
    private func snapshotEntries() throws -> [[String: Any]] {
        let url = try repositoryRoot().appendingPathComponent("contracts/snapshot/specs/system-permissions.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try XCTUnwrap(root["permissions"] as? [[String: Any]], "快照缺 permissions")
        XCTAssertFalse(entries.isEmpty, "快照 permissions 为空（守卫失效）")
        return entries
    }

    private func rows(_ entries: [[String: Any]], platform: String, level: String = MeLevel.member) -> [String] {
        PrivacyCenterView.model(level: level, platform: platform, permissionEntries: entries, permissionStatus: [:])
            .permissionRows.map(\.type)
    }

    // ① 出现新类型即红

    func testEverySnapshotPermissionTypeIsClassified() throws {
        let types = Set(try snapshotEntries().compactMap { $0["type"] as? String })
        let unclassified = types.subtracting(PrivacyCenterView.permissionKinds.keys)
        XCTAssertTrue(
            unclassified.isEmpty,
            "快照权限清单有未归类的类型：\(unclassified.sorted())（在 PrivacyCenterView.permissionKinds 补归类）"
        )
    }

    /// PermissionRequester 能申请的类型（文案表 push / photos）都归为向用户申请，且向用户申请的就是这几类。
    func testUserRequestedTypesAreExactlyTheRequestableOnes() {
        let userRequested = Set(PrivacyCenterView.permissionKinds.filter { $0.value == .userRequested }.keys)
        XCTAssertEqual(userRequested, ["push", "photos"])
    }

    // ② 安装即授予的类型不进 permissionRows

    func testInstallGrantedTypesNeverBecomeRows() throws {
        let entries = try snapshotEntries()
        let installGranted = Set(PrivacyCenterView.permissionKinds.filter { $0.value == .installGranted }.keys)
        XCTAssertTrue(installGranted.isSuperset(of: ["vibrate", "network", "dynamic_receiver"]))
        for platform in [MePlatform.ios, MePlatform.android, MePlatform.harmony] {
            for level in [MeLevel.member, MeLevel.guest, MeLevel.basic] {
                let listed = Set(rows(entries, platform: platform, level: level))
                XCTAssertTrue(listed.isDisjoint(with: installGranted), "\(platform)/\(level) 列出了安装即授予的类型：\(listed)")
            }
        }
        // 快照里安卓、鸿蒙只有安装即授予的条目：系统权限一节没有行（鸿蒙 vibrate 有 purpose_key 也不列）
        XCTAssertEqual(rows(entries, platform: MePlatform.android), [])
        XCTAssertEqual(rows(entries, platform: MePlatform.harmony), [])
    }

    /// 判据看类型、不看 purpose_key：向用户申请 + 空 purpose_key 仍列出；安装即授予 + 非空 purpose_key 仍不列；未归类类型保守不列。
    func testCriterionIsTheTypeNotThePurposeKey() throws {
        let entries: [[String: Any]] = [
            ["type": "push", "platform": MePlatform.ios, "purpose_key": NSNull()],
            ["type": "network", "platform": MePlatform.ios, "purpose_key": "perm.network.system_purpose"],
            ["type": "camera_future", "platform": MePlatform.ios, "purpose_key": "perm.camera.purpose"],
        ]
        let model = PrivacyCenterView.model(
            level: MeLevel.member, platform: MePlatform.ios, permissionEntries: entries, permissionStatus: [:]
        )
        XCTAssertEqual(model.permissionRows.map(\.type), ["push"])
        XCTAssertNil(try XCTUnwrap(model.permissionRows.first).purposeKey)
    }

    // ③ iOS 的 push / photos 照旧列出

    func testIosStillListsPushAndPhotosInSnapshotOrder() throws {
        let entries = try snapshotEntries()
        let expected = entries.filter { $0["platform"] as? String == MePlatform.ios }
            .compactMap { $0["type"] as? String }
        XCTAssertEqual(Set(expected), ["push", "photos"], "前提：快照 iOS 条目仍是 push / photos")
        let model = PrivacyCenterView.model(
            level: MeLevel.member, platform: MePlatform.ios, permissionEntries: entries,
            permissionStatus: ["push": "granted", "photos": "permanently_denied"]
        )
        XCTAssertEqual(model.permissionRows.map(\.type), expected, "按快照顺序列出")
        let byType = Dictionary(uniqueKeysWithValues: model.permissionRows.map { ($0.type, $0) })
        XCTAssertEqual(byType["push"]?.statusKey, "privacy.system_permissions.status.granted")
        XCTAssertEqual(byType["photos"]?.statusKey, "privacy.system_permissions.status.denied")
        for row in model.permissionRows {
            let entry = entries
                .first { $0["type"] as? String == row.type && $0["platform"] as? String == MePlatform.ios }
            XCTAssertEqual(row.purposeKey, entry?["purpose_key"] as? String, row.type)
        }
        // 基本模式、游客同样列出；强制更新时整节不显示
        XCTAssertEqual(rows(entries, platform: MePlatform.ios, level: MeLevel.basic), expected)
        XCTAssertEqual(rows(entries, platform: MePlatform.ios, level: MeLevel.guest), expected)
        let forced = PrivacyCenterView.model(
            level: MeLevel.member, platform: MePlatform.ios, permissionEntries: entries, permissionStatus: [:],
            forceUpdate: true
        )
        XCTAssertTrue(forced.permissionRows.isEmpty)
    }
}
