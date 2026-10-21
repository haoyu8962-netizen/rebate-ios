import BridgeHost
@testable import Couli
import Foundation
import Web
import WebKit
import XCTest

extension BridgeDisabledMethodsWebTests {
    /// B12：只通过页面世界操作公开对象，不取原生脚本里的秘密令牌。
    func testB12PageCannotForgeMethodsWithoutTokenOrWithWrongToken() async throws {
        try await withSecurityPage { app, view in
            let attacks = [
                "window.__couliBridgeMethods(['clipboard.read'])",
                "window.__couliBridgeMethods(undefined, ['clipboard.read'])",
                "window.__couliBridgeMethods(null, ['clipboard.read'])",
                "window.__couliBridgeMethods('wrong-token', ['clipboard.read'])",
                "window.__couliBridgeMethods('wrong-token', [])",
            ]
            for attack in attacks {
                let result = try await view.evaluateJavaScript("""
                (() => {
                  const before = JSON.stringify(window.__REBATE_BRIDGE__.methods);
                  const result = \(attack);
                  return {rejected: result === false,
                          unchanged: JSON.stringify(window.__REBATE_BRIDGE__.methods) === before};
                })()
                """)
                let flags = try XCTUnwrap(result as? [String: Bool])
                XCTAssertEqual(flags["rejected"], true, attack)
                XCTAssertEqual(flags["unchanged"], true, attack)
                try await expectHas(view, method: "clipboard.read", expected: false)
                try await expectHas(view, method: "app.getEnv", expected: true)
            }
            try await assertPageCannotRewriteBridge(view)
            // 阳性对照：不能靠停掉所有更新来通过攻击用例；原生配置仍能双向改变当前文档。
            try await setConfig(app, disabled: [])
            try await expectHas(view, method: "clipboard.read", expected: true)
            try await setConfig(app, disabled: ["clipboard.read"])
            try await expectHas(view, method: "clipboard.read", expected: false)
            let frozen = try await view.evaluateJavaScript("Object.isFrozen(window.__REBATE_BRIDGE__.methods)")
            XCTAssertEqual(frozen as? Bool, true, "合法更新后的新数组也应冻结")
        }
    }

    func testB12RevokedOriginReceivesNoMethodsUpdateFromSameConfigDocument() async throws {
        try await withSecurityPage { app, view in
            let before = try await methodsJSON(view)
            _ = try await view.evaluateJavaScript("window.fx24Marker = 'revoked-document'")
            // 一个真实配置响应里同时撤销当前 bridge_origins、移出禁用名单。
            try await setConfig(app, disabled: [], origins: ["https://other.example.test"])
            XCTAssertEqual(AppWeb.object(app.config.snapshotJson)?["bridge_origins"] as? [String],
                           ["https://other.example.test"])
            try await expectMethodsRemain(view, equalTo: before)
            try await expectHas(view, method: "clipboard.read", expected: false)
            let marker = try await view.evaluateJavaScript("window.fx24Marker") as? String
            XCTAssertEqual(marker, "revoked-document", "不能靠销毁或重载原文档掩盖推送")

            // 原生入口也确实撤销了 origin；此处只调用无副作用的 app.getEnv。
            let value = try await view.callAsyncJavaScript(
                "return await window.__REBATE_BRIDGE__.postMessage({v:1,id:'fx24-revoked',method:'app.getEnv'});",
                arguments: [:], in: nil, contentWorld: .page
            )
            XCTAssertEqual((value as? [String: Any])?["code"] as? Int, 90403)
            // 恢复可信源并改变名单后，同一文档可以重新接收原生更新，作为推送链路的阳性对照。
            try await setConfig(app, disabled: ["app.getEnv"])
            try await expectHas(view, method: "clipboard.read", expected: true)
            try await expectHas(view, method: "app.getEnv", expected: false)
        }
    }

    func methodsJSON(_ view: WKWebView) async throws -> String {
        let value = try await view.evaluateJavaScript("JSON.stringify(window.__REBATE_BRIDGE__.methods)")
        return try XCTUnwrap(value as? String)
    }

    /// 负向观察窗口：反复走真实 WebKit IPC，防止初次读取恰好早于异步推送而假绿。
    func expectMethodsRemain(_ view: WKWebView, equalTo expected: String) async throws {
        let deadline = Date().addingTimeInterval(0.5)
        repeat {
            let actual = try await methodsJSON(view)
            XCTAssertEqual(actual, expected, "禁止更新的文档收到了名单变化")
            if actual != expected {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
    }

    private func assertPageCannotRewriteBridge(_ view: WKWebView) async throws {
        let result = try await view.evaluateJavaScript("""
        (() => {
          'use strict';
          const bridge = window.__REBATE_BRIDGE__;
          const update = window.__couliBridgeMethods;
          const methods = bridge.methods;
          const before = JSON.stringify(methods);
          const ignore = action => { try { action(); } catch (_) {} };
          ignore(() => { bridge.methods = ['clipboard.read']; });
          ignore(() => Object.defineProperty(bridge, 'methods', {value: ['clipboard.read']}));
          ignore(() => methods.push('clipboard.read'));
          ignore(() => { methods[0] = 'clipboard.read'; });
          ignore(() => { window.__couliBridgeMethods = () => true; });
          ignore(() => Object.defineProperty(window, '__couliBridgeMethods', {value: () => true}));
          ignore(() => { delete window.__couliBridgeMethods; });
          const descriptor = Object.getOwnPropertyDescriptor(window, '__couliBridgeMethods');
          return Object.isFrozen(bridge) && Object.isFrozen(bridge.methods)
              && JSON.stringify(bridge.methods) === before
              && window.__couliBridgeMethods === update
              && descriptor.writable === false && descriptor.configurable === false;
        })()
        """) as? Bool
        XCTAssertEqual(result, true, "methods、冻结数组和更新函数都不能由页面改写")
    }

    private func withSecurityPage(
        _ body: @MainActor (MeAppFixture, WKWebView) async throws -> Void
    ) async throws {
        let app = make()
        try await setConfig(app, disabled: ["clipboard.read"])
        let web = makeWeb(app)
        let controller = web.makeTrustedController(url: nil, fromForceUpdatePage: false, onClose: {})
        defer {
            controller.teardown()
            withExtendedLifetime(web) {}
        }
        let window = host(controller.webView)
        defer { window.isHidden = true }
        let view = controller.webView
        let base = try XCTUnwrap(URL(string: DisabledMethodsFixture.origin + "/fx24-security"))
        view.loadHTMLString("<!doctype html><title>F-X-24 security</title>", baseURL: base)
        await waitUntil("B12 测试文档未完成加载") { !view.isLoading && view.url == base }
        try await expectHas(view, method: "clipboard.read", expected: false)
        try await expectHas(view, method: "app.getEnv", expected: true)
        try await body(app, view)
    }
}
