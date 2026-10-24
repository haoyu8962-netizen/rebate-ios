import BridgeHost
import Foundation
import UIKit
import WebKit

// MARK: - 切号（F-X-25；由 TrustedWebAuthCoordinator 驱动，口径见协调器说明）

extension TrustedWebController {
    static let authChangedEvent = "auth.changed"

    /// A 的投递资格（在判定的同一步里、隔离之前取）：当前主框架已提交文档、没有在途主框架导航（导航开始即视为旧文档在离开，
    /// P12）、当前主框架是可信源。返回该文档的编号，之后投递时核对仍是同一份文档；不符合为 nil。
    func authEventDocument() -> Int? {
        // 已在隔离中的文档（上一次变化还没恢复）不再投递（评审 r1 S2-06）：它只会被换成新文档。
        guard !isTornDown, !isAuthIsolated, documentSerial > 0, !methodsSync.navigating,
              let url = webView.url, isTrustedDocument(url)
        else { return nil }
        return documentSerial
    }

    /// 向判定时取下的那份文档发 `auth.changed`（载荷只有 logged_in）。只发主框架、文档 origin 仍是投递时核对过的可信源；
    /// 隔离不影响这一次受控投递（I7）。`completion` 在页面脚本执行完成（含页面监听器同步执行完）或不投递时调用，恰好一次。
    func deliverAuthChanged(loggedIn: Bool, document: Int, completion: @escaping @MainActor () -> Void) {
        guard !isTornDown, document == documentSerial, !methodsSync.navigating,
              let url = webView.url, isTrustedDocument(url),
              let origin = WebContainerSupport.webOrigin(of: url),
              let body = BridgeProtocol.event(name: Self.authChangedEvent, data: ["logged_in": loggedIn]),
              let literal = Self.jsStringLiteral(body), let originLiteral = Self.jsStringLiteral(origin)
        else {
            completion()
            return
        }
        let receive = BridgeBootstrapScript.receiveFunction
        let script = """
        (function () {
          if (window.top !== window || window.location.origin !== \(originLiteral)) { return false; }
          var receive = window.\(receive);
          if (typeof receive !== 'function') { return false; }
          receive(\(literal));
          return true;
        })();
        """
        webView.evaluateJavaScript(script, in: nil, in: .page) { _ in
            MainActor.assumeIsolated {
                completion()
            }
        }
    }

    /// 隔离（I1，判定的同一个同步步骤里对全部容器调用）：宿主 dispose（之后桥调用一律 90500、在途调用作废）、停掉在途导航、
    /// 清手势；记下恢复地址（此刻已提交文档的地址）。恢复前一定换新 WebView（新宿主、新令牌）。
    func authIsolate() {
        guard !isTornDown else { return }
        if !isAuthIsolated {
            restoreURL = documentSerial > 0 ? committedURL : nil
        }
        isAuthIsolated = true
        needsFreshView = true
        awaitingAuthCommit = false
        host?.dispose()
        tap.reset()
        webView.stopLoading()
    }

    /// 清理失败：显示可重试的错误页，保持隔离。
    func authFailed() {
        guard isAuthIsolated else { return }
        loadFailed = true
        awaitingAuthCommit = false
    }

    func authRetrying() {
        loadFailed = false
    }

    /// 旧文档退役（第一遍清理之后、第二遍之前）：有过加载的容器换上新的 WKWebView，旧 WebView 摘掉桥与脚本、只放行空白页并
    /// 加载空白页（旧文档的脚本随之停止，不能再写存储），移出界面。
    func authRetireDocument() {
        guard !isTornDown, isAuthIsolated, loadIssued else { return }
        swapToFreshView()
    }

    /// 清理全部成功：解除隔离（只对新 WebView 里的新文档），重新加载当前入口——隔离时已提交文档的地址；当时还没有文档、但已要求
    /// 开始加载的按初始地址加载；从没开始加载的等 `start()`。当前入口已不是可信源的不拉回，显示错误页。
    func authRestore() {
        guard !isTornDown, isAuthIsolated else { return }
        if needsFreshView {
            swapToFreshView()
        }
        isAuthIsolated = false
        loadFailed = false
        let target = restoreURL
        restoreURL = nil
        guard started else { return }
        guard let target else {
            awaitingAuthCommit = true
            loadInitial()
            if loadFailed {
                awaitingAuthCommit = false
            }
            return
        }
        guard isTrustedDocument(target), !AuthPages.isAuthPage(target.absoluteString) else {
            loadFailed = true
            return
        }
        awaitingAuthCommit = true
        load(target) { [weak self] in
            self?.authCommitEnded()
        }
    }

    /// 恢复的加载提交了新文档、失败或取消。
    func authCommitEnded() {
        guard awaitingAuthCommit else { return }
        awaitingAuthCommit = false
        auth?.commitSettled()
    }

    /// 换上新的 WKWebView：可信专用存储、新宿主（新世代的桥绑定）、新方法列表令牌与启动脚本；在界面里占旧 WebView 的位置。
    private func swapToFreshView() {
        let old = webView
        let fresh = Self.makeWebView(appVersion: appVersion, dataStore: dataStore)
        if let superview = old.superview {
            fresh.frame = old.frame
            fresh.autoresizingMask = old.autoresizingMask
            superview.insertSubview(fresh, aboveSubview: old)
        }
        auth?.trackRetirement(TrustedWebRetirement.retire(old, hadDocument: loadIssued))
        loadIssued = false
        documentSerial = 0
        committedURL = nil
        canGoBack = false
        webView = fresh
        bind(fresh)
        needsFreshView = false
        auth?.dependencies.configureWebView(fresh)
    }
}
