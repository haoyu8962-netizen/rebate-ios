import BridgeHost
import ClientCore
@testable import Couli
import Foundation
import UIKit
import Web
import WebKit
import XCTest

/// F-X-24：通过生产 AppWeb 装配和真实 WKWebView 检查 H5 has() 的输入 methods，防止只改宿主却漏接配置或脚本。
/// 本仓库不包含 H5 SDK；这里读取 SDK 使用的 __REBATE_BRIDGE__.methods，不另造 Swift has()。
@MainActor
final class BridgeDisabledMethodsWebTests: MeTestCase {
    func testB2B5B6CapabilityListUpdatesOnExistingPageAfterConfigRefresh() async throws {
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
        let base = try XCTUnwrap(URL(string: DisabledMethodsFixture.origin + "/fx24"))
        view.loadHTMLString("<!doctype html><title>F-X-24</title>", baseURL: base)
        await waitUntil("测试文档未完成加载") { !view.isLoading && view.url == base }
        try await expectHas(view, method: "clipboard.read", expected: false)
        try await expectHas(view, method: "app.getEnv", expected: true)
        _ = try await view.evaluateJavaScript("window.fx24DocumentMarker = 'same-document'")

        // B5：当前文档和控制器不重建，配置刷新后 has 的输入也必须恢复。
        try await setConfig(app, disabled: [])
        try await expectHas(view, method: "clipboard.read", expected: true)
        // B6：未知但合法的方法名不能禁掉已有能力，也不能被加入声明的方法列表。
        try await setConfig(app, disabled: ["unknown.method"])
        try await expectHas(view, method: "clipboard.read", expected: true)
        try await expectHas(view, method: "unknown.method", expected: false)
        // 从未禁用到禁用：已打开页面不能继续暴露过期的 methods。
        try await setConfig(app, disabled: ["clipboard.read"])
        try await expectHas(view, method: "clipboard.read", expected: false)
        let marker = try await view.evaluateJavaScript("window.fx24DocumentMarker") as? String
        XCTAssertEqual(marker, "same-document", "配置刷新不得靠重载页面达成")
    }

    /// 只改测试注入而漏掉 AppWeb 生产装配也会红；安全的 app.getEnv 经过实际 WK 消息通道与准入。
    func testProductionAppWebRejectsDisabledMethodThroughWebKitMessageChannel() async throws {
        let app = make()
        try await setConfig(app, disabled: ["app.getEnv"])
        let web = makeWeb(app)
        let controller = web.makeTrustedController(url: nil, fromForceUpdatePage: false, onClose: {})
        defer {
            controller.teardown()
            withExtendedLifetime(web) {}
        }
        let window = host(controller.webView)
        defer { window.isHidden = true }
        let view = controller.webView
        let base = try XCTUnwrap(URL(string: DisabledMethodsFixture.origin + "/fx24"))
        view.loadHTMLString("<!doctype html><title>F-X-24</title>", baseURL: base)
        await waitUntil("测试文档未完成加载") { !view.isLoading && view.url == base }
        let value = try await view.callAsyncJavaScript(
            "return await window.__REBATE_BRIDGE__.postMessage({v:1,id:'fx24-web',method:'app.getEnv'});",
            arguments: [:], in: nil, contentWorld: .page
        )
        let reply = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(reply["code"] as? Int, 90403)
        XCTAssertEqual((reply["data"] as? [String: Any])?["reason"] as? String, "method_disabled")
    }

    func setConfig(
        _ app: MeAppFixture, disabled: [String], origins: [String] = [DisabledMethodsFixture.origin]
    ) async throws {
        let marker = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: [
            "dict_version": marker, "bridge_origins": origins,
            "bridge_disabled_methods": disabled,
        ])
        script.ok("GET /v1/config", try XCTUnwrap(String(bytes: data, encoding: .utf8)))
        app.config.store.onForeground()
        await waitUntil("新配置没有成为生效配置") { app.config.snapshotJson.contains(marker) }
    }

    func makeWeb(_ app: MeAppFixture) -> AppWeb {
        let directory = MeAppFixture.localDirectory(suiteName)
        let tracker = AppTracker(
            privacy: app.routing.privacy, update: app.update, network: app.network,
            environmentReady: { true }, credentialsReadable: { app.runner.credentialsReadable },
            file: ClientFile(name: "fx24-tracker.json", baseDirectory: directory),
            withdrawalRegistry: app.withdrawal, environmentRegistry: app.environmentSwitch
        )
        return AppWeb(
            config: app.config, network: app.network, routing: app.routing, privacy: app.routing.privacy,
            update: app.update, tracker: tracker,
            permissions: AppPermissions(file: ClientFile(name: "fx24-permissions.json", baseDirectory: directory)),
            withdrawalRegistry: app.withdrawal, environmentRegistry: app.environmentSwitch
        )
    }

    func host(_ view: WKWebView) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        let root = UIViewController()
        window.frame = UIScreen.main.bounds
        window.rootViewController = root
        view.frame = root.view.bounds
        root.view.addSubview(view)
        window.isHidden = false
        return window
    }

    func expectHas(_ view: WKWebView, method: String, expected: Bool) async throws {
        let expression = "window.__REBATE_BRIDGE__ ? window.__REBATE_BRIDGE__.methods.indexOf('\(method)') >= 0 : null"
        let deadline = Date().addingTimeInterval(5)
        var actual: Bool?
        repeat {
            actual = try await view.evaluateJavaScript(expression) as? Bool
            if actual == expected {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        XCTAssertEqual(actual, expected, "has(\(method)) 的真实网页能力列表")
    }
}
