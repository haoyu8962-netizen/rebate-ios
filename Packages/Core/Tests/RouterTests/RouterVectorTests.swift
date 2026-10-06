import Foundation
import XCTest
@testable import Router

// 测试接线约定（不改变 brief.md §2 的方法名称）：
// - RouteRequest.params / PendingAction.params 使用 [String: Any]。
// - privacy/update/session/source 接受任务书中的原始字符串。
// - DeepLinkParser.parse(url:config:) 的 config 可用
//   .init(schemes: [String], hosts: [String]) 构造。
// - PendingActionStore(backend:clock:)；clock 是 () -> Int64，now 为毫秒。
// - 实现提供 MemoryPendingBackend：单记录内存存储后端；
//   read() -> String? 暴露原始存储记录，删除后为 nil。
//   此处不依赖其序列化格式，只据此验证过期/clear 确实删除。
// - PendingAction 至少暴露 action 和 params；不限定内部时间字段命名。
// - 每个 pending 步骤新建 Store、复用后端，检测写入/续时/删除的持久化。
// 本文件是实现前的测试；不以生产实现计算任何期望值。

private typealias JSONObject = [String: Any]

private final class VectorClock {
    var nowMillis: Int64 = 0
}

final class RouterVectorTests: XCTestCase {
    func testGuardVectors() throws {
        let root = try vectors()
        let reasons: JSONObject = try field(root, "reasons", "manifest")

        try each(root, group: "guard") { row, label in
            let input: JSONObject = try field(row, "request", label)
            let state: JSONObject = try field(row, "state", label)
            let expected: JSONObject = try field(row, "expect", label)

            let request = RouteRequest(
                route: try field(input, "route", label),
                params: try field(input, "params", label),
                source: try field(input, "source", label)
            )
            let guardState = GuardState(
                privacy: try field(state, "privacy", label),
                update: try field(state, "update", label),
                session: try field(state, "session", label),
                environmentSettled: try field(state, "environmentSettled", label),
                appVersion: try field(state, "appVersion", label),
                isDebugBuild: try field(state, "isDebugBuild", label),
                fromForceUpdatePage: try field(state, "fromForceUpdatePage", label)
            )
            let actual: GuardDecision = EntryGuard.decide(
                request: request,
                state: guardState
            )
            let kind: String = try field(expected, "kind", label)
            let reason: String = try field(expected, "reason", label)
            let reasonDescription = reasons[reason] as? String

            XCTAssertFalse(reasonDescription?.isEmpty ?? true, "\(label): reason 未定义")
            XCTAssertEqual(actual.kindRaw, kind, "\(label): kindRaw")
            XCTAssertEqual(
                actual.route,
                try optionalString(expected, "route", label),
                "\(label): route"
            )
            XCTAssertEqual(actual.reason, reason, "\(label): reason")
        }
    }

    func testDeepLinkVectors() throws {
        try each(try vectors(), group: "deeplink") { row, label in
            let config: JSONObject = try field(row, "config", label)
            let url: String = try field(row, "url", label)
            let schemes: [String] = try field(config, "schemes", label)
            let hosts: [String] = try field(config, "hosts", label)
            let expectedValue = try XCTUnwrap(row["expect"], "\(label): expect 缺失")

            let actual = DeepLinkParser.parse(
                url: url,
                config: .init(schemes: schemes, hosts: hosts)
            )

            if expectedValue is NSNull {
                XCTAssertNil(actual, "\(label): 应拒绝深链")
                return
            }

            let expected = try XCTUnwrap(
                expectedValue as? JSONObject,
                "\(label): expect 应为对象"
            )
            let request = try XCTUnwrap(actual, "\(label): 应解析成功")
            let route: String = try field(expected, "route", label)
            let source: String = try field(expected, "source", label)
            let params: JSONObject = try field(expected, "params", label)

            XCTAssertEqual(request.route, route, "\(label): route")
            XCTAssertEqual(request.source, source, "\(label): source")
            XCTAssertEqual(
                try canonicalJSON(request.params),
                try canonicalJSON(params),
                "\(label): params"
            )
        }
    }

