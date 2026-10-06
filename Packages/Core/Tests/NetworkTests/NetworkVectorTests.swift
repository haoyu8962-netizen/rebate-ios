// 实现前接线约定：
// - NetworkTests 依赖 Network 与 Generated；@testable import Network。
// - Generated 提供 ApiOperation、ApiOperations.byId(_:) -> ApiOperation?；缺项必须失败。
// - NetworkRequestState 的参数见调用；privacy=full/basic，sessionScope=full/deletion_only。
// - ErrorActionState.update=supported/below/unknown；ErrorActionInput.data 为 [String: Any]。
// - decide(state:operation:)、map(_:) 为纯函数；forOperation(_:) 返回策略。
//   超时/退避/禁用时长为 Int64 毫秒；headerNames 为 [String]。
// - RefreshRequest(id:operation:key:body:) 的 body 是原始字符串。
//   RefreshCoordinator(refresh:replay:clearSession:clock:)：
//   refresh: (@escaping (String?) -> Void) -> Void，nil 表示失败，非 nil 为新 access token；
//   replay: (RefreshRequest, String) -> Void；clearSession: () -> Void；clock: () -> Int64。
//   run(requests:forceUpdate:) 非阻塞接纳已收到 10002 的请求；回调串行交付。
//   可查询 refreshCalls、replayed、effectRaw。测试把多个 run 放在同一未完成刷新窗口，
//   验证跨批次单飞；不等待真实时间、不发 HTTP，也不以测试代码实现重试。
// - PendingKeyStore(backend:clock:)；MemoryPendingKeyBackend.read(account:key:)
//   返回可选记录，至少含 key、operationId、body、account。
//   beforeSend(operationId:key:body:account:) -> Bool 表示允许发送；
//   confirm(key:) / abandon(key:) -> Bool 只开始相应用户操作，不能直接删除记录。
//   onResponse(key:kind:) 接受下文 raw kind；abandoned 表示作废结果已被解包确认。
//   coldStart(account:) 恢复当前账号、将遗留 in_flight 变为 unknown，不发送请求；
//   state(key:).stateRaw 为 none/in_flight/unknown/done，done 不要求持久化墓碑。
// - pending 的 body 是仅供存储比较的测试字节，不是伪造的 HTTP 业务报文。
// - expect 可选字段缺省时不限定；显式 null 必须为空。
// - 这些测试不替代 URLProtocol 的 ApiClient 接线测试或 request-sign 向量测试。
//   只读产出，尚未在实现和测试 target 接线后编译执行。

import Foundation
import XCTest
import Generated
@testable import Network

private typealias Object = [String: Any]

private final class VectorClock {
    var nowMillis: Int64 = 0
}

private final class FakeRefresh {
    private(set) var calls = 0
    private var completions: [(String?) -> Void] = []

    func start(_ completion: @escaping (String?) -> Void) {
        calls += 1
        completions.append(completion)
    }

    func finish(_ token: String?) {
        let waiting = completions
        completions.removeAll()
        for completion in waiting {
            completion(token)
        }
    }
}

final class NetworkVectorTests: XCTestCase {
    private let consentTypes = [
        "privacy", "agreement", "ai_third_party",
        "id_verification", "personalization", "labor_agreement"
    ]

    func testHeaders() throws {
        try each("headers") { row, label in
            let state: Object = try value(row, "state")
            let expected: Object = try value(row, "expect")
            let actual = RequestHeaderPolicy.decide(
                state: NetworkRequestState(
                    privacy: try value(state, "privacy"),
                    sessionScope: try value(state, "sessionScope"),
                    hasAccessToken: try value(state, "hasAccessToken"),
                    deviceId: state["deviceId"] as? String,
                    environmentSettled: try value(state, "environmentSettled"),
                    credentialsReadable: try value(state, "credentialsReadable")
                ),
                operation: try operation(row)
            )
            let send: Bool = try value(expected, "send")
            XCTAssertEqual(actual.send, send, label)
            if let reason = expected["localRejectReason"] as? String {
                XCTAssertEqual(actual.localRejectReason, reason, label)
            }
            let names = Set(actual.headerNames.map { $0.lowercased() })
            let included: [String] = try value(expected, "include")
            let excluded: [String] = try value(expected, "exclude")
            for name in included {
                XCTAssertTrue(names.contains(name.lowercased()), "\(label): missing \(name)")
            }
            for name in excluded {
                XCTAssertFalse(names.contains(name.lowercased()), "\(label): leaked \(name)")
            }
        }
    }

