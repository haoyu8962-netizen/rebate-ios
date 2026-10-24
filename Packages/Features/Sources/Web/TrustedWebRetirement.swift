import Foundation
import WebKit

/// 旧文档退役（F-X-25 评审 r1 S0-01、r2 S1-R2-01）：退役的 WKWebView 摘掉桥与脚本，只放行主框架空白页并加载它；空白页提交
/// （`didCommit`）即旧文档已卸载——卸载事件（visibilitychange / pagehide / unload）在提交之前跑完，之后旧文档不再执行任何脚本、
/// 定时器与 IndexedDB 事务；WebContent 进程终止同样算卸载。进入往返缓存的旧页面处于挂起状态，退役代理拒绝一切返回导航。
/// 网络进程里活过文档的 keepalive / sendBeacon 请求不归这里管：它们的迟到写入只会落进已经换下的旧 store（见协调器换 store）。
/// 退役对象在卸载确认之前**强持有** WebView（容器 teardown、界面释放都不会让页面在没人等的情况下关闭），确认后释放。
/// 空白页加载被打断（旧文档里 `window.stop()`、发起导航等）时重新发起，最多 `maxAttempts` 次；等待方再补发一次。
@MainActor
final class TrustedWebRetirement: NSObject, WKNavigationDelegate {
    static let maxAttempts = 3

    private(set) var view: WKWebView?
    private(set) var unloaded = false
    private var attempts = 0
    private var waiters: [OnceGate<Bool>] = []

    private init(_ view: WKWebView) {
        self.view = view
    }

    /// 退役一个 WebView。`hadDocument` 为 false（从没加载过）时直接算已卸载。`detach` 为 false 时不移出界面（teardown：
    /// 界面随路由出栈自行移除，避免出栈动画里先变白）。
    static func retire(_ view: WKWebView, hadDocument: Bool, detach: Bool = true) -> TrustedWebRetirement {
        let retirement = TrustedWebRetirement(view)
        view.navigationDelegate = retirement
        view.uiDelegate = nil
        view.stopLoading()
        let content = view.configuration.userContentController
        content.removeAllScriptMessageHandlers()
        content.removeAllUserScripts()
        if detach {
            view.removeFromSuperview()
        }
        if hadDocument {
            retirement.loadBlank()
        } else {
            retirement.markUnloaded()
        }
        return retirement
    }

    private func loadBlank() {
        guard !unloaded, let view, attempts < Self.maxAttempts else { return }
        attempts += 1
        view.loadHTMLString("", baseURL: nil)
    }

    /// 等旧文档卸载；超时为 false（调用方按清理失败处理）。还没卸载的先补发一次空白页（之前的加载可能已被打断）。
    func waitUnloaded(timeout: TimeInterval) async -> Bool {
        if unloaded {
            return true
        }
        if attempts >= Self.maxAttempts {
            attempts = Self.maxAttempts - 1
        }
        loadBlank()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = OnceGate<Bool>(continuation)
            waiters.append(gate)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                gate.resume(false)
            }
        }
    }

    private func markUnloaded() {
        guard !unloaded else { return }
        unloaded = true
        view = nil
        let resumed = waiters
        waiters = []
        for gate in resumed {
            gate.resume(true)
        }
    }

    func webView(
        _: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let blank = action.targetFrame?.isMainFrame == true && WebContainerSupport.isBlankDocument(action.request.url)
            && action.navigationType != .backForward
        decisionHandler(blank ? .allow : .cancel)
    }

    func webView(
        _: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(WebContainerSupport.isBlankDocument(response.response.url) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didCommit _: WKNavigation!) {
        if WebContainerSupport.isBlankDocument(webView.url) {
            markUnloaded()
        }
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        if WebContainerSupport.isBlankDocument(webView.url) {
            markUnloaded()
        }
    }

    /// 空白页加载被打断：重新发起（评审 r2 S2-R2-02）。
    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
        loadBlank()
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        loadBlank()
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        markUnloaded()
    }
}
