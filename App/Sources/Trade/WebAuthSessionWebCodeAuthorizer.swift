import AuthenticationServices
import Foundation
import Trade

/// 一次已启动的授权会话（系统实现包着 ASWebAuthenticationSession 并强引用到完成为止；测试用假实现）。
@MainActor
protocol WebAuthSessionHandle: AnyObject {
    /// 取消会话。系统会话被取消后仍会以 canceledLogin 回调一次 completion，授权器只 resume 一次。
    func cancel()
}

/// 授权会话端口（可注入，测试里不碰系统会话）：建一个会话并 start。
@MainActor
protocol WebAuthSessionLauncher: AnyObject {
    /// 用 `url` 建会话，回跳 scheme 为 `callbackURLScheme`，`prefersEphemeralWebBrowserSession` 原样设给会话，然后 start。
    /// - 返回：start 成功 → 会话句柄（completion 之后恰好回调一次）；start 返回 false（例如没有可用的展示窗口）→ nil，completion 不会被调用。
    /// - completion：在主线程回调，参数原样是系统给的（回跳地址，或错误；canceledLogin 是
    ///   `ASWebAuthenticationSessionError.canceledLogin`），由授权器映射结果。
    func start(
        url: URL,
        callbackURLScheme: String,
        prefersEphemeralWebBrowserSession: Bool,
        completion: @escaping @MainActor (URL?, (any Error)?) -> Void
    ) -> (any WebAuthSessionHandle)?
}

/// 淘宝 web_code 的真实授权器（FU-IOS-TB-WEBCODE-A；对齐安卓甲 `BrowserWebCodeAuthorizer`，D10-2717 定值、D10-3567 ⑥）：
/// ① auth_url 只放行 https、主机恰为 `authHost`、不带 userinfo、不带端口（`isAllowedAuthUrl`）；不在白名单返回 `.failed`，
///    **不启动会话、不写尝试记录**；
/// ② 先写尝试记录（只存 sha256(state) 与 `clock` 时间），再经 `launcher` 启动会话（`callbackURLScheme`、
///    `prefersEphemeralWebBrowserSession = false`）；start 失败（launcher 返回 nil）→ `.failed`，并按哈希删掉这条记录；
/// ③ completion：回跳地址经 `WebCodeCallbackParser` 解析且 state 哈希与本次一致 → `.code` 给 `.credential(.webCode(code))`、
///    `.incomplete`（error=1）给 `.failed`，两者都按哈希删记录；解析不了或哈希不符 → `.failed`；canceledLogin → `.cancelled`，
///    **记录保留**（留给晚到回跳核对，iOS 乙）；其他错误（如 presentationContextNotProvided）→ `.failed`；
/// ④ 一次只开一个会话：新的 `authorize` 或 `abort()`、或调用方任务被取消时，`cancel()` 旧会话，旧调用以 `.cancelled` 结束
///    （调用方 TaobaoAuthFlow 之后复核 alive，按 abandoned 处理）；每次调用恰好 resume 一次（之后到达的 completion 忽略）。
/// `available` 恒为 true。不另设本地计时器；会话期间场景在 inactive / active 之间来回不算取消（取消只认 canceledLogin）。
/// code 只在内存里经过（completion → 凭证），不保存、不进日志。
@MainActor
final class WebAuthSessionWebCodeAuthorizer: WebCodeAuthorizer {
    /// auth_url 白名单（D10-2717）：只放 https://oauth.taobao.com。
    static let authScheme = "https"
    static let authHost = "oauth.taobao.com"
    /// 会话的回跳 scheme（= 回跳解析器的 scheme，couli）。
    static let callbackURLScheme = WebCodeCallbackParser.scheme
    /// 共用 Safari 的淘宝登录态（D10-3567 ⑥）。
    static let prefersEphemeralWebBrowserSession = false

    private let launcher: any WebAuthSessionLauncher
    private let attempts: any WebCodeAttemptStore
    private let clock: () -> Int64

    /// launcher：会话端口（生产 `SystemWebAuthSessionLauncher`）；attempts：本机尝试记录（生产 `UserDefaultsWebCodeAttempts`）；
    /// clock：毫秒墙钟（写尝试记录的 started_at）。
    init(
        launcher: any WebAuthSessionLauncher,
        attempts: any WebCodeAttemptStore,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.launcher = launcher
        self.attempts = attempts
        self.clock = clock
    }

    /// TODO(FU-IOS-TB-WEBCODE-A 实现)：恒为 true。
    var available: Bool {
        false
    }

    /// TODO(FU-IOS-TB-WEBCODE-A 实现)：按类注释 ①–④ 执行（continuation 收口，仿 ThirdPartyAuth.swift AppleSignInAuthorizer）。
    func authorize(authUrl _: String, state _: String) async -> AuthStepResult {
        .failed
    }

    /// 取消正在进行的会话（页面离开时调用方可直接调；调用方任务被取消时同样生效）：旧调用以 `.cancelled` 结束，只 resume 一次。
    /// TODO(FU-IOS-TB-WEBCODE-A 实现)。
    func abort() {}

    /// https、主机（不区分大小写）恰为 `authHost`、不带 userinfo、不带端口；解析不了一律不放行。
    /// TODO(FU-IOS-TB-WEBCODE-A 实现)。
    nonisolated static func isAllowedAuthUrl(_: String) -> Bool {
        false
    }
}

/// 系统会话端口：`ASWebAuthenticationSession(url:callbackURLScheme:completionHandler:)`（最低 iOS 16，只能用自定义 scheme），
/// 展示锚点取 key window（仿 ThirdPartyAuth.swift AppleSignInAuthorizer.presentationAnchor）。
@MainActor
final class SystemWebAuthSessionLauncher: NSObject, WebAuthSessionLauncher {
    /// TODO(FU-IOS-TB-WEBCODE-A 实现)：建会话、设 presentationContextProvider 与 prefersEphemeralWebBrowserSession、start；
    /// 返回强引用会话的句柄；completion 转回主线程。
    func start(
        url _: URL,
        callbackURLScheme _: String,
        prefersEphemeralWebBrowserSession _: Bool,
        completion _: @escaping @MainActor (URL?, (any Error)?) -> Void
    ) -> (any WebAuthSessionHandle)? {
        nil
    }
}

extension SystemWebAuthSessionLauncher: ASWebAuthenticationPresentationContextProviding {
    /// TODO(FU-IOS-TB-WEBCODE-A 实现)：取 key window，没有再退回空锚点。
    nonisolated func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            ASPresentationAnchor()
        }
    }
}