    func testRetryPolicies() throws {
        try each("retry") { row, label in
            let failure: String = try value(row, "failure")
            XCTAssertTrue(["timeout", "disconnect", "http5xx"].contains(failure), label)
            let expected: Object = try value(row, "expect")
            let actual = RetryPolicy.forOperation(try operation(row))
            let retries: Int = try value(expected, "autoRetries")
            XCTAssertEqual(actual.autoRetries, retries, label)
            XCTAssertEqual(actual.timeoutMillis, try millis(expected, "timeoutMillis"), label)
            if expected["backoffMillis"] != nil {
                XCTAssertEqual(actual.backoffMillis, try millis(expected, "backoffMillis"), label)
            }
        }
    }

    func testErrorActions() throws {
        let manifest = try vectors()
        let kinds: Object = try value(manifest, "effectKinds")
        try each("errorAction") { row, baseLabel in
            let expected: Object = try value(row, "expect")
            let kind: String = try value(expected, "effectKind")
            XCTAssertNotNil(kinds[kind], "\(baseLabel): undefined effect")
            let code: Int = try value(row, "code")
            let variants = code == 10004 && kind == "guide_only" ? consentTypes : [""]
            for consent in variants {
                var data: Object = try value(row, "data")
                if !consent.isEmpty {
                    data["consent_type"] = consent
                }
                let label = "\(baseLabel) \(consent)"
                let state: Object = try value(row, "state")
                let effect = ErrorActionMapper.map(
                    ErrorActionInput(
                        code: code,
                        data: data,
                        operation: try operation(row),
                        headers: try value(row, "headers"),
                        isReplay: try value(row, "isReplay"),
                        state: ErrorActionState(
                            update: try value(state, "update"),
                            sessionScope: try value(state, "sessionScope"),
                            appVersion: try value(state, "appVersion")
                        )
                    )
                )
                XCTAssertEqual(effect.effectKindRaw, kind, label)
                let replay: String = try value(expected, "replay")
                let pending: Bool = try value(expected, "registerPending")
                XCTAssertEqual(effect.replayRaw, replay, label)
                XCTAssertEqual(effect.registerPending, pending, label)
                if expected["route"] != nil {
                    XCTAssertEqual(effect.route, expected["route"] as? String, label)
                }
                if expected["textKey"] != nil {
                    XCTAssertEqual(effect.textKey, expected["textKey"] as? String, label)
                }
                if expected["disableMillis"] != nil {
                    XCTAssertEqual(effect.disableMillis, try millis(expected, "disableMillis"), label)
                }
                if let trace = expected["trace6"] as? Bool {
                    XCTAssertEqual(effect.includeTrace6, trace, label)
                }
            }
        }
    }

