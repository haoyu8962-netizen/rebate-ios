import BridgeHost
import Foundation
import WebKit

// MARK: - 传输层

extension TrustedWebController: WKScriptMessageHandlerWithReply {
    public func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard message.webView === webView, let raw = message.body as? String, let host else {
            replyHandler(nil, "invalid")
            return
        }
        // 框架身份只取 WebKit 给出的 frameInfo（不看页面自报的任何字段，不按 URL 比较）。
        let frame = message.frameInfo
        host.handle(
            raw: raw,
            origin: WebContainerSupport.origin(of: frame.securityOrigin),
            isMainFrame: frame.isMainFrame,
            userGesture: tap.hasRecentTap
        ) { reply in
            replyHandler(reply, reply == nil ? "invalid" : nil)
        }
    }
}
