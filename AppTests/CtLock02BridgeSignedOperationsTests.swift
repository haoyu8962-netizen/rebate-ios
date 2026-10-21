import BridgeHost
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import XCTest

/// CT-LOCK-02 编排裁定（契约即白名单）：桥 net.signedRequest 按契约 signed 操作表放行，不在原生侧拦 createOrderClaim。
/// ① 桥可代发的 signed 操作集合 = 契约里的 signed 操作集合（预期值独立读 contracts/snapshot，不从生成代码反推、不手抄；
/// 实际值从生产准入与真实桥入口独立枚举，复审 r1 重写）；
/// ② a7c9f1f 起 openapi 有 createOrderClaim（POST /v1/orders/claims，signed），桥代发照常放行：只发 1 次、接口正确。
final class CtLock02BridgeSignedOperationsTests: MeTestCase {
    private func snapshot(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/snapshot/contracts/\(name)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], name)
    }

    /// 契约 openapi 的客户端接口（不含 /admin/）："METHOD path" → (operationId, x-signed)。
    private func contractOperations() throws -> [String: (id: String, signed: Bool)] {
        let paths = try XCTUnwrap(try snapshot("openapi.json")["paths"] as? [String: Any])
        var result: [String: (id: String, signed: Bool)] = [:]
        for (path, item) in paths where !path.hasPrefix("/admin/") {
            for (method, value) in item as? [String: Any] ?? [:] {
                guard let operation = value as? [String: Any],
                      let id = operation["operationId"] as? String else { continue }
                result["\(method.uppercased()) \(path)"] = (id, operation["x-signed"] as? Bool ?? false)
            }
        }
        return result
    }

    /// 快照 bridge.schema 的 signed_paths："METHOD path"（只读快照文件）。
    private func snapshotSignedPaths() throws -> [String] {
        let rows = try XCTUnwrap(try snapshot("bridge.schema.json")["signed_paths"] as? [[String: Any]])
        return try rows.map { row in
            "\(try XCTUnwrap(row["method"] as? String)) \(try XCTUnwrap(row["path"] as? String))"
        }
    }

    private func split(_ key: String) -> (method: String, path: String) {
        let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }

    /// 复审 r1 重写：预期 = 快照 signed_paths ∩ openapi x-signed；实际 = 把快照里每个客户端接口（签名与否）连同 signed_paths
    /// 各项都当候选，过生产准入的两道关（协议层 BridgeProtocol.signedPathAllowed + 代发查找 AppBridgeServices.signedOperation）
    /// 能通过的 operationId 集合。双向比较；白名单外候选一律不准入。
    func testBridgeSignedSetEqualsContractSignedSet() throws {
        let signedPaths = try snapshotSignedPaths()
        XCTAssertFalse(signedPaths.isEmpty, "前提：契约 signed_paths 非空")
        let contract = try contractOperations()
        let expected = Set(signedPaths.compactMap { contract[$0] }.filter(\.signed).map(\.id))
        XCTAssertEqual(expected.count, signedPaths.count, "signed_paths 每一项在 openapi 里都是签名接口")
        XCTAssertTrue(expected.contains("createOrderClaim"))
        let candidates = Set(contract.keys).union(signedPaths)
        let admitted = Set(candidates.compactMap { key -> String? in
            let parts = split(key)
            guard BridgeProtocol.signedPathAllowed(method: parts.method, path: parts.path) else { return nil }
            return AppBridgeServices.signedOperation(method: parts.method, path: parts.path)?.operationId
        })
        XCTAssertEqual(admitted.subtracting(expected), [], "多放的操作")
        XCTAssertEqual(expected.subtracting(admitted), [], "少放的操作")
        for key in candidates.subtracting(signedPaths) {
            let parts = split(key)
            XCTAssertFalse(BridgeProtocol.signedPathAllowed(method: parts.method, path: parts.path), "白名单外不准入：\(key)")
        }
        // 查找本身与 openapi 的 x-signed 一一对应：签名接口能找到，非签名接口找不到。
        for (key, value) in contract {
            let parts = split(key)
            XCTAssertEqual(
                AppBridgeServices.signedOperation(method: parts.method, path: parts.path)?.operationId,
                value.signed ? value.id : nil, key
            )
        }
    }

    /// 复审 r1：经真实 BridgeHost 入口（协议层准入 → 生产代发 AppBridgeServices.signedRequest → ApiClient → 假服务）逐个代发
    /// 快照里的每个客户端接口；真正到达假服务的 "METHOD path" 集合必须等于快照 signed_paths ∩ openapi x-signed，
    /// 白名单外的候选不回成功、零请求。
    func testOnlyContractSignedOperationsReachTheServerThroughTheRealBridge() async throws {
        let contract = try contractOperations()
        let expected = Set(try snapshotSignedPaths().filter { contract[$0]?.signed == true })
        XCTAssertFalse(expected.isEmpty)
        let fixture = make()
        let host = signedOnlyHost(fixture.client)
        let candidates = contract.keys.sorted()
        await settle(50)
        let baseline = WalletStubProtocol.requests.count
        for (index, key) in candidates.enumerated() {
            let parts = split(key)
            let before = WalletStubProtocol.requests.filter { key == "\($0.method) \($0.path)" }.count
            let box = SignedReplyBox()
            let raw = #"{"v":1,"id":"s\#(index)","method":"net.signedRequest","params":{"method":"\#(parts.method)","#
                + #""path":"\#(parts.path)","body":{}}}"#
            host.handle(raw: raw, origin: Self.origin, isMainFrame: true, userGesture: true) { box.value = $0 }
            await waitUntil("没有回复：\(key)") { box.value != nil }
            await settle()
            let after = WalletStubProtocol.requests.filter { key == "\($0.method) \($0.path)" }.count
            if expected.contains(key) {
                XCTAssertEqual(box.code, BridgeCode.ok, "放行：\(key)")
                XCTAssertEqual(after, before + 1, "放行且只发 1 次：\(key)")
            } else {
                XCTAssertNotEqual(box.code, BridgeCode.ok, "白名单外不回成功：\(key)")
                XCTAssertEqual(after, before, "白名单外零请求：\(key)")
            }
        }
        let sent = Set(WalletStubProtocol.requests.dropFirst(baseline).map { "\($0.method) \($0.path)" })
        XCTAssertEqual(sent, expected)
    }

    private static let origin = "https://h5.example.test"
    /// BridgeHost 只弱持有 UI（与容器同生命周期），测试里自己留住。
    private var bridgeUI: SignedOnlyUI?

    /// 与 AppWeb 同口径的调用方状态，接真实 BridgeHost；net.signedRequest 走生产实现，其余能力本测试不用。
    private func signedOnlyHost(_ client: ApiClient) -> BridgeHost {
        let caller: @MainActor () -> BridgeCallerState = {
            BridgeCallerState(
                privacy: BridgePrivacy.consented,
                accountKey: AppWeb.accountKey(account: client.isolatedAccount, generation: client.sessionGeneration),
                update: BridgeUpdateState.supported
            )
        }
        let ui = SignedOnlyUI()
        bridgeUI = ui
        return BridgeHost(
            protocol: { BridgeProtocol(trustedOrigins: [Self.origin], linkPatterns: [:], shareDomains: []) },
            caller: caller,
            services: SignedOnlyServices(client: client),
            ui: ui,
            awaitUpdate: { BridgeUpdateState.supported }
        )
    }

    func testClaimSignedPathIsSentOnce() async throws {
        script.ok("POST /v1/orders/claims", "{}")
        let fixture = make()
        let outcome = await AppBridgeServices.signedRequest(
            client: fixture.client, method: "POST", path: "/v1/orders/claims",
            bodyJson: "{\"platform\":\"taobao\",\"order_no\":\"1234567890\"}", validity: BridgeCallValidity()
        )
        await settle()
        XCTAssertEqual(outcome.code, BridgeCode.ok)
        XCTAssertEqual(requests("POST", "/v1/orders/claims").count, 1, "放行：只发 1 次")
        let sent = try XCTUnwrap(requests("POST", "/v1/orders/claims").first)
        XCTAssertTrue(sent.body.contains("1234567890"), "请求体原样代发")
        XCTAssertTrue(sent.query.isEmpty)
    }
}

