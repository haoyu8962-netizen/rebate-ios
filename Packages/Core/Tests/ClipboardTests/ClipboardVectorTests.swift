/*
 实现前测试；只读输出，未编译运行。需登记 ClipboardTests target。

 接线约定（以下类型由 Clipboard 模块提供）：
 - ClipboardReadPolicy.decide(platform: String, state: [String: Any])
   -> { actionRaw: String, reasonRaw: String? }。
 - InviteCodeExtractor.extract(_ text: String) -> String?。
 - ClipboardRules.defaults。
 - ClipboardClassifier.classify(text: String, context: ClipboardContext,
   rules: ClipboardRules, nowMs: Int64)
   -> { kindRaw: String, reasonRaw: String?, inviteCode: String?,
        uploadText: String? }。
 - ClipboardContext(selfWritten: [String],
   prompted: [ClipboardPromptStamp], inviteEligible: Bool,
   selfInviteCode: String?, shareDomains: [String],
   hash: @escaping (String) -> String)。
   selfWritten 为 hash 数组；ClipboardPromptStamp(hash: String, atMs: Int64)。
   这些是纯逻辑的输入 DTO，不是新服务端字段。
 - ClipboardWriteLedger(capacity: Int = 10,
   hash: @escaping (String) -> String)；record(_ text: String)；
   contains(_ text: String) -> Bool。hash 是题定的注入依赖。
 - ParseResultAction.map(response: [String: Any]?, errorCode: Int?,
   retryAfter: String?, traceId: String?)
   -> { actionRaw: String, linkId: String?, prefill: String?,
        textKey: String?, showTrace6: Bool?, disableMs: Int64? }。
   response 原样传 ParseInputResponse 外壳；errorCode 是业务码。
 - ManualPasteAction.decide(entry: String, text: String?, rules: ClipboardRules)
   -> { actionRaw: String, uploadText: String?, prefill: String?, code: String? }。
 - InviteConfirmAction.decide(session: String, me: [String: Any]?)
   -> { actionRaw: String }；me 是题定的邀请状态投影。
 - expect 缺字段不判定，显式 null 必须无值。
 - readPolicy 的中性前提见 neutralState，不是生产配置默认值。
   iosDetectHit 缺失保持缺失。所有平台向量均执行。
 - 每行独立 hash/ledger；固定毫秒时钟。
   假 hash 只测试相等关系，不实现生产哈希、不读写系统剪贴板。
 - gaps 中的执行层验收不由这些纯函数测试代替。
 */

import Foundation
import XCTest
@testable import Clipboard

private typealias ClipboardJSON = [String: Any]

private final class ClipboardVectorHasher {
    private var values: [String: String] = [:]

    func digest(_ text: String) -> String {
        if let existing = values[text] {
            return existing
        }
        let digest = "fixture-digest-\(values.count + 1)"
        values[text] = digest
        return digest
    }
}

final class ClipboardVectorTests: XCTestCase {
    private let nowMs: Int64 = 1_800_000_000_000

    private let groups = [
        "readPolicy", "inviteExtract", "classify", "writeLedger",
        "parseResult", "manualPaste", "inviteConfirm",
    ]

    func testManifest() throws {
        let root = try vectors()
        let version: Int = try value(root, "version")
        let sources: [String] = try value(root, "sources")
        let gaps: [String] = try value(root, "gaps")
        XCTAssertEqual(version, 1)
        XCTAssertFalse(sources.isEmpty)
        XCTAssertFalse(gaps.isEmpty)

        for group in groups {
            let rows: [ClipboardJSON] = try value(root, group)
            XCTAssertFalse(rows.isEmpty, group)
            let names: [String] = try rows.map { try value($0, "name") }
            XCTAssertTrue(names.allSatisfy { !$0.isEmpty }, group)
            XCTAssertEqual(names.count, Set(names).count, "\(group): 名称重复")
        }

        let rows: [ClipboardJSON] = try value(root, "classify")
        for row in rows {
            let name: String = try value(row, "name")
            let text: String = try value(row, "text")
            if name == "length_500" {
                XCTAssertEqual(text.utf8.count, 500, name)
            }
            if name == "length_501" {
                XCTAssertEqual(text.utf8.count, 501, name)
            }
        }
    }

