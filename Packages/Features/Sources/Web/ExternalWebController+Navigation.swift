import BridgeHost
import Foundation
import Generated
import WebKit

// MARK: - 导航

extension ExternalWebController: WKNavigationDelegate, WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let isNewWindow = action.targetFrame == nil
        let isMainFrame = action.targetFrame?.isMainFrame ?? false
        let frame: TrackerEvents.ExternalPageNavHost
            .FrameValue = isNewWindow ? .newWindow : isMainFrame ? .main : .subframe
        let url = action.request.url
        let finish = { [weak self] (policy: NavigationTrace.Policy) in
            self?.record(url: url, type: action.navigationType, frame: frame, policy: policy)
            decisionHandler(policy == .allow ? .allow : .cancel)
        }
        guard !tornDown else {
            finish(.cancel)
            return
        }
        if action.shouldPerformDownload {
            finish(.cancel)
            reportDownload(frame: TrackerEvents.ExternalPageBlockedNav.FrameValue(rawValue: frame.rawValue) ?? .main)
            return
        }
        if frame == .subframe, WebContainerSupport.isBlankDocument(url) {
            finish(.allow)
            return
        }
        // 统一入口每次都核对生效规则表能否用于阻断（三端共性第 27 条）：运行中变空或损坏（解析不了、回落到空的包内快照）
        // 时取消加载并显示降级页，不把「没有匹配」当放行。
        let table = deps.policy.table(json: deps.linkPatterns())
        guard !table.isEmpty else {
            finish(.cancel)
            degradeForMissingRules()
            return
        }
        // 容器自己以程序方式重新发起的那次导航（见下）：照常判定，但不再重发、不重复抽样。
        let isReissue = consumeReissue(url, action)
        let allowed = decide(
            url: url?.absoluteString ?? "", frame: frame, isMainFrame: isMainFrame, isNewWindow: isNewWindow,
            table: table, sample: !isReissue
        )
        guard allowed else {
            finish(.cancel)
            return
        }
        if isNewWindow || (isMainFrame && !isReissue && needsProgrammaticLoad(action, url: url, in: webView)) {
            // 不让 WebKit 按通用链接（Universal Links）拉起其他 App（三端共性第 26 条，03 §5.1）：带用户手势的跨域主框架
            // 导航放行时，WebKit 会先尝试交给登记了该域名的 App。这里先取消，再用 load(URLRequest) 以程序方式发起——
            // API 发起的加载不尝试通用链接，它之后的服务器重定向沿用同一策略。新窗口请求同样在当前容器里这样打开（03 §5.1）。
            finish(.reissue)
            reissue(action.request, in: webView)
        } else {
            finish(.allow)
        }
    }

    public func webView(
        _: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard WebContainerSupport.isDownload(response) else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        reportDownload(frame: response.isForMainFrame ? .main : .subframe)
    }

    public func webView(
        _: WKWebView,
        respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (WebContainerSupport.disposition(for: challenge), nil)
    }

    public func webView(_ webView: WKWebView, didCommit _: WKNavigation!) {
        // 标题栏固定显示当前主框架页面的主机名（03 §5.1）。
        host = webView.url?.host
        canGoBack = webView.canGoBack
        loadFailed = false
    }

    public func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        canGoBack = webView.canGoBack
    }

    public func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        if !WebContainerSupport.isCancellation(error) {
            loadFailed = true
        }
    }

    public func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        if !WebContainerSupport.isCancellation(error) {
            loadFailed = true
        }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    public func webView(
        _: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for _: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        // 新窗口请求已在 decidePolicyFor（targetFrame == nil）里判定，不创建新 WebView。
        nil
    }
}

extension ExternalWebController {
    /// 标题栏的主机名与返回按钮跟上 SPA 页内跳转（pushState、replaceState、片段导航、历史返回不触发 didCommit；
    /// 三端共性第 48 条）：KVO 监听 WKWebView 的 url 与 canGoBack。
    func observePageState() {
        // 只在没有文档加载进行中时取 url（同文档跳转）；文档加载由 didCommit 更新，不显示未提交的临时地址。
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            let current = view.isLoading ? nil : view.url?.host
            MainActor.assumeIsolated {
                if let current, self?.host != current {
                    self?.host = current
                }
            }
        }
        backObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
            let value = view.canGoBack
            MainActor.assumeIsolated {
                if self?.canGoBack != value {
                    self?.canGoBack = value
                }
            }
        }
    }
}