    func testRefreshCoordinator() throws {
        try each("refresh") { row, label in
            let expected: Object = try value(row, "expect")
            let count: Int = try value(row, "concurrent")
            let force: Bool = try value(row, "forceUpdate")
            let result: String = try value(row, "refreshResult")
            let fake = FakeRefresh()
            let clock = VectorClock()
            var replayed: [RefreshRequest] = []
            var replayTokens: [String] = []
            var clearCalls = 0
            let coordinator = RefreshCoordinator(
                refresh: { completion in fake.start(completion) },
                replay: { request, token in
                    replayed.append(request)
                    replayTokens.append(token)
                },
                clearSession: { clearCalls += 1 },
                clock: { clock.nowMillis }
            )
            let operation = try XCTUnwrap(ApiOperations.byId("openLink"))
            let requests = (0..<count).map { index in
                RefreshRequest(
                    id: "request-\(index)",
                    operation: operation,
                    key: "key-\(index)",
                    body: "{\"fixture\":\(index)}"
                )
            }
            // 所有请求都在刷新尚未完成的窗口内到达，不用真实 sleep 制造竞争。
            for request in requests {
                coordinator.run(requests: [request], forceUpdate: force)
            }
            let refreshCalls: Int = try value(expected, "refreshCalls")
            XCTAssertEqual(fake.calls, refreshCalls, "\(label): actual refresh invocations")
            XCTAssertEqual(coordinator.refreshCalls, refreshCalls, label)
            XCTAssertTrue(replayed.isEmpty, "\(label): replayed before refresh completed")
            XCTAssertEqual(clearCalls, 0, label)

            clock.nowMillis = 1
            fake.finish(result == "ok" ? "fresh-access-token" : nil)

            let replayCount: Int = try value(expected, "replayed")
            let effect: String = try value(expected, "effect")
            XCTAssertEqual(fake.calls, refreshCalls, label)
            XCTAssertEqual(coordinator.refreshCalls, refreshCalls, label)
            XCTAssertEqual(coordinator.replayed, replayCount, label)
            XCTAssertEqual(coordinator.effectRaw, effect, label)
            XCTAssertEqual(replayed.count, replayCount, label)
            XCTAssertEqual(clearCalls, result == "fail" ? 1 : 0, label)
            if result == "ok" {
                XCTAssertEqual(replayed.map(\.id).sorted(), requests.map(\.id).sorted(), label)
                for (index, actual) in replayed.enumerated() {
                    let original = try XCTUnwrap(requests.first { $0.id == actual.id }, label)
                    XCTAssertEqual(actual.key, original.key, label)
                    XCTAssertEqual(actual.body, original.body, label)
                    XCTAssertEqual(replayTokens[index], "fresh-access-token", label)
                }
            }
        }
    }

    func testPendingKeys() throws {
        try each("pending") { row, label in
            let steps: [Object] = try value(row, "steps")
            let authKinds = steps.contains { $0["response"] as? String == "envelope_10001" }
                ? ["envelope_10001", "envelope_10004", "envelope_10005"] : ["envelope_10001"]
            let parameterKinds = steps.contains { $0["response"] as? String == "envelope_2xxxx" }
                ? ["envelope_20001", "envelope_20901", "envelope_20003"] : ["envelope_20001"]
            for authKind in authKinds {
                for parameterKind in parameterKinds {
                    try checkPending(row, "\(label) \(authKind)/\(parameterKind)", authKind, parameterKind)
                }
            }
        }
    }

    func testOtherNonterminalResponsesKeepUnknownKey() throws {
        // BR-ID-10 明列的非终结响应；既定 JSON response 枚举未给这些独立成员。
        for kind in ["envelope_40901", "envelope_42901", "envelope_10006", "envelope_50001"] {
            let backend = MemoryPendingKeyBackend()
            let store = PendingKeyStore(backend: backend, clock: { 0 })
            store.coldStart(account: "account-A")
            XCTAssertTrue(store.beforeSend(
                operationId: "createWithdrawal", key: "key", body: "original", account: "account-A"
            ))
            store.onResponse(key: "key", kind: "no_envelope")
            XCTAssertTrue(store.confirm(key: "key"))
            store.onResponse(key: "key", kind: kind)
            XCTAssertEqual(store.state(key: "key").stateRaw, "unknown", kind)
            XCTAssertNotNil(backend.read(account: "account-A", key: "key"), kind)
            XCTAssertFalse(store.beforeSend(
                operationId: "createWithdrawal", key: "new-key", body: "changed", account: "account-A"
            ), kind)
        }
    }

