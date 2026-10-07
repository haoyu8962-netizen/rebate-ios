import Foundation

extension ApiClient {
    /// 交给传输层发一次。真正发出（task.resume）前在登记任务的同一把锁里再核对作废世代与会话世代（lessons 22）；
    /// 桥调用另核对调用有效性（APP-04 三端共性第 22 条）。返回 nil = 登记时就已作废、请求没有写出（APP-05a 共性 22）；
    /// 已写出之后被取消的照常返回 cancelled（结果未知）。
    func sendOnce(_ ready: Ready, timeoutMillis: Int64, _ options: RunOptions) async -> TransportOutcome? {
        let (epochValue, bound, callValid) = (options.epoch, options.boundGeneration, options.callValid)
        let written = SendWrittenFlag()
        let outcome = await transport.send(
            ready.request, timeoutMillis: timeoutMillis, cancelWithTask: callValid != nil
        ) { [weak self] in
            guard let self else {
                return false
            }
            let live = isCurrent(epochValue) && (bound == nil || currentGeneration == bound) && (callValid?() ?? true)
            written.value = live && !(callValid != nil && Task.isCancelled)
            return live
        }
        if case let .failure(kind) = outcome, kind == HttpTransport.kindCancelled, !written.value {
            return nil
        }
        return outcome
    }

    /// 会话级副作用：跳登录与其他前置引导（会登记待办或要求在当前会话里补办）、刷新、清会话。旧世代的响应不得交付。
    /// guide_only（step-up 操作上的 10001 / 10004 / 10005 / 授权码，以及 30304 等补办引导）都要求当前账号补身份、同意、
    /// 授权或实名、收款信息，同样按会话世代校验（R3-02）。
    static func isSessionScoped(_ effect: ErrorEffect) -> Bool {
        let kinds: Set<ErrorEffectKind> = [
            .login, .bindPhone, .consent, .stepUp, .authorize, .guideOnly, .refreshReplay, .refreshOnly,
            .clearSessionLogin, .clearSessionStayForceUpdate,
        ]
        return kinds.contains(effect.kind) || effect.registerPending || effect.route == "Login"
    }
}

/// 一次发送是否真的写出（传输层登记任务时写入一次，之后在同一任务里读）。
final class SendWrittenFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
