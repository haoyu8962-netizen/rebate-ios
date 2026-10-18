import Foundation
@testable import HomeCore
import XCTest

/// HomeVectorTests 的关系向量与比较工具（照 Codex 原稿的比较口径）。
extension HomeVectorTests {
    // MARK: - 关系向量（只比较相等关系，不锁定代拟分隔符）

    func relationValue(_ row: JSONObject, _ group: String) throws -> String {
        if group == "lkgScope" {
            return HomeLkgScope.of(
                level: try field(row, "levelRaw"), userId: row["userId"] as? String, env: try field(row, "envRaw")
            )
        }
        return NoticeFilter.closeKey(
            sectionId: try field(row, "sectionId"), itemId: try field(row, "itemId"),
            contentVersion: try field(row, "contentVersion")
        )
    }

    func checkRelations(_ root: JSONObject, group: String, key: String) throws {
        let rows: [JSONObject] = try field(root, group)
        let actual = try rows.map { try relationValue($0, group) }
        let expected: [String] = try rows.map {
            let expect: JSONObject = try field($0, "expect")
            return try field(expect, key)
        }
        for row in rows.indices {
            XCTAssertFalse(actual[row].isEmpty, "\(group)[\(row)]")
            for col in rows.indices {
                XCTAssertEqual(actual[row] == actual[col], expected[row] == expected[col], "\(group)[\(row),\(col)]")
            }
        }
    }

    func mappedCloseKey(_ fixtureKey: String, _ root: JSONObject) throws -> String {
        let rows: [JSONObject] = try field(root, "noticeCloseKey")
        for row in rows {
            let expect: JSONObject = try field(row, "expect")
            if (expect["key"] as? String) == fixtureKey {
                return try relationValue(row, "noticeCloseKey")
            }
        }
        throw HomeVectors.failure("关闭键未在 noticeCloseKey 定义：\(fixtureKey)")
    }

    func labelInput(_ value: Any?) -> Any? {
        (value as? String) == "absent" ? nil : value
    }

    // MARK: - 比较

    /// 对象只比较 expect 已写字段；数组有序且等长；params、closable 精确比较；期望 null 时实际缺省或 null 都算无值。
    func match(_ actual: Any?, _ expected: Any, _ path: String, exact: Bool = false) throws {
        if expected is NSNull {
            XCTAssertTrue(actual == nil || actual is NSNull, "\(path): 应无值，实际 \(String(describing: actual))")
            return
        }
        if let expectedArray = expected as? [Any] {
            let actualArray = try XCTUnwrap(actual as? [Any], "\(path): 应为数组")
            XCTAssertEqual(actualArray.count, expectedArray.count, path)
            guard actualArray.count == expectedArray.count else { return }
            for index in expectedArray.indices {
                try match(actualArray[index], expectedArray[index], "\(path)[\(index)]", exact: exact)
            }
            return
        }
        if let expectedObject = expected as? JSONObject {
            let actualObject = try XCTUnwrap(actual as? JSONObject, "\(path): 应为对象")
            if exact {
                XCTAssertEqual(Set(actualObject.keys), Set(expectedObject.keys), path)
            }
            for (key, value) in expectedObject {
                try match(
                    actualObject[key], value, "\(path).\(key)", exact: exact || key == "params" || key == "closable"
                )
            }
            return
        }
        let value = try XCTUnwrap(actual, "\(path): 缺字段")
        XCTAssertEqual(try HomeVectors.canonical(value), try HomeVectors.canonical(expected), path)
    }

    func field<T>(_ object: JSONObject, _ key: String) throws -> T {
        try XCTUnwrap(object[key] as? T, "\(key): 缺失或类型错误")
    }
}
