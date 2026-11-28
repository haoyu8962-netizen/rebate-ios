import AuthenticationServices
import Foundation
import Trade
import UIKit

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
    nonisolated static let authScheme = "https"
    nonisolated static let authHost = "oauth.taobao.com"
    /// 会话的回跳 scheme（= 回跳解析器的 scheme，couli）。
    static let callbackURLScheme = WebCodeCallbackParser.scheme
    /// 共用 Safari 的淘宝登录态（D10-3567 ⑥）。
    static let prefersEphemeralWebBrowserSession = false

    /// 正在进行的一次授权（至多一次）：`id` 区分新旧调用，旧调用迟到的 completion / 取消按 `id` 对不上即忽略。
    private struct Pending {
        let id: Int
        let stateSha256: String
        let continuation: CheckedContinuation<AuthStepResult, Never>
        var session: (any WebAuthSessionHandle)?
    }

    private let launcher: any WebAuthSessionLauncher
    private let attempts: any WebCodeAttemptStore
    private let clock: () -> Int64
    private var pending: Pending?
    private var nextId = 0

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

    /// 恒为 true（Release 与关着假服务的 Debug 都能执行；会话起不来时在 start 那一步返回 `.failed`）。
    var available: Bool {
        true
    }

    /// 按类注释 ①–④ 执行（continuation 收口，仿 ThirdPartyAuth.swift AppleSignInAuthorizer）。
    func authorize(authUrl: String, state: String) async -> AuthStepResult {
        guard Self.isAllowedAuthUrl(authUrl), let url = URL(string: authUrl) else { return .failed }
        // 一次只开一个会话：先收掉上一次（cancel 旧会话，旧调用以 cancelled 结束），再写记录、开新会话
        abort()
        guard !Task.isCancelled else { return .cancelled }
        nextId += 1
        let id = nextId
        let stateSha256 = webCodeStateSha256(state)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending = Pending(id: id, stateSha256: stateSha256, continuation: continuation, session: nil)
                attempts.record(state: state, nowMillis: clock())
                let session = launcher.start(
                    url: url,
                    callbackURLScheme: Self.callbackURLScheme,
                    prefersEphemeralWebBrowserSession: Self.prefersEphemeralWebBrowserSession
                ) { [weak self] callbackURL, error in
                    self?.complete(id: id, callbackURL: callbackURL, error: error)
                }
                guard let session else {
                    attempts.clearIfCurrent(stateSha256: stateSha256)
                    finish(id: id, .failed)
                    return
                }
                if pending?.id == id {
                    pending?.session = session
                }
            }
        } onCancel: {
            // 调用方任务被取消（可能来自任意线程）：回主线程 cancel 本次会话；本次已结束或已被新调用取代时什么都不做
            Task { @MainActor [weak self] in
                self?.cancel(id: id)
            }
        }
    }

    /// 取消正在进行的会话（页面离开时调用方可直接调；调用方任务被取消时同样生效）：旧调用以 `.cancelled` 结束，只 resume 一次。
    /// 尝试记录保留（同 canceledLogin，留给晚到回跳核对）。没有进行中的授权时什么都不做。
    func abort() {
        guard let current = pending else { return }
        cancel(id: current.id)
    }

    /// https、主机（不区分大小写）恰为 `authHost`、不带 userinfo、不带端口（含显式 :443 与空端口）；解析不了一律不放行。
    /// 主机按百分号编码原样比（`oauth%2Etaobao.com` 之类不放行）。
    nonisolated static func isAllowedAuthUrl(_ authUrl: String) -> Bool {
        guard let components = URLComponents(string: authUrl) else { return false }
        return components.scheme == authScheme
            && components.percentEncodedUser == nil
            && components.percentEncodedPassword == nil
            && components.port == nil
            && components.rangeOfPort == nil
            && components.percentEncodedHost?.lowercased() == authHost
    }

    // MARK: - 收口（每次调用恰好 resume 一次）

    private func cancel(id: Int) {
        guard let current = pending, current.id == id else { return }
        current.session?.cancel()
        finish(id: id, .cancelled)
    }

    /// 会话 completion：只认本次调用的第一次回调，之后到达的（含 cancel 之后系统补的 canceledLogin）一律忽略。
    private func complete(id: Int, callbackURL: URL?, error: (any Error)?) {
        guard let current = pending, current.id == id else { return }
        if let error {
            let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
            finish(id: id, cancelled ? .cancelled : .failed)
            return
        }
        guard let callbackURL, let callback = WebCodeCallbackParser.parse(callbackURL.absoluteString),
              webCodeStateSha256(callback.state) == current.stateSha256
        else {
            // 解析不了或 state 哈希不符：按失败；记录保留（不是本次的回跳，不据此删）
            finish(id: id, .failed)
            return
        }
        attempts.clearIfCurrent(stateSha256: current.stateSha256)
        switch callback {
        case let .code(code, _):
            finish(id: id, .credential(.webCode(code)))
        case .incomplete:
            finish(id: id, .failed)
        }
    }

    private func finish(id: Int, _ result: AuthStepResult) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        current.continuation.resume(returning: result)
    }
}

/// 系统会话的句柄：强引用 ASWebAuthenticationSession 与 completion，直到系统回调 completion（或 start 失败）为止；completion 只转发一次。
@MainActor
private final class SystemWebAuthSessionHandle: WebAuthSessionHandle {
    var session: ASWebAuthenticationSession?
    var completion: (@MainActor (URL?, (any Error)?) -> Void)?

    func cancel() {
        session?.cancel()
    }

    /// 系统 completion 到达（已回到主线程）：放掉会话与 completion，再转发一次。
    func deliver(_ callbackURL: URL?, _ error: (any Error)?) {
        let forward = completion
        release()
        forward?(callbackURL, error)
    }

    func release() {
        session = nil
        completion = nil
    }
}

/// 系统会话端口：`ASWebAuthenticationSession(url:callbackURLScheme:completionHandler:)`（最低 iOS 16，只能用自定义 scheme），
/// 展示锚点取 key window（仿 ThirdPartyAuth.swift AppleSignInAuthorizer.presentationAnchor）。
@MainActor
final class SystemWebAuthSessionLauncher: NSObject, WebAuthSessionLauncher {
    /// 建会话、设 presentationContextProvider 与 prefersEphemeralWebBrowserSession、start；返回强引用会话的句柄。
    /// 系统 completion 的回调线程没有保证：closure 标 `@Sendable`（不继承主线程隔离），再经 Task 回主线程转发。
    func start(
        url: URL,
        callbackURLScheme: String,
        prefersEphemeralWebBrowserSession: Bool,
        completion: @escaping @MainActor (URL?, (any Error)?) -> Void
    ) -> (any WebAuthSessionHandle)? {
        let handle = SystemWebAuthSessionHandle()
        handle.completion = completion
        let session = ASWebAuthenticationSession(
            url: url, callbackURLScheme: callbackURLScheme
        ) { @Sendable callbackURL, error in
            Task { @MainActor in
                handle.deliver(callbackURL, error)
            }
        }
        session.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
        session.presentationContextProvider = self
        handle.session = session
        guard session.start() else {
            handle.release()
            return nil
        }
        return handle
    }
}

extension SystemWebAuthSessionLauncher: ASWebAuthenticationPresentationContextProviding {
    /// 取 key window，没有再退回空锚点（系统在主线程调用）。
    nonisolated func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
