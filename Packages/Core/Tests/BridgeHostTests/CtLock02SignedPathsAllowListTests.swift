@testable import BridgeHost
import Foundation
import XCTest

/// CT-LOCK-02 复审 r1：桥运行时白名单（BridgeContract.shared.signedPaths）与协议准入（BridgeProtocol.signedPathAllowed）
/// 都要与锁定快照 bridge.schema.json 的 signed_paths 双向一致。预期值直接读 contracts/snapshot 文件，不经生成物或运行时。
/// 运行时多放一项、少放一项都使本测试变红（变异记录见 NATIVE/CT-LOCK-02/ios-mutations.txt）。
final class CtLock02SignedPathsAllowListTests: XCTestCase {
    private func snapshot(_ name: String) throws -> [String: Any] {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw XCTSkip("找不到仓库根目录") as Error
            }
            directory = parent
        }
        let url = directory.appendingPathComponent("contracts/snapshot/contracts/\(name)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], name)
    }

    /// 快照 signed_paths："METHOD path"。
    private func snapshotSignedPaths() throws -> [String] {
        let rows = try XCTUnwrap(try snapshot("bridge.schema.json")["signed_paths"] as? [[String: Any]])
        return try rows.map { row in
            let method = try XCTUnwrap(row["method"] as? String)
            let path = try XCTUnwrap(row["path"] as? String)
            return "\(method) \(path)"
        }
    }

    /// 快照 openapi 的全部客户端接口（不含 /admin/），签名与否都算候选："METHOD path"。
    private func snapshotClientOperations() throws -> Set<String> {
        let paths = try XCTUnwrap(try snapshot("openapi.json")["paths"] as? [String: Any])
        var result: Set<String> = []
        for (path, item) in paths where !path.hasPrefix("/admin/") {
            for (method, value) in item as? [String: Any] ?? [:]
                where (value as? [String: Any])?["operationId"] != nil {
                result.insert("\(method.uppercased()) \(path)")
            }
        }
        return result
    }

    private func split(_ key: String) -> (method: String, path: String) {
        let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }

    func testRuntimeAllowListEqualsSnapshotSignedPaths() throws {
        let expected = try snapshotSignedPaths()
        XCTAssertFalse(expected.isEmpty, "前提：快照 signed_paths 非空")
        let runtime = BridgeContract.shared.signedPaths.map { "\($0.method) \($0.path)" }
        XCTAssertEqual(runtime.count, Set(runtime).count, "运行时白名单没有重复项")
        XCTAssertEqual(Set(runtime).subtracting(expected), [], "多出的项")
        XCTAssertEqual(Set(expected).subtracting(runtime), [], "缺少的项")
    }

    func testProtocolAdmitsExactlyTheSnapshotSignedPaths() throws {
        let expected = Set(try snapshotSignedPaths())
        let runtime = BridgeContract.shared.signedPaths.map { "\($0.method) \($0.path)" }
        let candidates = try snapshotClientOperations().union(expected).union(runtime)
        let admitted = candidates.filter { key in
            let parts = split(key)
            return BridgeProtocol.signedPathAllowed(method: parts.method, path: parts.path)
        }
        XCTAssertEqual(admitted, expected)
        for key in candidates.subtracting(expected) {
            let parts = split(key)
            XCTAssertFalse(BridgeProtocol.signedPathAllowed(method: parts.method, path: parts.path), "白名单外不准入：\(key)")
            XCTAssertFalse(
                BridgeProtocol.signedPathAllowed(method: parts.method, path: parts.path + "?x=1"), "带查询串也不准入：\(key)"
            )
        }
    }
}