    func testPendingVectors() throws {
        try each(try vectors(), group: "pending") { row, label in
            let backend = MemoryPendingBackend()
            let clock = VectorClock()
            let steps: [JSONObject] = try field(row, "steps", label)
            XCTAssertFalse(steps.isEmpty, "\(label): steps 不能为空")

            for (index, step) in steps.enumerated() {
                let stepLabel = "\(label): step[\(index)]"
                let op: String = try field(step, "op", stepLabel)
                let atMillis: NSNumber = try field(step, "atMillis", stepLabel)
                clock.nowMillis = atMillis.int64Value

                let store = PendingActionStore(
                    backend: backend,
                    clock: { clock.nowMillis }
                )

                switch op {
                case "save":
                    let action: String = try field(step, "action", stepLabel)
                    let params: JSONObject = try field(step, "params", stepLabel)
                    let expected: Bool = try field(step, "expect", stepLabel)
                    let actual = store.save(
                        action: action,
                        params: params,
                        now: clock.nowMillis
                    )
                    XCTAssertEqual(actual, expected, "\(stepLabel): save")
                case "load":
                    let expectedValue = try XCTUnwrap(
                        step["expect"],
                        "\(stepLabel): expect 缺失"
                    )
                    let actual = store.load(now: clock.nowMillis)

                    if expectedValue is NSNull {
                        XCTAssertNil(actual, "\(stepLabel): load")
                        XCTAssertNil(
                            backend.read(),
                            "\(stepLabel): 返回 nil 后后端不得残留记录"
                        )
                    } else {
                        let expected = try XCTUnwrap(
                            expectedValue as? JSONObject,
                            "\(stepLabel): expect 应为对象"
                        )
                        let pending = try XCTUnwrap(actual, "\(stepLabel): load")
                        let action: String = try field(expected, "action", stepLabel)
                        let params: JSONObject = try field(expected, "params", stepLabel)
                        XCTAssertEqual(pending.action, action, "\(stepLabel): action")
                        XCTAssertEqual(
                            try canonicalJSON(pending.params),
                            try canonicalJSON(params),
                            "\(stepLabel): params"
                        )
                    }
                case "markStepDone":
                    // 返回值未由任务书规定；效果由后续 load 及边界时刻断言。
                    store.markStepDone(now: clock.nowMillis)
                case "clear":
                    store.clear()
                    XCTAssertNil(backend.read(), "\(stepLabel): clear 必须删除后端记录")
                default:
                    XCTFail("\(stepLabel): 未知 op=\(op)")
                }
            }
        }
    }

    private func vectors() throws -> JSONObject {
        let url = try repositoryRoot()
            .appendingPathComponent("specs/router-vectors.json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? JSONObject,
            "\(url.path): 根必须为对象"
        )
        let version: Int = try field(root, "version", url.path)
        let sources: [String] = try field(root, "sources", url.path)
        let gaps: [String] = try field(root, "gaps", url.path)
        XCTAssertEqual(version, 1, "\(url.path): version")
        XCTAssertFalse(sources.isEmpty, "\(url.path): sources")
        XCTAssertFalse(gaps.isEmpty, "\(url.path): gaps")

        for group in ["guard", "deeplink", "pending"] {
            let rows: [JSONObject] = try field(root, group, url.path)
            XCTAssertFalse(rows.isEmpty, "\(url.path): \(group) 不能为空")
        }
        return root
    }

    private func each(
        _ root: JSONObject,
        group: String,
        check: (JSONObject, String) throws -> Void
    ) throws {
        let rows: [JSONObject] = try field(root, group, group)
        var names = Set<String>()

        for (index, row) in rows.enumerated() {
            let name: String = try field(row, "name", "\(group)[\(index)]")
            let note: String = try field(row, "note", "\(group)[\(index)] \(name)")
            let label = "\(group)[\(index)] \(name): \(note)"
            XCTAssertFalse(name.isEmpty, label)
            XCTAssertFalse(note.isEmpty, label)
            XCTAssertTrue(names.insert(name).inserted, "\(label): 重复 name")
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
        try XCTUnwrap(object[key] as? T, "\(label): \(key) 缺失或类型错误")
    }

    private func optionalString(
        _ object: JSONObject,
        _ key: String,
        _ label: String
    ) throws -> String? {
        let value = try XCTUnwrap(object[key], "\(label): \(key) 缺失")
        if value is NSNull {
            return nil
        }
        return try XCTUnwrap(value as? String, "\(label): \(key) 应为 string/null")
    }

    private func canonicalJSON(_ object: JSONObject) throws -> String {
        // JSON 序列化保持 boolean/number/string 类型，不用 NSDictionary 的宽松数字比较。
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .standardizedFileURL

        while true {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("contract.lock").path
            ) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                throw NSError(
                    domain: "RouterVectorTests",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "从 \(#filePath) 向上找不到含 contract.lock 的仓库根目录",
                    ]
                )
            }
            directory = parent
        }
    }
}