    func testReadPolicyVectors() throws {
        try each("readPolicy") { row, expected, label in
            let platform: String = try self.value(row, "platform")
            let raw: ClipboardJSON = try self.value(row, "state")
            let actual = ClipboardReadPolicy.decide(
                platform: platform,
                state: self.neutralState(platform: platform, raw: raw)
            )
            let action: String = try self.value(expected, "actionRaw")
            XCTAssertEqual(actual.actionRaw, action, "\(label).actionRaw")
            try self.assertText(expected, "reasonRaw", actual.reasonRaw, label)
        }
    }

    func testInviteExtractVectors() throws {
        try each("inviteExtract") { row, expected, label in
            let text: String = try self.value(row, "text")
            XCTAssertNotNil(expected["code"], "\(label).code 必须存在")
            try self.assertText(
                expected,
                "code",
                InviteCodeExtractor.extract(text),
                label
            )
        }
    }

    func testClassifyVectors() throws {
        try each("classify") { row, expected, label in
            let hashes = ClipboardVectorHasher()
            let wire: ClipboardJSON = try self.value(row, "context")
            let written: [String] = try self.value(wire, "selfWritten")
            let history: [ClipboardJSON] = try self.value(wire, "prompted")
            let eligible: Bool = try self.value(wire, "inviteEligible")
            let domains: [String] = try self.value(wire, "shareDomains")

            let prompted = try history.map { item in
                let text: String = try self.value(item, "text")
                let agoMs: Int64 = try self.value(item, "agoMs")
                return ClipboardPromptStamp(
                    hash: hashes.digest(text),
                    atMs: self.nowMs - agoMs
                )
            }

            let context = ClipboardContext(
                selfWritten: written.map(hashes.digest),
                prompted: prompted,
                inviteEligible: eligible,
                selfInviteCode: try self.optionalText(wire, "selfInviteCode"),
                shareDomains: domains,
                hash: hashes.digest
            )
            let text: String = try self.value(row, "text")
            let actual = ClipboardClassifier.classify(
                text: text,
                context: context,
                rules: ClipboardRules.defaults,
                nowMs: self.nowMs
            )

            let kind: String = try self.value(expected, "kindRaw")
            XCTAssertEqual(actual.kindRaw, kind, "\(label).kindRaw")
            try self.assertText(expected, "reasonRaw", actual.reasonRaw, label)
            try self.assertText(expected, "inviteCode", actual.inviteCode, label)
            try self.assertText(expected, "uploadText", actual.uploadText, label)
        }
    }

    func testWriteLedgerVectors() throws {
        try each("writeLedger") { row, expected, label in
            let hashes = ClipboardVectorHasher()
            var ledger = ClipboardWriteLedger(
                capacity: 10,
                hash: hashes.digest
            )
            let writes: [String] = try self.value(row, "writes")
            for text in writes {
                ledger.record(text)
            }

            let probe: String = try self.value(row, "probe")
            let excluded: Bool = try self.value(expected, "excluded")
            XCTAssertEqual(ledger.contains(probe), excluded, label)
        }
    }

    func testParseResultVectors() throws {
        try each("parseResult") { row, expected, label in
            let headers = row["headers"] as? ClipboardJSON
            let actual = ParseResultAction.map(
                response: row["response"] as? ClipboardJSON,
                errorCode: row["errorCode"] as? Int,
                retryAfter: try headers.flatMap {
                    try self.optionalText($0, "Retry-After")
                },
                traceId: try self.optionalText(row, "traceId")
            )
            let action: String = try self.value(expected, "actionRaw")
            XCTAssertEqual(actual.actionRaw, action, "\(label).actionRaw")
            try self.assertText(expected, "linkId", actual.linkId, label)
            try self.assertText(expected, "prefill", actual.prefill, label)
            try self.assertText(expected, "textKey", actual.textKey, label)

            if expected.keys.contains("showTrace6") {
                let flag: Bool = try self.value(expected, "showTrace6")
                XCTAssertEqual(actual.showTrace6, flag, "\(label).showTrace6")
            }
            if expected.keys.contains("disableMs") {
                let duration: Int64 = try self.value(expected, "disableMs")
                XCTAssertEqual(actual.disableMs, duration, "\(label).disableMs")
            }
        }
    }

