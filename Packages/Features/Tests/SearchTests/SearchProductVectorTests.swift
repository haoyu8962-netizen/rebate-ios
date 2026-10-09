/*
 实现前测试；只读交付，未编译运行。

 接线约定：
 - @testable import Search；以下六个符号对 SearchTests 可见。
   详情共用逻辑可放 Core 并由 Search 转出，禁止 Product 依赖 Search。
 - 对象参数、query 使用 [String: Any]；金额在实现中按 Int64 读取。
 - SearchQuery.build(_ input) -> { valid: Bool, query, reasonRaw: String? }。
   filters 使用契约蛇形字段。有效 query 为平铺查询参数；
   省略 sort 与 relevance 等价。无效输入只判 valid，query:{} 是占位。
 - SearchTabs.resolve(_ searchStatus) -> [String]，返回平台原始编码。
   只判完整成员及无重复，暂不判顺序。
 - SearchPager()；append(_ response) 接收完整成功 envelope；
   items 为搜索命中对象数组，另行展示 fallback_items。
   endReached: Bool；stateRaw: String。每个向量新建实例。
 - SearchResultState.map(_ responseOrError) 接收完整 envelope，
   返回 stateRaw: String、textKey: String?；复用 Core 错误映射。
   content/empty 表示搜索命中有/无，error 表示请求失败。
 - SearchSession()；begin(kind: String) -> Int64、accept(_ seq: Int64)、
   leave()；shownSeq: Int64?。向量 seq 是符号引用，不要求计数器从 1 开始。
 - ProductDetailState.map(_ product, context: [String: Any])
   接收 ProductCard（即成功响应 data），返回 buttonKeyRaw: String、
   presale/ rebateUnknown/ degraded/ rebateGone/ publicMode: Bool。
   privacy 使用 consented/basic；不将 publicMode 当发布阶段。
 - expect 缺字段表示不判定；显式 null 表示必须无值。
   degraded、rebateGone 尚无充分判据，见向量 gaps，不默认为 false。
 - 从 #filePath 向上定位 contract.lock；不复制内嵌向量、不访问网络。
 - 实现接入时为 Features 包登记 SearchTests testTarget；
   本文件不修改包清单，也不提供被测 API 的假实现。
 */
import Foundation
import XCTest
@testable import Search

private typealias JSONObject = [String: Any]

final class SearchProductVectorTests: XCTestCase {
    private let groups = [
        "searchRequest", "tabs", "paging",
        "resultState", "staleResponse", "detail"
    ]

    func testManifest() throws {
        _ = try vectors()
    }

    func testSearchRequestVectors() throws {
        try each("searchRequest") { row, label in
            let input: JSONObject = try self.field(row, "input", label)
            let expected: JSONObject = try self.field(row, "expect", label)
            let actual = SearchQuery.build(input)
            let valid: Bool = try self.field(expected, "valid", label)

            XCTAssertEqual(actual.valid, valid, "\(label).valid")
            if valid {
                let query: JSONObject = try self.field(expected, "query", label)
                var actualQuery = actual.query
                if actualQuery["sort"] == nil {
                    actualQuery["sort"] = "relevance"
                }
                XCTAssertEqual(
                    try self.canonical(actualQuery),
                    try self.canonical(query),
                    "\(label).query"
                )
            }
            try self.assertText(expected, "reason", actual.reasonRaw, label)
        }
    }

    func testTabVectors() throws {
        try each("tabs") { row, label in
            let input: JSONObject = try self.field(row, "searchStatus", label)
            let expected: JSONObject = try self.field(row, "expect", label)
            let tabs: [String] = try self.field(expected, "tabs", label)
            let actual = SearchTabs.resolve(input)

            XCTAssertEqual(actual.count, Set(actual).count, "\(label).duplicates")
            XCTAssertEqual(actual.sorted(), tabs.sorted(), "\(label).members")
        }
    }

    func testPagingVectors() throws {
        try each("paging") { row, label in
            let pages: [JSONObject] = try self.field(row, "pages", label)
            let expected: JSONObject = try self.field(row, "expect", label)
            XCTAssertFalse(pages.isEmpty, label)
            var pager = SearchPager()
            var inputKeys: [String] = []

            for page in pages {
                pager.append(page)
                let data: JSONObject = try self.field(page, "data", label)
                let items: [JSONObject] = try self.field(data, "items", label)
                for item in items {
                    inputKeys.append(try self.field(item, "product_key", label))
                }
            }

            let count: Int = try self.field(expected, "items", label)
            let end: Bool = try self.field(expected, "endReached", label)
            let state: String = try self.field(expected, "stateRaw", label)
            XCTAssertEqual(pager.items.count, count, "\(label).items")
            XCTAssertEqual(pager.endReached, end, "\(label).endReached")
            XCTAssertEqual(pager.stateRaw, state, "\(label).stateRaw")

            // 本组没有重复商品；只比较输入顺序，不实现排序或去重算法。
            let actualKeys: [String] = try pager.items.map {
                try self.field($0, "product_key", label)
            }
            XCTAssertEqual(actualKeys, inputKeys, "\(label).itemOrder")
        }
    }

