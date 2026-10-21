import BridgeHost
import ClientCore
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import XCTest

/// F-X-24 的透明替身：只计数系统能力；签名请求仍走生产 AppBridgeServices → ApiClient → WalletStubProtocol。
@MainActor
final class DisabledMethodsServices: BridgeServices, BridgeUI {
    let client: ApiClient
    var calls: [String] = []
    var rejected: [TrackEvent] = []

    init(client: ApiClient) {
        self.client = client
    }

    func env() -> [String: Any] {
        calls.append("app.getEnv")
        return ["platform": "ios"]
    }

    func clipboardRead() async -> BridgeOutcome {
        calls.append("clipboard.read")
        return .ok(["text": "fx24-test-clipboard"])
    }

    func signedRequest(method: String, path: String, bodyJson: String?, validity: BridgeCallValidity) async
        -> BridgeOutcome {
        calls.append("net.signedRequest")
        return await AppBridgeServices.signedRequest(
            client: client, method: method, path: path, bodyJson: bodyJson, validity: validity
        )
    }

    func reportRejected(method: String, code: Int) {
        rejected.append(TrackerEvents.bridgeCall(page: AppWeb.page, method: method, code: code))
    }

    func config(keys _: [String]) -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func user(validity _: BridgeCallValidity) async -> BridgeOutcome {
        calls.append("auth.getUser")
        return .fail(BridgeCode.notSupported)
    }

    func h5Token(readOnly _: Bool,
                 validity _: BridgeCallValidity) async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func login() async -> BridgeOutcome {
        calls.append("auth.login")
        return .fail(BridgeCode.notSupported)
    }

    func navOpen(route _: String, paramsJson _: String, readOnlyPagesOnly _: Bool) async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func clipboardWrite(text _: String) -> BridgeOutcome {
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

    func toast(text _: String, long _: Bool) {}
    func showLoading(text _: String?) {}
    func hideLoading() {}
    func setNavBar(_: BridgeNavBar) -> Bool {
        true
    }

    func close() {}
}

@MainActor
final class DisabledMethodsFixture {
    static let origin = "https://h5.example.test"
    let services: DisabledMethodsServices
    private var pending: ((ConfigReply) -> Void)?
    lazy var store = ConfigStore(
        readFile: { nil }, writeFile: { _ in }, fetcher: { [unowned self] _, done in pending = done },
        clock: { 1 }, bundled: "{}"
    )

    init(client: ApiClient, disabled: [String]) throws {
        services = DisabledMethodsServices(client: client)
        try update(disabled)
    }

    func update(_ disabled: [String]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["bridge_disabled_methods": disabled])
        store.onForeground()
        let reply = try XCTUnwrap(pending)
        pending = nil
        reply(.init(kindRaw: ConfigReply.ok, bodyJson: try XCTUnwrap(String(bytes: data, encoding: .utf8)), etag: nil))
    }

    func makeHost(
        ui: (any BridgeUI)? = nil,
        update: @escaping @MainActor () -> String = { BridgeUpdateState.supported },
        awaitUpdate: @escaping @MainActor () async -> String = { BridgeUpdateState.supported }
    ) -> BridgeHost {
        BridgeHost(
            protocol: { BridgeProtocol(trustedOrigins: [Self.origin], linkPatterns: [:], shareDomains: []) },
            caller: { [services] in
                BridgeCallerState(
                    privacy: BridgePrivacy.consented,
                    accountKey: AppWeb.accountKey(account: services.client.isolatedAccount,
                                                  generation: services.client.sessionGeneration),
                    update: update()
                )
            },
            services: services, ui: ui ?? services, awaitUpdate: awaitUpdate,
            disabledMethods: { [store] in store.bridgeDisabledMethods() }
        )
    }

    func call(
        _ host: BridgeHost, method: String, params: [String: Any] = [:],
        whilePending: (@MainActor () async throws -> Void)? = nil
    ) async throws -> [String: Any] {
        let id = UUID().uuidString
        let request = try JSONSerialization.data(withJSONObject: ["v": 1, "id": id, "method": method, "params": params])
        var responses: [String?] = []
        host.handle(raw: try XCTUnwrap(String(bytes: request, encoding: .utf8)), origin: Self.origin,
                    isMainFrame: true, userGesture: true) { responses.append($0) }
        try await whilePending?()
        await waitUntil("F-X-24 桥调用没有结算：\(method)") { !responses.isEmpty }
        await settle()
        XCTAssertEqual(responses.count, 1, "每次调用只结算一次")
        XCTAssertEqual(host.inFlightCount, 0)
        let first = try XCTUnwrap(responses.first)
        let response = try XCTUnwrap(first)
        let object = try XCTUnwrap(AppWeb.object(response))
        XCTAssertEqual(object["id"] as? String, id)
        return object
    }
}

/// 只有测试显式放行才结束强更等待；isWaiting 证明调用已经真正挂起，不靠固定休眠猜执行时序。
@MainActor
final class DisabledMethodsUpdateGate {
    private(set) var state = BridgeUpdateState.checking
    private var continuation: CheckedContinuation<String, Never>?

    var isWaiting: Bool {
        continuation != nil
    }

    func wait() async -> String {
        guard state == BridgeUpdateState.checking else { return state }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        state = BridgeUpdateState.supported
        let pending = continuation
        continuation = nil
        pending?.resume(returning: state)
    }
}
