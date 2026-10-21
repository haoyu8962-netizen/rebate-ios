import BridgeHost
@testable import Couli
import Foundation
import Web
import WebKit
import XCTest

extension BridgeDisabledMethodsWebTests {
    /// B9 在真实 WK 消息通道再跑一遍；用无需手势的 app.getEnv 进入同一强更等待逻辑。
    /// signedRequest 的合法体、处理器次数和真实 ApiClient 请求数由 BridgeDisabledMethodsTests 专测。
    func testB9WebKitEntryRejectionAndRemovalDuringWait() async throws {
        let app = make()
        let fixture = try DisabledMethodsFixture(client: app.client, disabled: ["app.getEnv"])
        let gate = DisabledMethodsUpdateGate()
        let controller = TrustedWebController(
            url: nil, appVersion: AppWeb.appVersion,
            hostFactory: {
                fixture.makeHost(ui: $0, update: { gate.state }, awaitUpdate: { await gate.wait() })
            },
            onOpenExternal: { _ in XCTFail("B9 测试不应外跳") }, onClose: {}
        )
        let window = host(controller.webView)
        defer {
            gate.release()
            window.isHidden = true
            controller.teardown()
        }
        let view = controller.webView
        let base = try XCTUnwrap(URL(string: DisabledMethodsFixture.origin + "/fx24-wait"))
        view.loadHTMLString("<!doctype html><title>F-X-24 wait</title>", baseURL: base)
        await waitUntil("B9 真实文档未完成加载") { !view.isLoading && view.url == base }
        _ = try await view.evaluateJavaScript("window.fx24Replies = []; true")
        try await postEnvironmentCall(view, id: "entry-denied")
        let denied = try await waitForReply(view, count: 1)
        XCTAssertEqual(denied["id"] as? String, "entry-denied")
        XCTAssertEqual(denied["code"] as? Int, 90403)
        XCTAssertEqual((denied["data"] as? [String: Any])?["reason"] as? String, "method_disabled")
        XCTAssertFalse(gate.isWaiting)
        XCTAssertTrue(fixture.services.calls.isEmpty)

        try fixture.update([])
        try await postEnvironmentCall(view, id: "wait-then-allow")
        await waitUntil("真实 WK 桥调用没有进入强更等待") { gate.isWaiting }
        XCTAssertTrue(gate.isWaiting)
        XCTAssertEqual(controller.host?.inFlightCount, 1)
        try fixture.update(["app.getEnv"])
        XCTAssertEqual(fixture.store.bridgeDisabledMethods(), ["app.getEnv"])
        try fixture.update([])
        XCTAssertTrue(fixture.store.bridgeDisabledMethods().isEmpty)
        XCTAssertTrue(gate.isWaiting)
        XCTAssertTrue(fixture.services.calls.isEmpty)
        gate.release()
        let allowed = try await waitForReply(view, count: 2)
        XCTAssertEqual(allowed["id"] as? String, "wait-then-allow")
        XCTAssertEqual(allowed["code"] as? Int, 0)
        XCTAssertEqual((allowed["data"] as? [String: Any])?["platform"] as? String, "ios")
        XCTAssertEqual(fixture.services.calls, ["app.getEnv"], "入口已拒的旧调用不得补跑")
        XCTAssertEqual(fixture.services.rejected.count, 1)
        XCTAssertEqual(controller.host?.inFlightCount, 0)
        let count = try await view.evaluateJavaScript("window.fx24Replies.length") as? Int
        XCTAssertEqual(count, 2, "每个请求只能结算一次")
    }

    private func postEnvironmentCall(_ view: WKWebView, id: String) async throws {
        _ = try await view.evaluateJavaScript("""
        window.__REBATE_BRIDGE__.postMessage({v:1,id:'\(id)',method:'app.getEnv'})
          .then(reply => window.fx24Replies.push(reply), error => window.fx24Replies.push({error: String(error)}));
        true;
        """)
    }

    private func waitForReply(_ view: WKWebView, count: Int) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let value = try await view.evaluateJavaScript("window.fx24Replies")
            let replies = try XCTUnwrap(value as? [[String: Any]])
            if replies.count >= count {
                XCTAssertEqual(replies.count, count)
                return replies[count - 1]
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        XCTFail("真实 WK 消息没有结算，第 \(count) 个响应")
        throw URLError(.timedOut)
    }
}
