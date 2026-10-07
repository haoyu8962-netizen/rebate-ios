/*
 * 实现前测试；只读会话未写文件、未编译或运行。
 *
 * 接线约定：
 * - 新增生产 target ClientCore、测试 target ClientCoreTests，后者依赖前者。
 *   本文件只 import ClientCore，不使用系统框架同名模块承载这些 API。
 * - DeviceIdPolicy.evaluate(platform:rawId:privacy:) 返回 register、reasonRaw。
 *   rawId 可空；reasonRaw 原文未定义，因此不比较原因字符串。
 * - ConfigResolver 的 current/lkg/bundled 接收配置 data 的 JSON 字符串。
 *   resolve(..., key:) 返回选中值的 JSON 字符串；searchStatus(..., platformKey:)
 *   返回状态字符串；linkPatterns(...) 返回完整 link_patterns 的 JSON 字符串。
 *   缺当前/LKG 用 nil；这些是配置片段测试，不是 HTTP schema 校验测试。
 * - ConfigStore(readFile:writeFile:fetcher:clock:bundled:)：
 *   readFile () -> String?，writeFile (String?) -> Void，文件内容对测试不透明；
 *   fetcher (String?, @escaping (ConfigReply) -> Void) -> Void；
 *   第一个参数是实际待发送的 If-None-Match。clock 返回 Int64 毫秒。
 *   ConfigReply(kindRaw:bodyJson:etag:) 的 kindRaw 为 ok/not_modified/failure。
 *   onColdStart() 同步读取文件并启动后台请求；onForeground() 发起请求；
 *   snapshotJson、sourceRaw 提供当前 data 与 current/lkg/bundled 来源。
 *   注入回调在同一串行执行上下文完成，不要求 @Sendable，不使用真实网络。
 * - TrackerQueue(readFile:writeFile:sink:privacy:userId:deviceId:platform:
 *   appVersion:sessionId:clock:canUpload:)；sink ([String]) -> Bool，
 *   接收真实待上传事件 JSON，true 表示全部成功；userId () -> String?。
 *   track(event:) -> Bool 表示是否接受，flush()、onPrivacyChanged(state:)、
 *   queueSize；序列化存储不透明。ClientEvents.appLaunch(page:) 必须重导出
 *   events.yaml 生成的构造器，不能为通过测试手写另一个事件实现。
 * - PermissionRequester(readFile:writeFile:clock:platform:status:
 *   showRationale:systemRequest:showSettingsGuide:)：
 *   status (String) -> String，未申请返回 not_asked；
 *   showRationale (String, String?) async -> Void，分别为用途键、继续按钮键；
 *   完成表示说明已显示，iOS 用户已点继续。
 *   systemRequest (String) async -> String；
 *   showSettingsGuide (String?, String) -> Void，分别为提示键、去设置按钮键。
 *   request(permission:) async 返回包含 resultRaw 的结果。
 *   systemResult 步骤仅预置下一次系统申请的返回值，不冒充申请已经发生；
 *   advance 后重建 Requester，复用文件、时钟和系统状态，验证持久化。
 * - 上述补充签名是测试接线约定，不是新增业务规则。适配层只能转型/转发，
 *   不得在适配层实现回落、节流、隐私判断或消费 expect。
 * - DeviceRegistry 另需验证真实标识来源、禁止读取/哈希/注册的副作用、
 *   安全存储与清理接线。哈希测试直接读
 *   contracts/snapshot/specs/device-hash.vectors.json（9cd1e6f），不复制预期值。
 *   完整哈希、清缓存、环境切换及计时批量上报集成测试由实现任务补齐。
 */

import Foundation
import XCTest
@testable import ClientCore

private typealias VectorObject = [String: Any]

private struct VectorError: Error {
    let message: String
}

private final class VectorFile {
    var value: String?

    func read() -> String? { value }
    func write(_ value: String?) { self.value = value }
}

private final class VectorClock {
    var now: Int64 = 1_000_000
}

private final class FetchProbe {
    var sent: [String?] = []
    var pending: ((ConfigReply) -> Void)?

    func fetch(_ etag: String?, _ completion: @escaping (ConfigReply) -> Void) {
        precondition(pending == nil, "测试只提供一个在途请求")
        sent.append(etag)
        pending = completion
    }

