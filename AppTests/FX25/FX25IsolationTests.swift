import BridgeHost
@testable import Couli
import CouliNetwork
import Foundation
@testable import Web
import WebKit
import XCTest

@MainActor
final class FX25IsolationTests: FX25TestCase {
    func testI1R101OldBridgeRejectedDuringCleanupAfterFailureAndAfterRecovery() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let controller = try page(web, path: "/isolation")
        try await loaded("/isolation")
        let oldView = controller.webView
        let oldHost = try XCTUnwrap(controller.host)
        probe.held = .cookies
        probe.fault = (.cookies, .throwing)
        try await login(app)
        try await until("清理没有开始") { self.probe.entered.contains(.cookies) }
        XCTAssertTrue(controller.isAuthIsolated)
        try await assertBridgeDenied(oldHost, controller: controller)
        let tokenCalls = requests("POST", "/v1/auth/h5-token").count
        try await assertBridgeDenied(oldHost, controller: controller, method: "auth.getH5Token", params: [:])
        XCTAssertEqual(requests("POST", "/v1/auth/h5-token").count, tokenCalls)
        let before = server.requests("/forbidden-load")
        oldView.load(URLRequest(url: try XCTUnwrap(URL(string: server.origin + "/forbidden-load"))))
        _ = try await oldView.evaluateJavaScript("location.href = '/forbidden-navigation'; true")
        controller.retry()
        probe.release()
        await settled(web, succeeds: false)
        XCTAssertEqual(server.requests("/forbidden-load"), before)
        XCTAssertEqual(server.requests("/forbidden-navigation"), 0)
        XCTAssertTrue(controller.isAuthIsolated)
        XCTAssertTrue(controller.loadFailed)
        try await assertBridgeDenied(oldHost, controller: controller)
        probe.fault = nil
        controller.retry()
        await settled(web)
        try await loaded("/isolation", count: 2)
        XCTAssertFalse(controller.isAuthIsolated)
        try await assertBridgeDenied(oldHost, controller: controller)
        // 新文档必须真的可用，而不是永远隔离骗过负向断言。
        let result = try await controller.webView.callAsyncJavaScript(
            "return await window.__REBATE_BRIDGE__.postMessage({v:1,id:'new-doc',method:'app.getEnv'});",
            arguments: [:], in: nil, contentWorld: .page
        )
        XCTAssertEqual((result as? [String: Any])?["code"] as? Int, 0)
    }

    func testI1SynchronousIsolationBeforeFirstCleanupCallback() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let first = try page(web, path: "/atomic-a")
        let second = try page(web, path: "/atomic-b")
        try await loaded("/atomic-a")
        try await loaded("/atomic-b")
        probe.beforeClear = {
            XCTAssertTrue(first.isAuthIsolated)
            XCTAssertTrue(second.isAuthIsolated, "不能逐页隔离一页、先 await 清理、再隔离下一页")
        }
        app.client.signOut()
        await settled(web)
        XCTAssertFalse(probe.entered.isEmpty)
    }

    func testI1P12ProvisionalNavigationCannotDeliverNewTokenOrEventToDepartingDocument() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let controller = try page(web, path: "/departing")
        try await loaded("/departing")
        let original = try await controller.webView
            .evaluateJavaScript("JSON.stringify(window.__REBATE_BRIDGE__.methods)")
            as? String
        server.holdResponse(for: "/pending-navigation")
        controller.webView.load(URLRequest(url: try XCTUnwrap(URL(string: server.origin + "/pending-navigation"))))
        try await until("没进入未提交的新导航") { self.server.isHoldingResponse }
        probe.held = .cookies
        try await login(app)
        try await until("未进入清理") { self.probe.entered.contains(.cookies) }
        let marker = UUID().uuidString
        script.ok("GET /v1/config", MeSamples.json([
            "dict_version": marker, "bridge_disabled_methods": ["clipboard.read"],
        ]))
        app.config.store.onForeground()
        try await until("没有真的触发方法/令牌推送入口") { app.config.snapshotJson.contains(marker) }
        controller.refreshDeclaredMethods()
        let after = try await controller.webView.evaluateJavaScript("JSON.stringify(window.__REBATE_BRIDGE__.methods)")
            as? String
        XCTAssertEqual(after, original)
        XCTAssertTrue(journal.events("/departing").isEmpty, "文档令牌已作废时不可给旧页补发")
        XCTAssertTrue(controller.isAuthIsolated)
        server.releaseResponse()
        probe.release()
        await settled(web)
        XCTAssertFalse(controller.isAuthIsolated)
    }

    func testI7P05CurrentlyUntrustedOriginReceivesNoEvent() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        var trusted = true
        let origin = server.origin
        let controller = web.makeTrustedController(
            url: try XCTUnwrap(URL(string: origin + "/lost-trust")),
            protocolProvider: {
                let permitted = trusted
                return BridgeProtocol(trustedOrigins: [], linkPatterns: [:], shareDomains: [],
                                      extraOriginAllowed: { permitted && $0 == origin })
            }, caller: { web.callerState(fromForceUpdatePage: false) }, onClose: {}
        )
        controllers.append(controller)
        host(controller.webView)
        controller.start()
        try await loaded("/lost-trust")
        trusted = false
        try await login(app)
        await settled(web)
        XCTAssertTrue(journal.events("/lost-trust").isEmpty)
        XCTAssertEqual(journal.documents("/lost-trust").count, 1)
    }

    private func assertBridgeDenied(
        _ bridge: BridgeHost, controller: TrustedWebController,
        method: String = "ui.setNavBar", params: [String: Any] = ["title": "must-not-run"]
    ) async throws {
        let oldTitle = controller.navTitle
        let reply = expectation(description: "隔离桥必须结算拒绝，不能进入处理器")
        bridge.handle(
            raw: MeSamples.json(["v": 1, "id": UUID().uuidString, "method": method, "params": params]),
            origin: server.origin, isMainFrame: true, userGesture: true
        ) { raw in
            let object = raw.flatMap(AppWeb.object)
            let code = object?["code"] as? Int
            XCTAssertTrue([90401, 90403, 90500].contains(code ?? 0), "\(raw ?? "nil")")
            XCTAssertNil((object?["data"] as? [String: Any])?["token"])
            reply.fulfill()
        }
        await fulfillment(of: [reply], timeout: 2)
        XCTAssertEqual(controller.navTitle, oldTitle, "ui.setNavBar 处理器不得执行")
    }
}
