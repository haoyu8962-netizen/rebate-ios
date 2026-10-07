import Foundation
import UIKit
import WebKit
import XCTest

/// 真实 WKWebView 测试的公共夹具（APP-04）：把 WebView 放进宿主 App 的窗口，用包内测试 HTML 加载，等待与执行脚本。
@MainActor
class WebViewTestCase: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    /// WebView 放进一个真实窗口（宿主 App 的场景里），与界面上的容器同样参与布局与事件。
    func host(_ webView: WKWebView) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        window.frame = UIScreen.main.bounds
        let root = UIViewController()
        webView.frame = root.view.bounds
        root.view.addSubview(webView)
        window.rootViewController = root
        window.isHidden = false
        self.window = window
    }

    /// 把一个界面控制器（如承载 SwiftUI 容器页的 UIHostingController）放进真实窗口。
    func hostController(_ controller: UIViewController) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        window.frame = UIScreen.main.bounds
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        self.window = window
    }

    func html(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "html"), "缺少 \(name).html")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func load(_ webView: WKWebView, html name: String, base: String) async throws {
        webView.loadHTMLString(try html(name), baseURL: URL(string: base))
        try await waitUntil(timeout: 15) { !webView.isLoading && webView.url?.absoluteString == base }
        try await waitFor(webView, "document.readyState === 'complete'", "readyState")
    }

    func loadExpectingCancel(_ webView: WKWebView, html name: String, base: String) async throws {
        webView.loadHTMLString(try html(name), baseURL: URL(string: base))
        try await waitUntil(timeout: 10) { !webView.isLoading }
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    func evaluate(_ webView: WKWebView, _ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    func waitFor(_ webView: WKWebView, _ condition: String, _ label: String) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if await (try? evaluate(webView, "Boolean(\(condition))")) as? Bool == true {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("等待超时：\(label)")
    }

    func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("等待超时")
    }
}