    func complete(_ reply: ConfigReply) throws {
        let completion = try XCTUnwrap(pending, "没有等待中的 fetch")
        pending = nil
        completion(reply)
    }
}

private final class TrackerProbe {
    var online = true
    var attempted: [String] = []
    var uploaded: [String] = []

    func send(_ events: [String]) -> Bool {
        attempted.append(contentsOf: events)
        if online {
            uploaded.append(contentsOf: events)
        }
        return online
    }
}

private final class TrackerInputs {
    var privacy: String
    var loggedIn: Bool
    var canUpload = true

    init(privacy: String, loggedIn: Bool) {
        self.privacy = privacy
        self.loggedIn = loggedIn
    }
}

private struct RationaleCall {
    let purpose: String
    let continueKey: String?
}

private struct SettingsCall {
    let message: String?
    let button: String
}

private final class PermissionProbe {
    var current: [String: String] = [:]
    var nextResult: String?
    var trace: [String] = []
    var rationales: [RationaleCall] = []
    var guides: [SettingsCall] = []

    func resetCalls() {
        trace.removeAll()
        rationales.removeAll()
        guides.removeAll()
    }

    func status(_ permission: String) -> String {
        trace.append("status")
        return current[permission] ?? "not_asked"
    }

    func rationale(_ purpose: String, _ continueKey: String?) async {
        trace.append("rationale")
        rationales.append(RationaleCall(purpose: purpose, continueKey: continueKey))
    }

    func systemRequest(_ permission: String) async -> String {
        trace.append("system")
        let result = nextResult ?? "unexpected_unconfigured_system_call"
        nextResult = nil
        current[permission] = result
        return result
    }

    func settings(_ message: String?, _ button: String) {
        trace.append("settings")
        guides.append(SettingsCall(message: message, button: button))
    }
}

final class ClientCoreVectorTests: XCTestCase {
    private let platform = "ios"
    private let deviceID = "0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a60"
    private let bundled =
        #"{"dict_version":"bundled","link_patterns":{"version":"bundled-patterns","rules":[]}}"#

    func testDeviceVectors() throws {
        for row in try rows("device") {
            let label = try text(row, "name")
            let expected = try object(row["expect"])
            let decision = DeviceIdPolicy.evaluate(
                platform: try text(row, "platform"),
                rawId: try optionalText(row, "rawId"),
                privacy: try text(row, "privacy")
            )
            XCTAssertEqual(decision.register, try flag(expected, "register"), label)
            // 原文未定义 reasonRaw，不锁死实现自行选择的原因命名。
        }
    }

    func testConfigResolverVectors() throws {
        for row in try rows("config") {
            let label = try text(row, "name")
            let expected = try object(row["expect"])
            let current = try document(row, "current")
            let lkg = try document(row, "lkg")
            let fallback = try XCTUnwrap(document(row, "bundled"))

            if let value = expected["value"] {
                let result = ConfigResolver.resolve(
                    current: current, lkg: lkg, bundled: fallback, key: "dict_version"
                )
                try assertJSON(result, equals: json(value), label)
            } else if let status = expected["searchStatus"] as? String {
                XCTAssertEqual(
                    ConfigResolver.searchStatus(
                        current: current,
                        lkg: lkg,
                        bundled: fallback,
                        platformKey: try text(row, "platformKey")
                    ),
                    status,
                    label
                )
            } else if let version = expected["linkPatternsVersion"] as? String {
                let result = try XCTUnwrap(
                    ConfigResolver.linkPatterns(
                        current: current, lkg: lkg, bundled: fallback
                    ),
                    label
                )
                let patterns = try object(parse(result))
                XCTAssertEqual(try text(patterns, "version"), version, label)
                XCTAssertNotNil(patterns["rules"] as? [Any], label)
            } else {
                throw VectorError(message: "\(label)：未知配置断言")
            }
        }
    }