    func testResultStateVectors() throws {
        try each("resultState") { row, label in
            let hasResponse = row["response"] != nil
            let hasError = row["error"] != nil
            XCTAssertNotEqual(hasResponse, hasError, "\(label).oneEnvelope")
            let key = hasResponse ? "response" : "error"
            let envelope: JSONObject = try self.field(row, key, label)
            let expected: JSONObject = try self.field(row, "expect", label)
            let actual = SearchResultState.map(envelope)
            let state: String = try self.field(expected, "stateRaw", label)

            XCTAssertEqual(actual.stateRaw, state, "\(label).stateRaw")
            try self.assertText(expected, "textKey", actual.textKey, label)
        }
    }

    func testStaleResponseVectors() throws {
        try each("staleResponse") { row, label in
            let steps: [JSONObject] = try self.field(row, "steps", label)
            let expected: JSONObject = try self.field(row, "expect", label)
            var session = SearchSession()
            var tokens: [Int: Int64] = [:]
            var issued = Set<Int64>()

            for (index, step) in steps.enumerated() {
                let stepLabel = "\(label).steps[\(index)]"
                let op: String = try self.field(step, "op", stepLabel)
                switch op {
                case "search", "changeTab", "changeSort":
                    let symbol: Int = try self.field(step, "seq", stepLabel)
                    XCTAssertNil(tokens[symbol], "\(stepLabel).duplicateSymbol")
                    let token = session.begin(kind: op)
                    XCTAssertTrue(
                        issued.insert(token).inserted,
                        "\(stepLabel).tokenReusedAcrossRequestsOrLeave"
                    )
                    tokens[symbol] = token
                case "respond":
                    let symbol: Int = try self.field(step, "seq", stepLabel)
                    let token = try XCTUnwrap(
                        tokens[symbol], "\(stepLabel).unknownSeq"
                    )
                    session.accept(token)
                case "leave":
                    session.leave()
                default:
                    XCTFail("\(stepLabel): 未知操作 \(op)")
                    throw VectorError.invalid(stepLabel)
                }
            }

            let shown = try XCTUnwrap(expected["shown"], "\(label).shown")
            if shown is NSNull {
                XCTAssertNil(session.shownSeq, "\(label).shownSeq")
            } else {
                let symbol: Int = try self.field(expected, "shown", label)
                let token = try XCTUnwrap(tokens[symbol], "\(label).unknownShown")
                XCTAssertEqual(session.shownSeq, token, "\(label).shownSeq")
            }
        }
    }

    func testDetailVectors() throws {
        try each("detail") { row, label in
            let product: JSONObject = try self.field(row, "product", label)
            let context: JSONObject = try self.field(row, "context", label)
            let expected: JSONObject = try self.field(row, "expect", label)
            let actual = ProductDetailState.map(product, context: context)

            try self.assertText(expected, "buttonKeyRaw", actual.buttonKeyRaw, label)
            try self.assertFlag(expected, "presale", actual.presale, label)
            try self.assertFlag(expected, "rebateUnknown", actual.rebateUnknown, label)
            try self.assertFlag(expected, "degraded", actual.degraded, label)
            try self.assertFlag(expected, "rebateGone", actual.rebateGone, label)
            try self.assertFlag(expected, "publicMode", actual.publicMode, label)
        }
    }

    private func vectors() throws -> JSONObject {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("contract.lock").path
        ) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw VectorError.invalid("从 #filePath 向上找不到 contract.lock")
            }
            directory = parent
        }

        let url = directory.appendingPathComponent("specs/search-product-vectors.json")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? JSONObject
        )
        let version: Int = try field(root, "version", url.path)
        let sources: [String] = try field(root, "sources", url.path)
        let gaps: [String] = try field(root, "gaps", url.path)
        XCTAssertEqual(version, 1)
        XCTAssertFalse(sources.isEmpty)
        XCTAssertFalse(gaps.isEmpty)

        for group in groups {
            let rows: [JSONObject] = try field(root, group, url.path)
            XCTAssertFalse(rows.isEmpty, "\(group) 不能为空")
            var names = Set<String>()
            for row in rows {
                let name: String = try field(row, "name", group)
                XCTAssertFalse(name.isEmpty, group)
                XCTAssertTrue(names.insert(name).inserted, "\(group).\(name) 重复")
            }
        }
        return root
    }

    private func each(
        _ group: String,
        check: (JSONObject, String) throws -> Void
    ) throws {
        let rows: [JSONObject] = try field(try vectors(), group, group)
        for row in rows {
            let name: String = try field(row, "name", group)
            let label = "\(group).\(name)"
            do {
                try check(row, label)
            } catch {
                XCTFail("\(label): \(error)")
            }
        }
    }

    private func field<T>(
        _ object: JSONObject,
        _ key: String,
        _ label: String
    ) throws -> T {
        try XCTUnwrap(object[key] as? T, "\(label).\(key) 缺失或类型错误")
    }

    private func canonical(_ object: JSONObject) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func assertText(
        _ expected: JSONObject,
        _ key: String,
        _ actual: String?,
        _ label: String
    ) throws {
        guard let value = expected[key] else { return }
        if value is NSNull {
            XCTAssertNil(actual, "\(label).\(key)")
        } else {
            let text: String = try field(expected, key, label)
            XCTAssertEqual(actual, text, "\(label).\(key)")
        }
    }

    private func assertFlag(
        _ expected: JSONObject,
        _ key: String,
        _ actual: Bool,
        _ label: String
    ) throws {
        guard expected[key] != nil else { return }
        let flag: Bool = try field(expected, key, label)
        XCTAssertEqual(actual, flag, "\(label).\(key)")
    }

    private enum VectorError: Error {
        case invalid(String)
    }
}
