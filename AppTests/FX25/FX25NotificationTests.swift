@testable import Couli
import CouliNetwork
import Foundation
import Web
import WebKit
import XCTest

@MainActor
final class FX25NotificationTests: FX25TestCase {
    func testP10EventExecutionMustFinishBeforeReload() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        _ = try page(web, path: "/event-completion")
        try await loaded("/event-completion")
        let view = try XCTUnwrap(controllers.last?.webView)
        // 同步 XHR 只用来扣住真实事件脚本的完成回调；由本机 HTTP 服务明确放行，无墙钟猜测。
        _ = try await view.evaluateJavaScript("""
        window.__REBATE_BRIDGE__.subscribe(event => {
          if (event.event !== 'auth.changed') return;
          const request = new XMLHttpRequest();
          request.open('GET', '/event-gate', false);
          request.send();
        }); true;
        """)
        server.holdResponse(for: "/event-gate")
        defer { server.releaseResponse() }
        let change = Task { try await login(app) }
        try await until("事件没有真正执行到旧页") { self.server.isHoldingResponse }
        XCTAssertEqual(server.requests("/event-completion"), 1, "事件脚本未返回时不能开始重载")
        XCTAssertTrue(probe.entered.isEmpty, "通知完成之前不能销毁旧文档或开始清理")
        server.releaseResponse()
        try await change.value
        await settled(web)
        try await loaded("/event-completion", count: 2)
        try assertEvent("/event-completion", loggedIn: true)
    }

    func testP07PageWithoutDeliveredDocumentDoesNotReceiveOldEvent() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let controller = try page(web, path: "/not-started", start: false)
        try await login(app)
        await settled(web)
        controller.start()
        try await loaded("/not-started")
        XCTAssertTrue(journal.events("/not-started").isEmpty)
        XCTAssertFalse(controller.isAuthIsolated)
    }

    func testP08OldDocumentLateTokenReplyDoesNotReachNewDocument() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let controller = try page(web, path: "/late-reply")
        try await loaded("/late-reply")
        script.on("POST /v1/auth/h5-token", .hold)
        _ = try await controller.webView.evaluateJavaScript("""
        window.__REBATE_BRIDGE__.postMessage({v:1,id:'old-token',method:'auth.getH5Token'})
          .then(reply => window.fx25.send('reply', {reply}), () => window.fx25.send('rejected'));
        true;
        """)
        try await until("旧桥请求未进入真实处理器") { !WalletStubProtocol.heldIds.isEmpty }
        let request = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        let oldDocument = try XCTUnwrap(journal.documents("/late-reply").first?.document)
        try await login(app)
        await settled(web)
        try await loaded("/late-reply", count: 2)
        let answer = MeSamples.json([
            "token": "old-user-a-token", "expire_at": "2099-01-01T00:00:00Z", "scope": "standard",
        ])
        WalletStubProtocol.release(request, with: .envelope(code: 0, data: answer, headers: [:]))
        await settled(web)
        for entry in journal.entries where entry.kind == "reply" {
            let reply = try XCTUnwrap(entry.body["reply"] as? [String: Any])
            XCTAssertNotEqual(reply["code"] as? Int, 0, "旧文档迟到成功不交付")
            XCTAssertEqual(entry.document, oldDocument, "旧回复不能投给新页")
        }
        XCTAssertEqual(controller.host?.inFlightCount, 0)
    }

    func testI7GuestLoginAndLogoutAreTwoDistinctChanges() async throws {
        try await prepare()
        let app = make(account: nil)
        let web = makeWeb(app)
        _ = try page(web, path: "/guest-login")
        try await loaded("/guest-login")
        try await login(app)
        await settled(web)
        try await loaded("/guest-login", count: 2)
        try assertEvent("/guest-login", loggedIn: true)
        app.client.signOut()
        await settled(web)
        try await loaded("/guest-login", count: 3)
        let events = journal.events("/guest-login")
        XCTAssertEqual(events.count, 2)
        let payloads = events.compactMap { ($0.body["event"] as? [String: Any])?["data"] as? [String: Any] }
        XCTAssertEqual(payloads.compactMap { $0["logged_in"] as? Bool }, [true, false])
        XCTAssertTrue(payloads.allSatisfy { Set($0.keys) == ["logged_in"] })
    }

    func testD11RestrictedScopeRefreshDoesNotChangeIdentity() async throws {
        try await prepare()
        script.on("POST /v1/auth/refresh", .hold)
        let app = make(scope: "deletion_only")
        let old = try XCTUnwrap(app.tokens.readSession())
        let web = makeWeb(app)
        _ = try page(web, path: "/scope-only")
        try await loaded("/scope-only")
        let read = Task { await app.client.send(ApiCall(operationId: "getMe")) }
        try await until("受限会话没有进入刷新") { !WalletStubProtocol.heldIds.isEmpty }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: """
        {"access_token":"scope-at","refresh_token":"scope-rt","session_scope":"full","expires_in":7200}
        """, headers: [:]))
        let result = await read.value
        guard case .success = result else { return XCTFail("刷新未成功：\(result)") }
        let new = try XCTUnwrap(app.tokens.readSession())
        XCTAssertEqual(new.loginEpoch, old.loginEpoch)
        XCTAssertEqual(new.account, old.account)
        XCTAssertNotEqual(new.scope, old.scope)
        XCTAssertNotEqual(new.access, old.access)
        XCTAssertNotEqual(new.refresh, old.refresh)
        await settled(web)
        XCTAssertTrue(journal.events("/scope-only").isEmpty)
        XCTAssertEqual(journal.documents("/scope-only").count, 1)
        XCTAssertTrue(probe.entered.isEmpty)
    }
}
