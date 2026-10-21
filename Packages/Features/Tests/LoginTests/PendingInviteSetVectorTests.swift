import Foundation
@testable import Login
import XCTest

/// FU-IOS-0729：直接调用生产容器，逐条执行三端共用 pendingInviteSet v2；不在测试里规范化输入。
@MainActor
final class PendingInviteSetVectorTests: XCTestCase {
    func testSharedManifestV2() throws {
        let vectors = try PendingInviteSetVectors.load()
        XCTAssertEqual(vectors.version, 2)
        XCTAssertEqual(vectors.valid.count, 8)
        XCTAssertEqual(vectors.invalid.count, 11)
        XCTAssertEqual(vectors.sequences.count, 3)
    }

    func testValidVectorsStoreNormalizedCode() throws {
        for (index, row) in try PendingInviteSetVectors.load().valid.enumerated() {
            let pending = PendingInviteCode()
            pending.set(row.raw)
            XCTAssertEqual(pending.peek(), row.stored, label("valid", index, row.raw))
        }
    }

    func testInvalidVectorsLeaveEmptyContainerEmpty() throws {
        for (index, raw) in try PendingInviteSetVectors.load().invalid.enumerated() {
            let pending = PendingInviteCode()
            pending.set(raw)
            XCTAssertNil(pending.peek(), label("invalid.empty", index, raw))
        }
    }

    func testInvalidVectorsPreservePreviousCode() throws {
        let previous = "PREV23"
        for (index, raw) in try PendingInviteSetVectors.load().invalid.enumerated() {
            let pending = PendingInviteCode()
            pending.set(previous)
            let context = label("invalid.preserve", index, raw)
            XCTAssertEqual(pending.peek(), previous, "\(context)：先确认旧码已写入")
            pending.set(raw)
            XCTAssertEqual(pending.peek(), previous, context)
        }
    }

    func testSequenceVectorsStoreFinalCode() throws {
        for (index, row) in try PendingInviteSetVectors.load().sequences.enumerated() {
            let pending = PendingInviteCode()
            let context = "pendingInviteSet.sequences[\(index)] steps=\(row.steps.debugDescription)"
            XCTAssertFalse(row.steps.isEmpty, context)
            for raw in row.steps {
                pending.set(raw)
            }
            XCTAssertEqual(pending.peek(), row.stored, context)
        }
    }

    private func label(_ group: String, _ index: Int, _ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
        return "pendingInviteSet.\(group)[\(index)] raw=\(raw.debugDescription) scalars=[\(scalars)]"
    }
}

/// 沿用 LoginVectorTests 的 specs 路径查找；InviteLink 测试也从这里取 invalid，避免再维护手写列表。
struct PendingInviteSetVectors: Decodable {
    struct Valid: Decodable {
        let raw: String
        let stored: String
    }

    struct Sequence: Decodable {
        let steps: [String]
        let stored: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: SequenceCodingKeys.self)
            steps = try container.decode([String].self, forKey: .steps)
            // 显式 null 才表示空容器；缺少 stored 必须报错，不能把缺失期望当成 nil。
            stored = try container.decode(String?.self, forKey: .stored)
        }
    }

    private enum SequenceCodingKeys: String, CodingKey {
        case steps, stored
    }

    private struct Manifest: Decodable {
        let pendingInviteSet: PendingInviteSetVectors
    }

    let version: Int
    let valid: [Valid]
    let invalid: [String]
    let sequences: [Sequence]

    static func load() throws -> PendingInviteSetVectors {
        var directory = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw NSError(
                    domain: "PendingInviteSetVectors", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "从 \(#filePath) 向上找不到 contract.lock"]
                )
            }
            directory = parent
        }
        let url = directory.appendingPathComponent("specs/login-vectors.json")
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)).pendingInviteSet
    }
}
