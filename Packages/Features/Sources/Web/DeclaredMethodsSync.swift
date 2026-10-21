import Foundation
import WebKit

/// 声明给 H5 的方法列表的同步（F-X-24 方法远程禁用，三端口径 A；TrustedWebController 持有，主线程使用）。
///
/// - 令牌：每个容器随机生成一份（`BridgeBootstrapScript.newToken`），只拼进原生注入的启动脚本与原生执行的推送脚本。
/// - 版本：列表每变一次 `version` 加一；启动脚本按最新列表重装（之后的新文档）。
/// - 文档身份：主框架每提交一次文档 `serial` 加一（含前进后退从页面缓存恢复的文档），已确认的是「哪份文档拿到了哪一版」。
///   主框架导航在途（provisional）时不推；推送前核对当前主文档是可信源，推送脚本里再核一次文档 origin，导航换了文档就不改。
/// - 补同步：列表变化、文档提交（didCommit）、加载完成（didFinish）都推一次当前版本；推送结果不是 true（脚本执行失败、更新函数
///   还不在、令牌不符）且文档与版本都没变时，隔 `retryDelayNanos` 重试，最多 `attemptLimit` 次；之后等下一次提交或加载完成。
@MainActor
final class DeclaredMethodsSync {
    static let attemptLimit = 3
    static let retryDelayNanos: UInt64 = 100_000_000

    let token = BridgeBootstrapScript.newToken()
    private(set) var methods: [String]
    private(set) var version = 0
    private var serial = 0
    private var navigating = false
    /// 当前文档已确认拿到的版本（文档换了清空）。
    private(set) var confirmedVersion: Int?

    init(methods: [String]) {
        self.methods = methods
    }

    func userScript(bridgeVersion: Int) -> WKUserScript {
        BridgeBootstrapScript.userScript(version: bridgeVersion, methods: methods, token: token)
    }

    /// 换成最新列表；变了返回 true（调用方重装启动脚本并推送）。
    func update(_ latest: [String]) -> Bool {
        guard latest != methods else { return false }
        methods = latest
        version += 1
        return true
    }

    func navigationStarted() {
        navigating = true
    }

    /// 主框架导航没有提交就结束（失败、取消）：原文档还在。
    func navigationEnded() {
        navigating = false
    }

    /// 主框架提交了一份文档（新加载、刷新或前进后退恢复）：之前的确认不算数。
    func documentCommitted() {
        navigating = false
        serial += 1
        confirmedVersion = nil
    }

    /// 把当前版本推进主框架。`trustedOrigin` 返回当前主文档的可信 origin（不是可信源为 nil，不推）。
    func push(to webView: WKWebView, trustedOrigin: @escaping @MainActor () -> String?, attempt: Int = 1) {
        guard !navigating, let origin = trustedOrigin() else { return }
        let expected = (serial: serial, version: version)
        let script = BridgeBootstrapScript.updateMethodsScript(token: token, methods: methods, origin: origin)
        webView.evaluateJavaScript(script, in: nil, in: .page) { [weak self, weak webView] result in
            MainActor.assumeIsolated {
                self?.pushed(
                    result,
                    expected: expected,
                    webView: webView,
                    trustedOrigin: trustedOrigin,
                    attempt: attempt
                )
            }
        }
    }

    /// 推送结果：true 记为当前文档已确认；否则（脚本失败、更新函数不在、令牌不符）文档与版本都没变时稍后重试。
    private func pushed(
        _ result: Result<Any, Error>,
        expected: (serial: Int, version: Int),
        webView: WKWebView?,
        trustedOrigin: @escaping @MainActor () -> String?,
        attempt: Int
    ) {
        guard expected == (serial, version) else { return }
        if case let .success(value) = result, value as? Bool == true {
            confirmedVersion = version
            return
        }
        guard attempt < Self.attemptLimit, let webView else { return }
        Task { @MainActor [weak self, weak webView] in
            try? await Task.sleep(nanoseconds: Self.retryDelayNanos)
            guard let self, let webView, expected == (serial, version), confirmedVersion != version else { return }
            push(to: webView, trustedOrigin: trustedOrigin, attempt: attempt + 1)
        }
    }
}

// MARK: - 容器接线

extension TrustedWebController {
    /// 声明给 H5 的方法列表跟上宿主此刻的 `declaredMethods`（远程禁用名单变化）：重新安装启动脚本（之后的新文档），并原地
    /// 换掉当前文档的 `__REBATE_BRIDGE__.methods`（不重载页面；只推给可信源的主文档，见 `DeclaredMethodsSync`）。列表没变时不动。
    public func refreshDeclaredMethods() {
        guard let host, methodsSync.update(host.declaredMethods) else { return }
        let contentController = webView.configuration.userContentController
        contentController.removeAllUserScripts()
        contentController.addUserScript(methodsSync.userScript(bridgeVersion: host.bridgeVersion))
        pushDeclaredMethods()
    }

    /// 把当前列表推进主文档（文档提交、加载完成时补同步）：主文档此刻不是可信源时不推。
    func pushDeclaredMethods() {
        methodsSync.push(to: webView) { [weak self] in
            guard let self, let url = webView.url, isTrustedDocument(url) else { return nil }
            return WebContainerSupport.webOrigin(of: url)
        }
    }
}
