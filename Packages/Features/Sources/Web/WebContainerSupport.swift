import Foundation
import UIKit
import WebKit

/// 两类容器共用的小工具（03 §5.1「两类容器的共同规则」、§4.8 CSB-02 / CSB-03）。WebView 只在本模块的两个容器封装里创建。
enum WebContainerSupport {
    /// UA：完整保留系统默认 UA，只在末尾追加 ` Couli/<版本号>`（03 §5.1）。`applicationNameForUserAgent` 会替换 UA 末尾的
    /// 默认应用名（iOS 上是 `Mobile/…`），所以先取出默认值再追加，不删不改原有内容。
    static func applyUserAgent(_ configuration: WKWebViewConfiguration, appVersion: String) {
        let base = WKWebViewConfiguration().applicationNameForUserAgent ?? ""
        let suffix = "Couli/" + appVersion
        configuration.applicationNameForUserAgent = base.isEmpty ? suffix : base + " " + suffix
    }

    /// 两类容器共同的设置：不自动开窗、不识别电话 / 地址链接、只升级已知 HSTS 主机，不允许内嵌的 Web 检查器之外的任何放宽。
    static func applyCommonSettings(_ configuration: WKWebViewConfiguration) {
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.dataDetectorTypes = []
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.allowsInlineMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    }

    /// 证书与认证质询（03 §4.8 CSB-01 / CSB-02）：服务器证书只走系统默认校验（失败即取消加载，进原生错误页，不提供继续访问）；
    /// 客户端证书、HTTP 认证一律取消。
    static func disposition(for challenge: URLAuthenticationChallenge) -> URLSession.AuthChallengeDisposition {
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling
            : .cancelAuthenticationChallenge
    }

    /// 被策略取消或被新导航打断的失败不算加载失败（不显示错误页）。
    static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
            return true
        }
        // WebKitErrorFrameLoadInterruptedByPolicyChange（策略取消）
        return error.domain == "WebKitErrorDomain" && error.code == 102
    }

    /// 响应是附件、或容器无法渲染：一律不在 App 内下载（03 §5.1）。
    static func isDownload(_ response: WKNavigationResponse) -> Bool {
        if !response.canShowMIMEType {
            return true
        }
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        return disposition?.lowercased().hasPrefix("attachment") ?? false
    }

    /// 子框架的空白文档（about:blank、about:srcdoc）：不是去往某个地址的导航。
    static func isBlankDocument(_ url: URL?) -> Bool {
        guard let url else { return true }
        let text = url.absoluteString.lowercased()
        return text == "about:blank" || text == "about:srcdoc"
    }

    /// 文档地址的 origin（`scheme://host[:port]`，主机转小写；端口原样保留，由协议层按 443 规范化）。
    static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// 浏览器口径的 origin（与页面里 `location.origin` 相同：默认端口 https 443、http 80 省略）。
    static func webOrigin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        let defaultPort = (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80)
        guard let port = url.port, !defaultPort else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }

    /// 调用方框架的 origin（WKSecurityOrigin；不透明 origin 的 protocol / host 为空 → "null"）。
    static func origin(of security: WKSecurityOrigin) -> String {
        let scheme = security.protocol.lowercased()
        let host = security.host.lowercased()
        guard !scheme.isEmpty, !host.isEmpty else { return "null" }
        return security.port == 0 ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(security.port)"
    }

    /// 只放行 https 的内容规则（禁止混合内容，CSB-03）：主框架、子框架里的 http / ws 子资源一律不加载。
    /// 规则列表不改页面内容，只拦加载（与导航判定同属容器层面）。编译失败时回调 nil，调用方不加载页面（宁可不开）。
    @MainActor
    static func httpsOnlyRules(_ completion: @escaping @MainActor (WKContentRuleList?) -> Void) {
        let rules = #"[{"trigger":{"url-filter":"^http:"},"action":{"type":"block"}},"#
            + #"{"trigger":{"url-filter":"^ws:"},"action":{"type":"block"}}]"#
        guard let store = WKContentRuleListStore.default() else {
            completion(nil)
            return
        }
        store.compileContentRuleList(forIdentifier: "couli.https-only.v1", encodedContentRuleList: rules) { list, _ in
            MainActor.assumeIsolated {
                completion(list)
            }
        }
    }
}

/// 用户手势（03 §5.3 L2 与 gesture_required；APP-04 三端共性第 5 条）：只把系统识别出的有效点击记为手势——UITapGestureRecognizer
/// 只在按下后在容差内抬起时识别，按下、滑动、长按、取消、多指都不算。时刻用单调时钟（systemUptime），主框架换文档时清除。
/// 页面脚本伪造不了（不看任何页面事件）。识别器不拦截触摸，与 WebView 自己的手势同时识别。
@MainActor
final class WebTapRecorder: NSObject, UIGestureRecognizerDelegate {
    static let window: TimeInterval = 1

    private var lastTap: TimeInterval?
    private let clock: () -> TimeInterval

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    func attach(to view: UIView) {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        view.addGestureRecognizer(recognizer)
    }

    /// 最近 1 秒内有有效点击。
    var hasRecentTap: Bool {
        guard let lastTap else { return false }
        let elapsed = clock() - lastTap
        return elapsed >= 0 && elapsed <= Self.window
    }

    func reset() {
        lastTap = nil
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        lastTap = clock()
    }

    nonisolated func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

/// WKScriptMessageHandlerWithReply 的弱代理：WKUserContentController 强引用处理器，直接登记容器会成环。
final class WeakScriptHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: (any WKScriptMessageHandlerWithReply)?

    init(_ target: any WKScriptMessageHandlerWithReply) {
        self.target = target
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let target else {
            replyHandler(nil, "closed")
            return
        }
        target.userContentController(controller, didReceive: message, replyHandler: replyHandler)
    }
}
