import CouliNetwork
import Foundation

/// parse 的发送端口（生产为 ApiClient；测试可给假实现）。`isValid` 在每次等待结束、重试与实际发送前检查（请求归属，brief §0）。
public protocol ParseApi: AnyObject, Sendable {
    func send(_ call: ApiCall, isValid: @escaping @Sendable () -> Bool) async -> ApiResult
}

extension ApiClient: ParseApi {}

/// 一次 parse 的结果：action 为页面动作；dropped = 本地没发出或归属已失效（不出卡、不提示）。
public struct ParseOutcome: @unchecked Sendable {
    public let action: ParseAction?
    public let dropped: Bool
}

/// `POST /v1/inputs/parse`（brief §2.6）：scene=clipboard（SearchTyping 的粘贴入口同样用 clipboard）；请求体只有本地抽出的片段（G04），
/// 原文不上传。parse 没有幂等键，不做自动重试（读接口的网络层重试另算）。
/// 整体 10405：请求声明 `forceUpdateByCaller`，网络层不替它进强更；结果带 networkForced 与最低版本交回执行层，执行层在主线程复核
/// 请求归属后才进强更（共性第 29 条，迟到或已失效的响应不跳强更、不落盘）。整体非强更 10405 按统一错误（`NonForcedUpdate`）。
/// 整体 30132：预填用请求前本地抽出的「」标题（`title`，随本次请求绑定），不读契约外的 data.raw，不保存原文（共性第 30 条）。
public final class ParseInputService: Sendable {
    public static let operationId = "parseInput"
    public static let scene = "clipboard"
    /// openapi ParseInputRequest.text maxLength。
    public static let maxTextLength = 4000
    /// 出【重试】的传输失败（FU-IOS-0730 三端口径）：超时、断连（无网也归这类）、拿到的不是统一外壳（按网络异常看）。
    /// 取值与 HttpTransport.kindTimeout / kindDisconnect / kindNoEnvelope 一致；cancelled 与刷新暂时失败沿用的原因不在内。
    public static let retryableTransportKinds: Set<String> = ["timeout", "disconnect", "no_envelope"]

    private let api: ParseApi

    public init(api: ParseApi) {
        self.api = api
    }

    /// 请求体：{"text": 片段, "scene": "clipboard"}。
    public static func body(_ upload: String) -> String {
        let text = String(upload.prefix(maxTextLength))
        let object: [String: Any] = ["text": text, "scene": scene]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    /// - Parameter title: 本次上传片段里本地抽出的「」标题（没有为 nil）；整体 30132 用它预填【用商品名搜索】。
    public func parse(
        _ upload: String, title: String? = nil, isValid: @escaping @Sendable () -> Bool
    ) async -> ParseOutcome {
        let call = ApiCall(operationId: Self.operationId, body: Self.body(upload), forceUpdateByCaller: true)
        let result = await api.send(call, isValid: isValid)
        return Self.outcome(result, title: title)
    }

    static func outcome(_ result: ApiResult, title: String? = nil) -> ParseOutcome {
        switch result {
        case let .success(data, traceId, _):
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            let envelope: [String: Any] = ["code": 0, "data": object, "trace_id": traceId ?? ""]
            return ParseOutcome(
                action: ParseResultAction.map(response: envelope, errorCode: nil, retryAfter: nil, traceId: traceId),
                dropped: false
            )
        case let .failure(rawCode, _, data, traceId, effect, _):
            // 整体非强更 10405（refresh_only，及其后刷新暂时失败 / 被拒；FU-IOS-0712 R1-03）：进按码分流表之前换成统一错误码
            // （error.50001 + trace6，提示后可再次粘贴 / 识别），不进强更；真强更与行内 10405（成功外壳里的行）照旧
            let code = NonForcedUpdate.pageCode(code: rawCode, effect: effect)
            var action = ParseResultAction.map(response: nil, errorCode: code, retryAfter: nil, traceId: traceId)
            if code == ParseResultAction.rateLimited {
                // Retry-After 由网络层解析进 ErrorEffect.disableMillis（缺省 5 秒）；0 也按 5 秒（A11）
                let millis = effect.disableMillis ?? 0
                action.disableMs = millis > 0 ? millis : ErrorActionMapper.defaultRetryAfterMillis
            }
            if code == ParseResultAction.unrecognized {
                // 契约不保证整体 30132 的 data 里有原文：只用本次请求前抽出的标题，没有就留空
                let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
                action.prefill = trimmed?.isEmpty == false ? trimmed : nil
            }
            if code == ParseResultAction.forceUpdateCode, effect.kind == .forceUpdate {
                let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                action.networkForced = true
                action.minSupportedVersion = (object?["min_supported_version"] as? String).flatMap {
                    $0.isEmpty ? nil : $0
                }
            }
            return ParseOutcome(action: action, dropped: false)
        case let .transportFailure(kind, _, _, _):
            var action = ParseAction(actionRaw: ParseResultAction.error)
            action.textKey = ParseResultAction.genericErrorKey
            action.showTrace6 = false
            action.transportKind = kind
            action.retryable = retryableTransportKinds.contains(kind)
            return ParseOutcome(action: action, dropped: false)
        case .localReject, .sessionCleared, .abandoned, .sessionNotSaved:
            return ParseOutcome(action: nil, dropped: true)
        }
    }
}

/// 自动识别的读取时机（brief §2.1；共性第 1 条）：只有冷启动进入前台、或真正经过后台之后回到前台，才算「一次回前台」；每次回前台最多判定
/// 1 次（判定过就算读过，不论结果）；App 内页面切换、系统弹窗或下拉通知后的重新激活都不触发；离开敏感页面后不补做。
/// 由 App 的生命周期事件驱动（iOS：didEnterBackground → didBecomeActive），不用页面 onAppear 代替。三端同名。
@MainActor
public final class ClipboardWatcher {
    public private(set) var inForeground = false
    /// 前台轮次：每次回前台、进后台都 +1；在途的探测与提示条按它核对。
    public private(set) var round: Int64 = 0
    public private(set) var readThisForeground = false
    private var started = false
    private var backgrounded = false
    private let evaluate: @MainActor (_ event: String, _ round: Int64) -> Void

    public init(evaluate: @escaping @MainActor (_ event: String, _ round: Int64) -> Void) {
        self.evaluate = evaluate
    }

    /// 场景变为活跃（iOS didBecomeActive / scenePhase active）：冷启动第一次与进过后台之后的那一次才算回前台。
    public func onActive() {
        guard !started || backgrounded else { return }
        let event = started ? ClipboardReadPolicy.eventForeground : ClipboardReadPolicy.eventColdStart
        started = true
        backgrounded = false
        inForeground = true
        round += 1
        readThisForeground = false
        evaluate(event, round)
    }

    /// 进入后台（didEnterBackground / scenePhase background）。
    public func onBackground() {
        guard started else { return }
        backgrounded = true
        inForeground = false
        round += 1
    }

    /// 本轮前台已判定（不论结果）：之后的普通重新激活不再触发。
    public func consume(_ round: Int64) {
        if round == self.round {
            readThisForeground = true
        }
    }
}
