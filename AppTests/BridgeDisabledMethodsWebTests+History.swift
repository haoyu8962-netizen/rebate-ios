import BridgeHost
@testable import Couli
import Foundation
import Web
import WebKit
import XCTest

extension BridgeDisabledMethodsWebTests {
    func testB12BackAndForwardCachedDocumentsReceiveLatestMethods() async throws {
        try await withHistoryPage { app, view, probe, server in
            try await loadHistoryPage(view, probe: probe, url: server.origin + "/a")
            let firstID = try await documentID(view)
            try await expectHas(view, method: "clipboard.read", expected: true)
            try await loadHistoryPage(view, probe: probe, url: server.origin + "/b")
            let secondID = try await documentID(view)
            XCTAssertNotEqual(firstID, secondID)
            try await setConfig(app, disabled: ["clipboard.read"])
            try await expectHas(view, method: "clipboard.read", expected: false)

            XCTAssertTrue(view.canGoBack)
            var finishes = probe.finishes
            _ = try XCTUnwrap(view.goBack())
            try await expectHistoryPage(view, probe: probe, path: "/a", after: finishes)
            try await assertCachedDocument(view, expectedID: firstID)
            try await expectHas(view, method: "clipboard.read", expected: false)
            // 先检查恢复时的名单，再发送配置；防止新通知替恢复回调补救而掩盖缺陷。
            try await setConfig(app, disabled: [])
            try await expectHas(view, method: "clipboard.read", expected: true)

            XCTAssertTrue(view.canGoForward)
            finishes = probe.finishes
            _ = try XCTUnwrap(view.goForward())
            try await expectHistoryPage(view, probe: probe, path: "/b", after: finishes)
            try await assertCachedDocument(view, expectedID: secondID)
            try await expectHas(view, method: "clipboard.read", expected: true)
        }
    }

    func testB12InterleavedNavigationUpdatesOnlyTheNewDocument() async throws {
        try await withHistoryPage { app, view, probe, server in
            try await loadHistoryPage(view, probe: probe, url: server.origin + "/a")
            let firstID = try await documentID(view)
            let firstMethods = try await methodsJSON(view)
            let commits = probe.commits
            let starts = probe.starts
            let finishes = probe.finishes
            server.holdResponse(for: "/b")
            view.load(URLRequest(url: try XCTUnwrap(URL(string: server.origin + "/b"))))
            await waitUntil("未进入已开始、未提交的真实导航窗口") {
                server.isHoldingResponse && probe.starts > starts
            }
            XCTAssertTrue(server.isHoldingResponse)
            XCTAssertEqual(probe.commits, commits)
            let pendingID = try await documentID(view)
            XCTAssertEqual(pendingID, firstID, "旧文档必须仍可观察")

            // 在旧文档仍活着、新文档未提交时反复改变名单。
            try await setConfig(app, disabled: ["clipboard.read"])
            try await expectMethodsRemain(view, equalTo: firstMethods)
            try await setConfig(app, disabled: ["app.getEnv"])
            try await expectMethodsRemain(view, equalTo: firstMethods)
            XCTAssertEqual(probe.commits, commits, "断言期间不得偷偷提交新文档")
            server.releaseResponse()
            try await expectHistoryPage(view, probe: probe, path: "/b", after: finishes)
            let secondID = try await documentID(view)
            XCTAssertNotEqual(secondID, firstID)
            try await expectHas(view, method: "clipboard.read", expected: true)
            try await expectHas(view, method: "app.getEnv", expected: false)

            // pagehide 是旧文档离开前的最后快照；仅查导航完成后的新页会漏掉“两个文档都收到”的错误。
            let old = try await view.evaluateJavaScript("JSON.parse(sessionStorage.getItem('fx24.hide./a'))")
            let oldDocument = try XCTUnwrap(old as? [String: Any])
            XCTAssertEqual(oldDocument["id"] as? String, firstID)
            let oldMethods = try XCTUnwrap(oldDocument["methods"] as? [String])
            let original = try XCTUnwrap(firstMethods.data(using: .utf8))
            XCTAssertEqual(oldMethods, try JSONSerialization.jsonObject(with: original) as? [String])

            // 新文档就绪后的后续更新仍能双向生效，不能沿用旧文档的身份或去重状态。
            try await setConfig(app, disabled: ["clipboard.read"])
            try await expectHas(view, method: "clipboard.read", expected: false)
            try await expectHas(view, method: "app.getEnv", expected: true)
            let finalID = try await documentID(view)
            XCTAssertEqual(finalID, secondID)
        }
    }

    private func assertCachedDocument(_ view: WKWebView, expectedID: String) async throws {
        let value = try await view.evaluateJavaScript("window.fx24Doc")
        let document = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(document["id"] as? String, expectedID, "必须恢复原 JavaScript 文档，不能重载替代")
        XCTAssertEqual(document["persisted"] as? Bool, true, "必须实际命中 WebKit 页面缓存，不能把普通返回算覆盖")
        XCTAssertEqual(document["shows"] as? Int, 2)
    }

    private func documentID(_ view: WKWebView) async throws -> String {
        let value = try await view.evaluateJavaScript("window.fx24Doc.id")
        return try XCTUnwrap(value as? String)
    }

    private func loadHistoryPage(
        _ view: WKWebView, probe: DisabledMethodsNavigationProbe, url: String
    ) async throws {
        let url = try XCTUnwrap(URL(string: url))
        let finishes = probe.finishes
        view.load(URLRequest(url: url))
        try await expectHistoryPage(view, probe: probe, path: url.path, after: finishes)
    }

    private func expectHistoryPage(
        _ view: WKWebView, probe: DisabledMethodsNavigationProbe, path: String, after finishes: Int
    ) async throws {
        await waitUntil("真实导航未完成：\(path)", timeout: 15) {
            probe.finishes > finishes && !view.isLoading && view.url?.path == path
        }
        XCTAssertGreaterThan(probe.finishes, finishes)
        let value = try await view.evaluateJavaScript("window.fx24Doc.path")
        XCTAssertEqual(value as? String, path)
    }

    private func withHistoryPage(
        _ body: @MainActor (MeAppFixture, WKWebView, DisabledMethodsNavigationProbe,
                            DisabledMethodsPageServer) async throws -> Void
    ) async throws {
        let server = try DisabledMethodsPageServer()
        try await server.start()
        defer { server.stop() }
        let origin = server.origin
        let app = make()
        try await setConfig(app, disabled: [])
        let web = makeWeb(app)
        // 沿用既有 Debug 一致性页的注入入口，仅额外允许本测试独占的回环端口。
        // AppWeb 的配置订阅、禁用读取、TrustedWebController 和启动脚本仍走生产实现。
        let controller = web.makeTrustedController(
            url: nil,
            protocolProvider: {
                BridgeProtocol(trustedOrigins: [], linkPatterns: [:], shareDomains: [],
                               extraOriginAllowed: { $0 == origin })
            },
            caller: { web.callerState(fromForceUpdatePage: false) }, onClose: {}
        )
        let probe = DisabledMethodsNavigationProbe(controller)
        controller.webView.navigationDelegate = probe
        let window = host(controller.webView)
        defer {
            window.isHidden = true
            controller.teardown()
            withExtendedLifetime((web, probe)) {}
        }
        try await body(app, controller.webView, probe, server)
    }
}
