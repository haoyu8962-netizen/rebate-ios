import Foundation
import Web
import WebKit

/// 只记录真实 WebKit 导航阶段，所有策略和生命周期回调继续交给生产容器；不手动制造产品回调。
@MainActor
final class DisabledMethodsNavigationProbe: NSObject, WKNavigationDelegate {
    let controller: TrustedWebController
    private(set) var starts = 0
    private(set) var commits = 0
    private(set) var finishes = 0

    init(_ controller: TrustedWebController) {
        self.controller = controller
    }

    func webView(
        _ view: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        controller.webView(view, decidePolicyFor: action, decisionHandler: decisionHandler)
    }

    func webView(
        _ view: WKWebView, decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        controller.webView(view, decidePolicyFor: response, decisionHandler: decisionHandler)
    }

    func webView(
        _ view: WKWebView, respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await controller.webView(view, respondTo: challenge)
    }

    func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        starts += 1
        controller.webView(view, didStartProvisionalNavigation: navigation)
    }

    func webView(_ view: WKWebView, didCommit navigation: WKNavigation!) {
        commits += 1
        controller.webView(view, didCommit: navigation)
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        controller.webView(view, didFinish: navigation)
        finishes += 1
    }

    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        controller.webView(view, didFailProvisionalNavigation: navigation, withError: error)
    }

    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        controller.webView(view, didFail: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
        controller.webViewWebContentProcessDidTerminate(view)
    }
}
