/*
 实现前测试；只读会话未写文件、未编译运行。

 接线约定：
 - BridgeProtocol(trustedOrigins: [String], linkPatterns: [String: Any],
   shareDomains: [String]) 是不可变配置的纯判定器，不读取生产配置或全局状态。
 - 静态方法 parseEnvelope(raw: String) 返回 valid: Bool、errorCode: Int?、
   method/id: String?、params: [String: Any]?；非法输入返回结果，不抛异常。
 - parseEnvelope 验信封及已登记方法参数；未知方法由 decide 返回 90001。
   成功时 params 必须存在，省略的 params 规范化为 [:]。
 - 实例方法 decide(ctx: BridgeContext)；BridgeContext 的初始化参数为
   method、origin、isMainFrame、userGesture、privacy、loggedIn、params。
   privacy 使用原始字符串，params 为 [String: Any]。
 - 静态 signedPathAllowed(method:path:)、eventAllowed(name:) 返回 Bool。
 - ExternalNavPolicy(bundledLinkPatterns: [String: Any]) 注入随包表替身；
   decide(url:isMainFrame:isNewWindow:linkPatterns:) 的末参为可选字典。
   测试直接传 nil，不在测试里实现回落。返回 actionRaw: String、reason: String?。
 - fixture_current/fixture_bundled 行提供输入夹具，不从 expect 生成配置。
 - allow 仅表示协议准入；since/能力声明/Host 暂不支持另测，见 vectors.gaps。
 - 成功的 errorCode 为 nil；拒绝且未给期望码时不比较，不能臆造隐私错误码。
 - 测试域不得进入生产白名单。适配层只能转型转发，不能实现判定规则。
 - Package.swift 需增加 BridgeHostTests testTarget，依赖 BridgeHost。
 */

import Foundation
import XCTest
@testable import BridgeHost

private typealias BridgeVectorObject = [String: Any]

final class BridgeVectorTests: XCTestCase {
    func testManifestAndMethodCoverage() throws {
        let root = try vectors()
        let envelopes: [BridgeVectorObject] = try field(root, "envelope", "manifest")
        let access: [BridgeVectorObject] = try field(root, "access", "manifest")
        var declared = Set<String>()

        for row in envelopes {
            let name: String = try field(row, "name", "envelope")
            if name.hasPrefix("valid:") {
                declared.insert(String(name.dropFirst("valid:".count)))
            }
        }
        XCTAssertFalse(declared.isEmpty)

        for method in declared {
            let matching = access.filter { ($0["method"] as? String) == method }
            let allows = matching.filter {
                ($0["expect"] as? BridgeVectorObject)?["allow"] as? Bool == true
            }
            let denies = matching.filter {
                ($0["expect"] as? BridgeVectorObject)?["allow"] as? Bool == false
            }
            XCTAssertFalse(denies.isEmpty, "\(method): 缺少拒绝向量")
            if method == "ext.openApp" {
                XCTAssertTrue(allows.isEmpty, "现有目标全是 trade_only，不能伪造允许")
            } else {
                XCTAssertFalse(allows.isEmpty, "\(method): 缺少协议准入向量")
            }
        }
    }

    func testEnvelopeVectors() throws {
        try each(try vectors(), group: "envelope") { row, label in
            let raw: String = try field(row, "raw", label)
            let expected: BridgeVectorObject = try field(row, "expect", label)
            let valid: Bool = try field(expected, "valid", label)
            let actual = BridgeProtocol.parseEnvelope(raw: raw)

            XCTAssertEqual(actual.valid, valid, "\(label): valid")
            try checkCode(actual.errorCode, expected, success: valid, label: label)

            if valid && actual.valid {
                let input = try object(raw)
                let method: String = try field(input, "method", label)
                let identifier: String = try field(input, "id", label)
                let params = try optionalObject(input, "params", label) ?? [:]

                XCTAssertEqual(actual.method, method, "\(label): method")
                XCTAssertEqual(actual.id, identifier, "\(label): id")
                let parsedParams = try XCTUnwrap(actual.params, "\(label): params")
                XCTAssertEqual(
                    try canonicalJSON(parsedParams),
                    try canonicalJSON(params),
                    "\(label): params 必须保留 JSON 类型和值"
                )
            }
        }
    }

    func testAccessVectors() throws {
        let root = try vectors()
        let bridge = try makeBridge(root)

        try each(root, group: "access") { row, label in
            let expected: BridgeVectorObject = try field(row, "expect", label)
            let allow: Bool = try field(expected, "allow", label)
            let actual = bridge.decide(ctx: try context(row, label))

            XCTAssertEqual(actual.allow, allow, "\(label): allow")
            try checkCode(actual.errorCode, expected, success: allow, label: label)
        }
    }

    func testTrustedOriginsAreInjected() throws {
        let root = try vectors()
        let injected = "https://injected.example.test:8443"
        let request = BridgeContext(
            method: "app.getEnv",
            origin: injected,
            isMainFrame: true,
            userGesture: false,
            privacy: "consented",
            loggedIn: false,
            params: [:]
        )

        let allowed = try makeBridge(root, origins: [injected]).decide(ctx: request)
        XCTAssertTrue(allowed.allow)
        XCTAssertNil(allowed.errorCode)

        let denied = try makeBridge(root).decide(ctx: request)
        XCTAssertFalse(denied.allow)
        XCTAssertEqual(denied.errorCode, 90403)

        let empty = try makeBridge(root, origins: []).decide(ctx: request)
        XCTAssertFalse(empty.allow)
        XCTAssertEqual(empty.errorCode, 90403)
    }