    private func checkPending(
        _ row: Object, _ label: String, _ authKind: String, _ parameterKind: String
    ) throws {
        let operationId: String = try value(row, "operationId")
        _ = try operation(row)
        let backend = MemoryPendingKeyBackend()
        let clock = VectorClock()
        var store = PendingKeyStore(backend: backend, clock: { clock.nowMillis })
        let key = "original-key"
        let body = "{\"fixture\":\"original\"}\n"
        var account = "account-A"
        var abandoning = false
        store.coldStart(account: account)
        let steps: [Object] = try value(row, "steps")
        XCTAssertFalse(steps.isEmpty, label)

        for (index, step) in steps.enumerated() {
            let op: String = try value(step, "op")
            let expected: Object = try value(step, "expect")
            let stepLabel = "\(label) step[\(index)] \(op)"
            switch op {
            case "send":
                XCTAssertTrue(store.beforeSend(
                    operationId: operationId, key: key, body: body, account: account
                ), stepLabel)
            case "confirm", "abandon":
                let allowed = account == "account-A" && store.state(key: key).stateRaw == "unknown"
                let accepted = op == "confirm" ? store.confirm(key: key) : store.abandon(key: key)
                XCTAssertEqual(accepted, allowed, stepLabel)
                if accepted { abandoning = op == "abandon" }
            case "result":
                var kind: String = try value(step, "response")
                if kind == "envelope_10001" { kind = authKind }
                if kind == "envelope_2xxxx" { kind = parameterKind }
                if abandoning && kind == "envelope_success" { kind = "abandoned" }
                store.onResponse(key: key, kind: kind)
                abandoning = false
            case "loginOther":
                account = "account-B"
                store.coldStart(account: account)
            case "coldStart":
                clock.nowMillis += 31 * 24 * 60 * 60 * 1000
                account = "account-A"
                store = PendingKeyStore(backend: backend, clock: { clock.nowMillis })
                store.coldStart(account: account)
                abandoning = false
            default:
                XCTFail("\(stepLabel): unknown op")
                throw NSError(domain: "NetworkVectors", code: 1)
            }
            let state: String = try value(expected, "state")
            let kept: Bool = try value(expected, "keyKept")
            XCTAssertEqual(store.state(key: key).stateRaw, state, stepLabel)
            let record = backend.read(account: "account-A", key: key)
            XCTAssertEqual(record != nil, kept, "\(stepLabel): actual backend retention")
            if let record {
                XCTAssertEqual(record.key, key, stepLabel)
                XCTAssertEqual(record.operationId, operationId, stepLabel)
                XCTAssertEqual(record.body, body, stepLabel)
                XCTAssertEqual(record.account, "account-A", stepLabel)
            }
            if state == "unknown" {
                XCTAssertFalse(store.beforeSend(
                    operationId: operationId, key: "replacement-key",
                    body: "{\"fixture\":\"changed\"}", account: account
                ), "\(stepLabel): unknown must reject a new submission")
                XCTAssertNil(backend.read(account: account, key: "replacement-key"), stepLabel)
                XCTAssertEqual(backend.read(account: "account-A", key: key)?.body, body, stepLabel)
                XCTAssertEqual(store.state(key: key).stateRaw, "unknown", stepLabel)
            }
            if state == "in_flight" {
                XCTAssertFalse(store.confirm(key: key), "\(stepLabel): duplicate confirm")
                XCTAssertFalse(store.abandon(key: key), "\(stepLabel): parallel abandon")
                XCTAssertEqual(store.state(key: key).stateRaw, "in_flight", stepLabel)
            }
        }
    }

    private func operation(_ row: Object) throws -> ApiOperation {
        let id: String = try value(row, "operationId")
        return try XCTUnwrap(ApiOperations.byId(id), "Missing generated operation: \(id)")
    }

    private func each(_ group: String, _ check: (Object, String) throws -> Void) throws {
        let rows: [Object] = try value(try vectors(), group)
        XCTAssertFalse(rows.isEmpty, "\(group): empty vectors")
        var names = Set<String>()
        for row in rows {
            let name: String = try value(row, "name")
            let note: String = try value(row, "note")
            XCTAssertFalse(name.isEmpty)
            XCTAssertFalse(note.isEmpty)
            XCTAssertTrue(names.insert(name).inserted, "\(group): duplicate \(name)")
            try check(row, "\(group)/\(name): \(note)")
        }
    }

    private func vectors() throws -> Object {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw NSError(
                    domain: "NetworkVectors", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot find contract.lock above #filePath"]
                )
            }
            directory = parent
        }
        let file = directory.appendingPathComponent("specs/network-vectors.json")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? Object
        )
        let version: Int = try value(root, "version")
        let sources: [String] = try value(root, "sources")
        XCTAssertEqual(version, 1)
        XCTAssertFalse(sources.isEmpty)
        return root
    }

    private func value<T>(_ object: Object, _ key: String) throws -> T {
        try XCTUnwrap(object[key] as? T, "Missing or invalid vector field: \(key)")
    }

    private func millis(_ object: Object, _ key: String) throws -> Int64 {
        let number: NSNumber = try value(object, key)
        return number.int64Value
    }
}