@MainActor
private final class SignedReplyBox {
    var value: String?

    var code: Int? {
        value.flatMap { AppWeb.object($0) }?["code"] as? Int
    }
}

private final class SignedOnlyUI: BridgeUI {
    func toast(text _: String, long _: Bool) {}
    func showLoading(text _: String?) {}
    func hideLoading() {}
    func setNavBar(_: BridgeNavBar) -> Bool {
        true
    }

    func close() {}
}

/// 只接 net.signedRequest（生产实现 `AppBridgeServices.signedRequest(client:...)`），其余能力本测试不用。
@MainActor
private final class SignedOnlyServices: BridgeServices {
    private let client: ApiClient

    init(client: ApiClient) {
        self.client = client
    }

    func env() -> [String: Any] {
        [:]
    }

    func config(keys _: [String]) -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func user(validity _: BridgeCallValidity) async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func h5Token(readOnly _: Bool, validity _: BridgeCallValidity) async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func login() async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func signedRequest(
        method: String,
        path: String,
        bodyJson: String?,
        validity: BridgeCallValidity
    ) async -> BridgeOutcome {
        await AppBridgeServices.signedRequest(
            client: client, method: method, path: path, bodyJson: bodyJson, validity: validity
        )
    }

    func navOpen(route _: String, paramsJson _: String, readOnlyPagesOnly _: Bool) async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func clipboardWrite(text _: String) -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func clipboardRead() async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func setClipboardAutoDetect(enabled _: Bool) -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func pushStatus() async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func requestPermission(type _: String, isStillValid _: @escaping @MainActor () -> Bool) async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func track(name _: String) -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func reportRejected(method _: String, code _: Int) {}
}