    func testSignedPathVectors() throws {
        try each(try vectors(), group: "signedPaths") { row, label in
            let expected: BridgeVectorObject = try field(row, "expect", label)
            let allow: Bool = try field(expected, "allow", label)
            let actual = BridgeProtocol.signedPathAllowed(
                method: try field(row, "method", label),
                path: try field(row, "path", label)
            )
            XCTAssertEqual(actual, allow, label)
        }
    }

    func testEventVectors() throws {
        try each(try vectors(), group: "events") { row, label in
            let expected: BridgeVectorObject = try field(row, "expect", label)
            let deliver: Bool = try field(expected, "deliver", label)
            let actual = BridgeProtocol.eventAllowed(
                name: try field(row, "event", label)
            )
            XCTAssertEqual(actual, deliver, label)
        }
    }

    func testExternalNavigationVectors() throws {
        let root = try vectors()
        let bundled = try fixture(root, name: "fixture_bundled")

        try each(root, group: "externalNav") { row, label in
            // 每行重建，避免上一行的远程表污染下一行的包内回落。
            let policy = ExternalNavPolicy(bundledLinkPatterns: bundled)
            let expected: BridgeVectorObject = try field(row, "expect", label)
            let actual = policy.decide(
                url: try field(row, "url", label),
                isMainFrame: try field(row, "isMainFrame", label),
                isNewWindow: try field(row, "isNewWindow", label),
                linkPatterns: try optionalObject(row, "linkPatterns", label)
            )
            let action: String = try field(expected, "action", label)
            XCTAssertEqual(actual.actionRaw, action, "\(label): action")
            if expected["reason"] != nil {
                let reason: String = try field(expected, "reason", label)
                XCTAssertEqual(actual.reason, reason, "\(label): reason")
            }
        }
    }

    private func makeBridge(
        _ root: BridgeVectorObject,
        origins: [String] = ["https://h5.example.test"]
    ) throws -> BridgeProtocol {
        BridgeProtocol(
            trustedOrigins: origins,
            linkPatterns: try fixture(root, name: "fixture_current"),
            shareDomains: ["s.example.test"]
        )
    }

    private func context(
        _ row: BridgeVectorObject,
        _ label: String
    ) throws -> BridgeContext {
        BridgeContext(
            method: try field(row, "method", label),
            origin: try field(row, "origin", label),
            isMainFrame: try field(row, "isMainFrame", label),
            userGesture: try field(row, "userGesture", label),
            privacy: try field(row, "privacy", label),
            loggedIn: try field(row, "loggedIn", label),
            params: try optionalObject(row, "params", label) ?? [:]
        )
    }

    private func fixture(
        _ root: BridgeVectorObject,
        name: String
    ) throws -> BridgeVectorObject {
        let rows: [BridgeVectorObject] = try field(root, "externalNav", name)
        let row = try XCTUnwrap(
            rows.first { ($0["name"] as? String) == name },
            "缺少规则夹具 \(name)"
        )
        return try field(row, "linkPatterns", name)
    }

    private func checkCode(
        _ actual: Int?,
        _ expected: BridgeVectorObject,
        success: Bool,
        label: String
    ) throws {
        if success {
            XCTAssertNil(actual, "\(label): 成功不携带错误码")
        } else if expected["errorCode"] != nil {
            let code: Int = try field(expected, "errorCode", label)
            XCTAssertEqual(actual, code, "\(label): errorCode")
        }
    }

    private func each(
        _ root: BridgeVectorObject,
        group: String,
        check: (BridgeVectorObject, String) throws -> Void
    ) throws {
        let rows: [BridgeVectorObject] = try field(root, group, group)
        XCTAssertFalse(rows.isEmpty, "\(group): 向量不能为空")
        var names = Set<String>()

        for (index, row) in rows.enumerated() {
            let name: String = try field(row, "name", "\(group)[\(index)]")
            let label = "\(group)[\(index)] \(name)"
            XCTAssertFalse(name.isEmpty, label)
            XCTAssertTrue(names.insert(name).inserted, "\(label): 重复名称")

            if group == "access" || group == "externalNav" {
                let note: String = try field(row, "note", label)
                XCTAssertFalse(note.isEmpty, "\(label): note")
            }
            do {
                try check(row, label)
            } catch {
                XCTFail("\(label): \(error)")
            }
        }
    }

    private func vectors() throws -> BridgeVectorObject {
        let url = try repositoryRoot().appendingPathComponent("specs/bridge-vectors.json")
        let root = try object(String(contentsOf: url, encoding: .utf8))
        let version: Int = try field(root, "version", "manifest")
        let sources: [String] = try field(root, "sources", "manifest")
        let gaps: [String] = try field(root, "gaps", "manifest")
        XCTAssertEqual(version, 1)
        XCTAssertFalse(sources.isEmpty)
        XCTAssertFalse(gaps.isEmpty)
        return root
    }

    private func object(_ text: String) throws -> BridgeVectorObject {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? BridgeVectorObject,
            "JSON 根必须为对象"
        )
    }

    private func field<T>(
        _ object: BridgeVectorObject,
        _ key: String,
        _ label: String
    ) throws -> T {
        try XCTUnwrap(object[key] as? T, "\(label): \(key) 缺失或类型错误")
    }

    private func optionalObject(
        _ object: BridgeVectorObject,
        _ key: String,
        _ label: String
    ) throws -> BridgeVectorObject? {
        guard object[key] != nil else { return nil }
        return try field(object, key, label)
    }

    private func canonicalJSON(_ object: BridgeVectorObject) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
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
                    domain: "BridgeVectorTests",
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