    func testConfigFetchVectors() throws {
        for row in try rows("configFetch") {
            let label = try text(row, "name")
            let file = VectorFile()
            let clock = VectorClock()
            let fetch = FetchProbe()

            func makeStore() -> ConfigStore {
                ConfigStore(
                    readFile: file.read,
                    writeFile: file.write,
                    fetcher: fetch.fetch,
                    clock: { clock.now },
                    bundled: bundled
                )
            }

            var store = makeStore()
            var lastSuccess: String?
            var successCount = 0

            for step in try objectRows(row, "steps") {
                let op = try text(step, "op")
                switch op {
                case "coldStart":
                    XCTAssertNil(fetch.pending, label)
                    store = makeStore()
                    let before = fetch.sent.count
                    store.onColdStart()
                    XCTAssertEqual(fetch.sent.count, before + 1, label)
                    XCTAssertNotNil(fetch.pending, label)
                    try assertJSON(store.snapshotJson, equals: lastSuccess ?? bundled, label)

                case "foreground":
                    let before = fetch.sent.count
                    store.onForeground()
                    XCTAssertEqual(fetch.sent.count, before + 1, label)
                    XCTAssertNotNil(fetch.pending, label)

                case "fetchOk":
                    successCount += 1
                    let body = """
                    {"dict_version":"network-\(successCount)",\
                    "link_patterns":{"version":"patterns-\(successCount)","rules":[]}}
                    """
                    try fetch.complete(
                        ConfigReply(
                            kindRaw: "ok",
                            bodyJson: body,
                            etag: try optionalText(step, "etag")
                        )
                    )
                    lastSuccess = body
                    XCTAssertNotNil(file.value, "\(label)：成功响应必须持久化")
                    try assertJSON(store.snapshotJson, equals: body, label)

                case "fetch304", "fetchFail":
                    let before = store.snapshotJson
                    try fetch.complete(
                        ConfigReply(
                            kindRaw: op == "fetch304" ? "not_modified" : "failure",
                            bodyJson: nil,
                            etag: try optionalText(step, "etag")
                        )
                    )
                    try assertJSON(store.snapshotJson, equals: before, label)

                default:
                    throw VectorError(message: "\(label)：未知 op \(op)")
                }
            }

            let expected = try object(row["expect"])
            XCTAssertEqual(store.sourceRaw, try text(expected, "source"), label)
            if expected.keys.contains("sentIfNoneMatch") {
                XCTAssertFalse(fetch.sent.isEmpty, label)
                XCTAssertEqual(
                    fetch.sent.last ?? nil,
                    try optionalText(expected, "sentIfNoneMatch"),
                    label
                )
            }
        }
    }

    func testTrackerVectors() throws {
        for row in try rows("tracker") {
            let label = try text(row, "name")
            let file = VectorFile()
            let clock = VectorClock()
            let sink = TrackerProbe()
            let inputs = TrackerInputs(
                privacy: try text(row, "privacy"),
                loggedIn: try flag(row, "loggedIn")
            )

            func makeQueue() -> TrackerQueue {
                TrackerQueue(
                    readFile: file.read,
                    writeFile: file.write,
                    sink: sink.send,
                    privacy: inputs.privacy,
                    userId: { inputs.loggedIn ? "user-test" : nil },
                    deviceId: deviceID,
                    platform: platform,
                    appVersion: "1.0.0",
                    sessionId: "session-test",
                    clock: { clock.now },
                    canUpload: { inputs.canUpload }
                )
            }

            var queue = makeQueue()
            var collected = 0

            for step in try objectRows(row, "steps") {
                let op = try text(step, "op")
                switch op {
                case "track":
                    for _ in 0..<(try integer(step, "count")) {
                        if queue.track(event: ClientEvents.appLaunch(page: "Home")) {
                            collected += 1
                        }
                        XCTAssertGreaterThanOrEqual(queue.queueSize, 0, label)
                        XCTAssertLessThanOrEqual(queue.queueSize, 500, label)
                    }
                case "flush":
                    queue.flush()
                case "privacy":
                    inputs.privacy = try text(step, "state")
                    queue.onPrivacyChanged(state: inputs.privacy)
                    if inputs.privacy != "consented" {
                        XCTAssertEqual(queue.queueSize, 0, "\(label)：撤回立即清队列")
                    }
                case "restart":
                    queue = makeQueue()
                case "sinkFail":
                    sink.online = false
                case "sinkOk":
                    sink.online = true
                case "login":
                    inputs.loggedIn = true
                case "uploadGate":
                    inputs.canUpload = try flag(step, "allowed")
                default:
                    throw VectorError(message: "\(label)：未知 op \(op)")
                }
            }

            let expected = try object(row["expect"])
            try assertCount(collected, key: "collected", expected, label)
            try assertCount(sink.uploaded.count, key: "uploaded", expected, label)
            try assertCount(queue.queueSize, key: "queueSize", expected, label)

            if try text(row, "privacy") != "consented",
               collected == 0 {
                XCTAssertTrue(sink.attempted.isEmpty, "\(label)：不得调用 sink")
            }
            if !inputs.canUpload {
                XCTAssertTrue(sink.attempted.isEmpty, "\(label)：未知版本只入队")
            }

            for packet in sink.attempted {
                try assertCommonFields(packet, label)
            }

            if let hasUserID = expected["hasUserId"] as? Bool {
                XCTAssertFalse(sink.uploaded.isEmpty, "\(label)：身份断言不能空跑")
                for packet in sink.uploaded {
                    let event = try object(parse(packet))
                    let userID = try optionalText(event, "user_id")
                    XCTAssertEqual(!(userID ?? "").isEmpty, hasUserID, label)
                }
            }
        }
    }

