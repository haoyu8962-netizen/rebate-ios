import CouliNetwork
import Foundation
import Generated

/// 一条提示（文案键 + trace；`id` 每次换新，读屏重新播报；`assertive` 为 false 时 polite）。
public struct Notice: Equatable, Sendable {
    public let key: String
    public let id: Int
    public let traceId: String?
    public let showTrace6: Bool
    public let assertive: Bool

    public init(_ key: String, id: Int, traceId: String? = nil, showTrace6: Bool = false, assertive: Bool = true) {
        self.key = key
        self.id = id
        self.traceId = traceId
        self.showTrace6 = showTrace6
        self.assertive = assertive
    }

    func polite() -> Notice {
        Notice(key, id: id, traceId: traceId, showTrace6: showTrace6, assertive: false)
    }

    /// 统一错误消息（trace6 由 `ErrorTrace` 独立追加，不依赖文案里有 {trace6}）。
    public func message(_ texts: WalletTexts) -> String {
        ErrorTrace.message(key: key, traceId: traceId, append: showTrace6) { texts.format($0, $1) }
    }
}

/// 读请求（摘要、rules、记录、收款账号、详情）失败的显示结论。
public struct WalletError: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 传输层失败（断网、超时、网关错误页）：钱包摘要可用缓存（G22）。
        case transport
        case server
        case retryAfter
        case forceUpdate
        case notFound
        /// 本地拒绝且属于调用方作废（离页、换代、归属不符）：不显示。
        case cancelled
        /// 本请求被发送前限流闸门拦下（APP-09 共性第 62 条）：按 42901 结算。
        case gated
        case other
    }

    public let kind: Kind
    public let textKey: String
    public let traceId: String?
    public let showTrace6: Bool
    public let disableMillis: Int64

    public init(_ kind: Kind, _ key: String, traceId: String? = nil, trace6: Bool = false, disable: Int64 = 0) {
        self.kind = kind
        textKey = key
        self.traceId = traceId
        showTrace6 = trace6
        disableMillis = disable
    }

    public func notice(id: Int) -> Notice {
        Notice(textKey, id: id, traceId: traceId, showTrace6: showTrace6)
    }
}

/// 钱包类页面的错误分类（APP-06a 第 6、12 条，APP-07 第 9 条，APP-08 第 8、16 条）：5xxxx 的 trace6 由 `Notice.message` 独立追加；未收录的
/// 5xxxx 回落 error.50001；5xxxx 不伪装成空结果或「余额为 0」。
public enum WalletErrors {
    public static let networkKey = "wallet.network_error"
    static let notFoundCode = 30701

    /// `probe`：本请求的发送前闸门；本地拒绝 send_blocked 且它记下了拒绝 → gated（按 42901 结算），不看回调时刻的禁用期。
    public static func of(_ result: ApiResult, probe: SendProbe? = nil) -> WalletError {
        switch result {
        case .transportFailure:
            return WalletError(.transport, networkKey)
        case let .localReject(reason):
            if probe?.gated(result) == true {
                return WalletError(.gated, "error.42901", disable: 0)
            }
            let silent = [
                LocalRejectReason.callCancelled, LocalRejectReason.sessionChanged, LocalRejectReason.accountMismatch,
                LocalRejectReason.sendBlocked,
            ]
            return silent.contains(reason) ? WalletError(.cancelled, "") : WalletError(.other, networkKey)
        case .sessionCleared, .sessionNotSaved:
            return WalletError(.cancelled, "")
        case let .failure(code, _, _, traceId, effect, _):
            return failure(code, traceId: traceId, effect: effect)
        case let .success(_, traceId, _):
            // code=0 却解析不了（坏数据）：按服务端错误显示加载失败（不当成 0）
            return WalletError(.server, "error.50001", traceId: traceId, trace6: true)
        case .abandoned:
            return WalletError(.server, "error.50001")
        }
    }

    static func failure(_ code: Int, traceId: String?, effect: ErrorEffect) -> WalletError {
        if code == 42901 {
            return WalletError(
                .retryAfter,
                "error.42901",
                disable: effect.disableMillis ?? SensitiveOutcome.defaultRetryMillis
            )
        }
        if code == 10405 || effect.kind == .forceUpdate {
            return WalletError(.forceUpdate, "error.10405")
        }
        if code == notFoundCode {
            return WalletError(.notFound, "error.30701")
        }
        if code / 10000 == 5 {
            return WalletError(.server, SensitiveOutcome.serverKey(code), traceId: traceId, trace6: true)
        }
        let candidate = effect.textKey.flatMap { DefaultTexts.text($0) != nil ? $0 : nil } ?? "error.\(code)"
        let key = DefaultTexts.text(candidate) != nil ? candidate : "error.50001"
        return WalletError(.other, key, traceId: traceId)
    }

    /// 42901 的禁用时长（网络层 ErrorEffect.disableMillis，缺省 5 秒）；其余为 0。
    public static func disableMillis(_ result: ApiResult) -> Int64 {
        guard case let .failure(code, _, _, _, effect, _) = result, code == 42901 else { return 0 }
        return effect.disableMillis ?? SensitiveOutcome.defaultRetryMillis
    }

    /// 已解包的结果 → 结局表输入（提交、确认）。
    public static func outcomeInput(_ result: ApiResult) -> OutcomeInput {
        switch result {
        case .success:
            return OutcomeInput(OutcomeInput.okKind)
        case let .failure(code, _, data, _, _, _):
            let object = WalletJSON.parse(data) as? [String: Any] ?? [:]
            var strings: [String: String] = [:]
            for (key, value) in object {
                if let text = value as? String {
                    strings[key] = text
                }
            }
            let fields = (object["fields"] as? [Any])?.compactMap { $0 as? String } ?? []
            return OutcomeInput(
                OutcomeInput.errorKind, code: code, data: strings, fields: fields,
                retryAfterMillis: code == 42901 ? disableMillis(result) : nil
            )
        default:
            return OutcomeInput(OutcomeInput.transportKind)
        }
    }

    /// 作废接口的结果 → 结局表输入：abandoned；completed 的原结果（成功或 3xxxx，ApiClient 已按原操作解包）；其余按普通结果。
    public static func abandonInput(_ result: ApiResult) -> OutcomeInput {
        switch result {
        case .abandoned:
            .abandonResult(SensitiveOutcome.abandoned)
        case .success:
            .abandonResult("completed", originalCode: 0)
        case let .failure(code, _, _, _, _, _) where ErrorActionMapper.isBusinessCode(code):
            .abandonResult("completed", originalCode: code, data: outcomeInput(result).data)
        default:
            outcomeInput(result)
        }
    }
}
