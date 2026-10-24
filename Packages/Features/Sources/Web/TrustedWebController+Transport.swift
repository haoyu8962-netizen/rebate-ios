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
        guard message.webView === webView, let raw = message.body as? String else {
            replyHandler(nil, "invalid")
            return
        }
        // 先按会话世代补一次切号核对（世代没变不读凭据）：新会话已保存、协调器还没收到通知时，在这一步同步隔离（F-X-25 I1）。
        auth?.catchUp()
        guard !isAuthIsolated, let host else {
            // 隔离中：不进宿主、不执行任何处理器，按 90500 结束（没有合法 id 的无法配对）。
            let id = BridgeProtocol.parseStructure(raw: raw).id
            let reply = id.map { BridgeProtocol.response(id: $0, code: BridgeCode.nativeError) }
            replyHandler(reply, reply == nil ? "invalid" : nil)
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