    func testPermissionVectors() async throws {
        for row in try rows("permission") {
            let label = try text(row, "name")
            let permission = try text(row, "permission")
            let file = VectorFile()
            let clock = VectorClock()
            let system = PermissionProbe()

            func makeRequester() -> PermissionRequester {
                PermissionRequester(
                    readFile: file.read,
                    writeFile: file.write,
                    clock: { clock.now },
                    platform: platform,
                    status: system.status,
                    showRationale: system.rationale,
                    systemRequest: system.systemRequest,
                    showSettingsGuide: system.settings
                )
            }

            var requester = makeRequester()
            var resultRaw: String?

            for step in try objectRows(row, "steps") {
                switch try text(step, "op") {
                case "systemResult":
                    system.nextResult = try text(step, "result")

                case "advance":
                    clock.now += Int64(try integer(step, "millis"))
                    requester = makeRequester()

                case "request":
                    let stateBefore = system.current[permission] ?? "not_asked"
                    system.resetCalls()
                    resultRaw = await requester.request(permission: permission).resultRaw

                    XCTAssertEqual(system.trace.first, "status", label)
                    let systemCalls = system.trace.filter { $0 == "system" }.count
                    XCTAssertLessThanOrEqual(systemCalls, 1, label)

                    if let systemIndex = system.trace.firstIndex(of: "system") {
                        let rationaleIndex = try XCTUnwrap(
                            system.trace.firstIndex(of: "rationale"),
                            "\(label)：系统申请前必须先说明"
                        )
                        XCTAssertLessThan(rationaleIndex, systemIndex, label)
                    }
                    if stateBefore == "granted" || stateBefore == "permanently_denied" {
                        XCTAssertEqual(systemCalls, 0, label)
                        XCTAssertTrue(system.rationales.isEmpty, label)
                    }

                    let purpose = permission == "push"
                        ? "perm.push.card_hint" : "perm.photos.purpose"
                    for call in system.rationales {
                        XCTAssertEqual(call.purpose, purpose, label)
                        XCTAssertEqual(call.continueKey, "perm.btn.continue", label)
                    }
                    for call in system.guides {
                        XCTAssertEqual(call.button, "perm.go_settings", label)
                        if resultRaw == "permanently_denied" {
                            let key = permission == "push"
                                ? "perm.push.denied_forever" : "perm.photos.denied_forever"
                            XCTAssertEqual(call.message, key, label)
                        }
                    }
                    if resultRaw == "throttled" {
                        XCTAssertEqual(systemCalls, 0, label)
                        XCTAssertTrue(system.rationales.isEmpty, label)
                        XCTAssertFalse(system.guides.isEmpty, label)
                    }

                default:
                    throw VectorError(message: "\(label)：未知权限步骤")
                }
            }

            let expected = try object(row["expect"])
            XCTAssertEqual(resultRaw, try text(expected, "resultRaw"), label)
            XCTAssertEqual(
                !system.rationales.isEmpty,
                try flag(expected, "showedRationale"),
                label
            )
            XCTAssertEqual(
                !system.guides.isEmpty,
                try flag(expected, "openSettingsGuide"),
                label
            )
        }
    }

