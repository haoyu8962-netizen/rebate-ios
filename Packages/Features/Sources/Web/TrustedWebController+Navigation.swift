import BridgeHost
import Foundation
import WebKit

// MARK: - 导航

extension TrustedWebController: WKNavigationDelegate, WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // 退役的旧 WebView、切号隔离中的一切导航（含页面脚本跳转、后退、直接 load、新窗口）一律取消（F-X-25 I1）。
        guard webView === self.webView, !isAuthIsolated else {
            decisionHandler(.cancel)
            return
        }
        guard !action.shouldPerformDownload, let url = action.request.url else {
            decisionHandler(.cancel)
            return
        }
        let isNewWindow = action.targetFrame == nil
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        // 授权与登录页不进容器（03 §5.1；三端共性第 16 条）：初始地址与每一次文档导航（含子框架）都查，不转交第三方页容器。
        if !WebContainerSupport.isBlankDocument(url), AuthPages.isAuthPage(url.absoluteString) {
            decisionHandler(.cancel)
            return
        }
        if !isMainFrame {
            // 子框架按目标地址的 origin 判（编排者裁定：非主框架且目标属于可信 origin → .cancel）。调用桥时的框架身份另由
            // WKScriptMessage.frameInfo 判，不靠这里。
            let allowed = Self.allowsSubframe(url, isTrustedOrigin: isTrustedDocument(url))
            if !allowed {
                blockedSubframeCount += 1
            }
            decisionHandler(allowed ? .allow : .cancel)
            return
        }
        if isTrustedDocument(url) {
            if isNewWindow {
                // 新窗口请求在当前容器里打开（不另开窗口）。
                decisionHandler(.cancel)
                webView.load(action.request)
            } else {
                decisionHandler(.allow)
            }
            return
        }
        decisionHandler(.cancel)
        if url.scheme?.lowercased() == "https" {
            onOpenExternal(url)
        }
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        // 隔离之前已放行、隔离时仍在途的导航，响应到达时同样取消，不提交新文档。
        guard webView === self.webView, !isAuthIsolated else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(WebContainerSupport.isDownload(response) ? .cancel : .allow)
    }

    public func webView(
        _: WKWebView,
        respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (WebContainerSupport.disposition(for: challenge), nil)
    }

    /// 主框架开始导航（WKNavigationDelegate 的这个回调只报主框架，不含同文档内的片段 / history 跳转）：立即作废旧页面的
    /// 在途桥调用，不等新文档提交——新页面加载很慢或失败时，旧调用也不能再发请求或继续权限流程（三端共性第 29 条）。
    /// 提交新文档时（didCommit）再作废一次，保持新旧文档隔离。
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        guard webView === self.webView else { return }
        methodsSync.navigationStarted()
        loadFailed = false
        tap.reset()
        host?.invalidate()
    }

    /// 提交新文档（含前进后退从页面缓存恢复）、加载完成：按当前版本补同步方法列表（F-X-24）。
    public func webView(_ webView: WKWebView, didCommit _: WKNavigation!) {
        guard webView === self.webView else { return }
        mainFrameChanged()
        methodsSync.documentCommitted()
        documentSerial += 1
        committedURL = webView.url
        authCommitEnded()
        pushDeclaredMethods()
    }

    public func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        guard webView === self.webView else { return }
        canGoBack = webView.canGoBack
        pushDeclaredMethods()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        methodsSync.navigationEnded()
        if !WebContainerSupport.isCancellation(error) {
            loadFailed = true
        }
        authCommitEnded()
    }

    public func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        if !WebContainerSupport.isCancellation(error) {
            loadFailed = true
        }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        mainFrameChanged()
        // 切号隔离中不重新加载旧文档（等清理成功后按新文档恢复）。
        guard !isAuthIsolated else { return }
        webView.reload()
    }

    public func webView(
        _: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for _: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        // 新窗口请求已在 decidePolicyFor（targetFrame == nil）里按主框架判定，这里不创建新 WebView。
        nil
    }
}