    func testManualPasteVectors() throws {
        try each("manualPaste") { row, expected, label in
            let entry: String = try self.value(row, "entry")
            XCTAssertNotNil(row["text"], "\(label).text 必须存在")
            let actual = ManualPasteAction.decide(
                entry: entry,
                text: try self.optionalText(row, "text"),
                rules: ClipboardRules.defaults
            )
            let action: String = try self.value(expected, "actionRaw")
            XCTAssertEqual(actual.actionRaw, action, "\(label).actionRaw")
            try self.assertText(expected, "uploadText", actual.uploadText, label)
            try self.assertText(expected, "prefill", actual.prefill, label)
            try self.assertText(expected, "code", actual.code, label)
        }
    }

    func testInviteConfirmVectors() throws {
        try each("inviteConfirm") { row, expected, label in
            let session: String = try self.value(row, "session")
            let actual = InviteConfirmAction.decide(
                session: session,
                me: row["me"] as? ClipboardJSON
            )
            let action: String = try self.value(expected, "actionRaw")
            XCTAssertEqual(actual.actionRaw, action, label)
        }
    }

    private func neutralState(
        platform: String,
        raw: ClipboardJSON
    ) -> ClipboardJSON {
        var state: ClipboardJSON = [
            "overlay": "none",
            "configEnabled": true,
            "webSuppressed": false,
            "readThisForeground": false,
        ]
        if platform == "ios" {
            state["iosChangeCountChanged"] = true
        }
        if platform == "android" {
            state["androidAutoSwitch"] = true
            state["androidWindowFocused"] = true
        }
        for (key, value) in raw {
            state[key] = value
        }
        return state
    }

    private func each(
        _ group: String,
        body: (ClipboardJSON, ClipboardJSON, String) throws -> Void
    ) throws {
        let rows: [ClipboardJSON] = try value(try vectors(), group)
        XCTAssertFalse(rows.isEmpty, group)
        for row in rows {
            let name: String = try value(row, "name")
            let expected: ClipboardJSON = try value(row, "expect")
            try body(row, expected, "\(group).\(name)")
        }
    }

    private func value<T>(
        _ object: ClipboardJSON,
        _ key: String
    ) throws -> T {
        try XCTUnwrap(
            object[key] as? T,
            "\(key) 缺失或类型错误，期望 \(T.self)"
        )
    }

    private func optionalText(
        _ object: ClipboardJSON,
        _ key: String
    ) throws -> String? {
        guard let raw = object[key], !(raw is NSNull) else {
            return nil
        }
        return try XCTUnwrap(raw as? String, "\(key) 应为字符串或 null")
    }

    private func assertText(
        _ expected: ClipboardJSON,
        _ key: String,
        _ actual: String?,
        _ label: String
    ) throws {
        guard expected.keys.contains(key) else {
            return
        }
        XCTAssertEqual(
            actual,
            try optionalText(expected, key),
            "\(label).\(key)"
        )
    }

    private func vectors() throws -> ClipboardJSON {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .standardizedFileURL

        while !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("contract.lock").path
        ) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw NSError(
                    domain: "ClipboardVectorTests",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "从 \(#filePath) 向上找不到 contract.lock",
                    ]
                )
            }
            directory = parent
        }

        let file = directory.appendingPathComponent(
            "specs/clipboard-vectors.json"
        )
        let decoded = try JSONSerialization.jsonObject(
            with: Data(contentsOf: file)
        )
        return try XCTUnwrap(decoded as? ClipboardJSON, file.path)
    }
}