    private func assertCommonFields(_ packet: String, _ label: String) throws {
        let event = try object(parse(packet))
        for key in [
            "event_id", "name", "client_at", "session_id",
            "device_id", "platform", "app_version", "page"
        ] {
            XCTAssertFalse(try text(event, key).isEmpty, "\(label)：\(key)")
        }
        XCTAssertEqual(try text(event, "name"), "app_launch", label)
        XCTAssertEqual(try text(event, "device_id"), deviceID, label)
        XCTAssertEqual(try text(event, "platform"), platform, label)
        XCTAssertEqual(try text(event, "session_id"), "session-test", label)
        XCTAssertEqual(try text(event, "app_version"), "1.0.0", label)
        XCTAssertEqual(try text(event, "page"), "Home", label)

        let timestamp = try text(event, "client_at")
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(
            plain.date(from: timestamp) ?? fractional.date(from: timestamp),
            "\(label)：client_at 必须是带时区 ISO 8601"
        )
    }

    private func assertCount(
        _ actual: Int,
        key: String,
        _ expected: VectorObject,
        _ label: String
    ) throws {
        let value = try integer(expected, key)
        let bounds = expected["upperBounds"] as? [String] ?? []
        XCTAssertGreaterThanOrEqual(actual, 0, label)
        if bounds.contains(key) {
            XCTAssertLessThanOrEqual(actual, value, "\(label)：\(key) 上界")
        } else {
            XCTAssertEqual(actual, value, "\(label)：\(key)")
        }
    }

    private func rows(_ group: String) throws -> [VectorObject] {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .standardizedFileURL

        while !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("contract.lock").path
        ) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw VectorError(message: "从 \(#filePath) 向上找不到 contract.lock")
            }
            directory = parent
        }

        let file = directory.appendingPathComponent("specs/client-core-vectors.json")
        let root = try object(JSONSerialization.jsonObject(with: Data(contentsOf: file)))
        XCTAssertEqual(try integer(root, "version"), 1, file.path)
        XCTAssertFalse(try XCTUnwrap(root["sources"] as? [String]).isEmpty, file.path)
        XCTAssertFalse(try XCTUnwrap(root["gaps"] as? [String]).isEmpty, file.path)

        for name in ["device", "config", "configFetch", "tracker", "permission"] {
            let entries = try objectRows(root, name)
            XCTAssertFalse(entries.isEmpty, name)
            let names = try entries.map { try text($0, "name") }
            XCTAssertEqual(names.count, Set(names).count, "\(name)：名称重复")
            for row in entries {
                XCTAssertFalse(try text(row, "name").isEmpty, name)
                XCTAssertFalse(try text(row, "note").isEmpty, name)
            }
        }
        return try objectRows(root, group)
    }

    private func object(_ value: Any?) throws -> VectorObject {
        try XCTUnwrap(value as? VectorObject, "预期 JSON object")
    }

    private func objectRows(_ row: VectorObject, _ key: String) throws -> [VectorObject] {
        try XCTUnwrap(row[key] as? [VectorObject], "缺少数组 \(key)")
    }

    private func text(_ row: VectorObject, _ key: String) throws -> String {
        try XCTUnwrap(row[key] as? String, "缺少字符串 \(key)")
    }

    private func optionalText(_ row: VectorObject, _ key: String) throws -> String? {
        guard let value = row[key], !(value is NSNull) else { return nil }
        return try XCTUnwrap(value as? String, "\(key) 必须是字符串或 null")
    }

    private func flag(_ row: VectorObject, _ key: String) throws -> Bool {
        try XCTUnwrap(row[key] as? Bool, "缺少布尔值 \(key)")
    }

    private func integer(_ row: VectorObject, _ key: String) throws -> Int {
        try XCTUnwrap(row[key] as? Int, "缺少整数 \(key)")
    }

    private func document(_ row: VectorObject, _ key: String) throws -> String? {
        guard let value = row[key], !(value is NSNull) else { return nil }
        return try json(value)
    }

    private func parse(_ value: String) throws -> Any {
        try JSONSerialization.jsonObject(
            with: Data(value.utf8), options: [.fragmentsAllowed]
        )
    }

    private func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .fragmentsAllowed]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private func assertJSON(
        _ actual: String?,
        equals expected: String,
        _ label: String
    ) throws {
        let actual = try XCTUnwrap(actual, label)
        XCTAssertEqual(
            try json(parse(actual)),
            try json(parse(expected)),
            label
        )
    }
}
