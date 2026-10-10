import Foundation

extension ApiClient {
    /// 一次交给传输层的结果：写出（含写出后被取消，结果未知）或没有写出（附本地结束原因：登记时已作废 call_cancelled，或最终准入
    /// 被发送前闸门拦下 send_blocked）。没有写出的按本地结束，与「已写出、结果未知」分开（APP-05a 共性 22；APP-08 共性第 32 条）。
    enum SendOnce {
        case written(TransportOutcome)
        case notWritten(String)

        /// 没有写出时的本地结束原因（写出了为 call_cancelled 占位，不会用到）。
        var notWrittenReason: String {
            if case let .notWritten(reason) = self {
                return reason
            }
            return LocalRejectReason.callCancelled
        }
    }

    /// 交给传输层发一次。真正发出（task.resume）前在登记任务的同一把锁里再核对作废世代与会话世代（lessons 22）；
    /// 桥调用另核对调用有效性（APP-04 三端共性第 22 条）；带发送前闸门的（订单请求）在这里做**最终准入**（APP-08 共性第 32 条）：
    /// admit 之后、实际写出之前别的请求启动了共享禁用期，本次也不写出，本地结束 send_blocked。闸门不进归属：先看归属，归属失效仍是
    /// call_cancelled；已写出的请求不受闸门影响。
    /// 登记时就已作废或被闸门拦下、请求没有写出时返回 `.notWritten`（APP-05a 共性 22）；已写出之后被取消的照常返回 cancelled（结果未知）。
    func sendOnce(_ ready: Ready, timeoutMillis: Int64, _ options: RunOptions) async -> SendOnce {
        let (epochValue, bound, callValid) = (options.epoch, options.boundGeneration, options.callValid)
        let sendAllowed = options.sendAllowed
        let expected = options.expected?.generation
        let written = SendWrittenFlag()
        let blocked = SendWrittenFlag()
        let outcome = await transport.send(
            ready.request, timeoutMillis: timeoutMillis, cancelWithTask: callValid != nil
        ) { [weak self] in
            guard let self else {
                return false
            }
            let generationNow = currentGeneration
            let live = isCurrent(epochValue) && (bound == nil || generationNow == bound)
                && (expected == nil || generationNow == expected) && (callValid?() ?? true)
            let allowed = !live || (sendAllowed?() ?? true)
            blocked.value = live && !allowed
            let proceed = live && allowed
            written.value = proceed && !(callValid != nil && Task.isCancelled)
            return proceed
        }
        if case let .failure(kind) = outcome, kind == HttpTransport.kindCancelled, !written.value {
            return .notWritten(blocked.value ? LocalRejectReason.sendBlocked : LocalRejectReason.callCancelled)
        }
        if case let .response(_, headers, _) = outcome {
            // 显示用的服务端时钟（BR-TEXT-11）：每个带 Date 的响应都看一次
            observeServerDate(headers)
        }
        return .written(outcome)
    }

    /// 确需强更的 10405：交 `onForceUpdate`。调用方声明自己执行强更副作用的（parse）只把 Effect 交回，由调用方在主线程复核请求归属后
    /// 再进强更（APP-07 共性第 29 条）。
    func forceUpdateUnlessCallerHandles(_ data: [String: Any], _ call: ApiCall) async {
        guard !call.forceUpdateByCaller else { return }
        await hooks.onForceUpdate(JSONFields.string(data, "min_supported_version"))
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
