import CouliNetwork
import Foundation
import Generated

/// 绑手机写请求（首次提交、确认上一次、放弃上一次）的结果 → 页面动作与共享结局（BR-ID-10 细则「敏感操作的幂等键」；APP-13a 共性第 7、22、
/// 24、44、47 条；G53、G75）：
/// - 键只在业务成功、写入幂等记录的 3xxxx、已作废（abandoned / 20903）时结束；1xxxx（前置除外）、其余 2xxxx、40901、42901、5xxxx、10405、
///   没有响应都不结束——从未结果未知的首次提交「这次键不用了」（下次点击生成新键）；结果未知过的键保持待确认；
/// - 首次绑定不预先二次验证：确认得到 10003 按「暂时无法确认」保留待确认（G53），不弹二次验证面板；
/// - 确认 / 放弃得到 30411 mergeable：只用本次响应带回的 merge_ticket 弹并号确认（G75）；键已结束。
@MainActor
enum BindOutcomes {
    enum Phase {
        case submit
        case confirm
        case abandon
    }

    static func map(_ result: ApiResult, phase: Phase, gated: Bool) -> (BindPageAction, BindSettledKind) {
        switch result {
        case .success:
            return (.done, .done)
        case let .failure(rawCode, _, data, traceId, effect, _):
            let object = LoginService.object(data)
            // 非强更的 10405 按 5xxxx（F-X-09，FU-IOS-0712）：首次提交统一错误 + trace6，确认 / 放弃保留待确认「稍后再试」
            let code = NonForcedUpdate.pageCode(code: rawCode, effect: effect)
            switch phase {
            case .submit:
                return submitFailure(code, object, traceId, effect)
            case .confirm:
                return confirmFailure(code, object, traceId, effect)
            case .abandon:
                return abandonFailure(code, object, traceId, effect)
            }
        case .abandoned:
            return (.reset(textKey: SensitiveTexts.abandoned), .abandoned)
        case let .transportFailure(_, _, _, unknown):
            if phase == .submit, !unknown {
                return (.notice(textKey: LoginService.genericKey, trace6: ""), .other)
            }
            return (.pending(noticeKey: phase == .submit ? nil : SensitiveTexts.retryLater, trace6: ""), .pending)
        case let .localReject(reason):
            return localReject(reason, phase: phase, gated: gated)
        default:
            return (.silent, .other)
        }
    }

    /// 没有发出：发送前被 phoneGate 拦下 → 限流提示；同一操作已有未决键 → 按记录进待确认；未决存储读不出 → 通用错误；其余（换会话等）静默。
    private static func localReject(_ reason: String, phase: Phase, gated: Bool) -> (BindPageAction, BindSettledKind) {
        if gated {
            return phase == .submit
                ? (.notice(textKey: "error.42901", trace6: ""), .other)
                : (.pending(noticeKey: SensitiveTexts.retryLater, trace6: ""), .other)
        }
        switch reason {
        case LocalRejectReason.pendingKeyUnresolved:
            return (.pending(noticeKey: nil, trace6: ""), .other)
        case LocalRejectReason.pendingStoreFailed:
            return (.notice(textKey: LoginService.genericKey, trace6: ""), .other)
        default:
            return (.silent, .other)
        }
    }

    // MARK: - 首次提交

    private static func submitFailure(_ code: Int, _ data: [String: Any], _ traceId: String?, _ effect: ErrorEffect)
        -> (BindPageAction, BindSettledKind) {
        if let shared = shared(code, data, effect) {
            return shared
        }
        switch code {
        case 20001:
            let key = ErrorActionMapper.resolveTextKey(
                code: code, reason: data["reason"] as? String, hasText: { DefaultTexts.text($0) != nil }
            )
            return (.field(field: "phone", textKey: key ?? "error.20001", clearCode: false), .other)
        case 20002:
            return (.field(field: "code", textKey: effect.textKey ?? "error.20002", clearCode: false), .other)
        case 20003:
            return (.field(field: "code", textKey: effect.textKey ?? "error.20003", clearCode: true), .other)
        case 42901:
            return (.notice(textKey: "error.42901", trace6: ""), .other)
        case 10003:
            // 首次绑定不需要二次验证（openapi bindPhone：step-up 只用于换号）；收到时只提示，键不用了
            return (.notice(textKey: effect.textKey ?? "error.10003", trace6: ""), .other)
        default:
            return generic(code, traceId, effect)
        }
    }

    // MARK: - 确认上一次

    private static func confirmFailure(_ code: Int, _ data: [String: Any], _ traceId: String?, _ effect: ErrorEffect)
        -> (BindPageAction, BindSettledKind) {
        if let shared = shared(code, data, effect) {
            return shared
        }
        if code / 10000 == 5 {
            return (.pending(noticeKey: SensitiveTexts.retryLater, trace6: LoginService.trace6(traceId)), .pending)
        }
        if code / 10000 == 2 {
            return (.pending(noticeKey: SensitiveTexts.cannotConfirm, trace6: ""), .pending)
        }
        // 42901、40901、10003（G53）、10405、44001 等：保持待确认，提示稍后再试
        return (.pending(noticeKey: SensitiveTexts.retryLater, trace6: ""), .pending)
    }

    // MARK: - 放弃上一次

    private static func abandonFailure(_ code: Int, _ data: [String: Any], _ traceId: String?, _ effect: ErrorEffect)
        -> (BindPageAction, BindSettledKind) {
        if code == 40901 {
            return (.pending(noticeKey: SensitiveTexts.abandonBusy, trace6: ""), .pending)
        }
        if let shared = shared(code, data, effect) {
            return shared
        }
        if code / 10000 == 5 {
            return (.pending(noticeKey: SensitiveTexts.retryLater, trace6: LoginService.trace6(traceId)), .pending)
        }
        return (.pending(noticeKey: SensitiveTexts.retryLater, trace6: ""), .pending)
    }

    // MARK: - 共用

    /// 三种写请求共用：30411（并号）、3xxxx 业务结局、44001（只首次提交按结束）、20903、10007、前置码。
    private static func shared(_ code: Int, _ data: [String: Any], _ effect: ErrorEffect)
        -> (BindPageAction, BindSettledKind)? {
        switch code {
        case 30411:
            if let ticket = BindPhoneAction.mergeTicket(data) {
                return (.merge(ticket: ticket), .ended)
            }
            return (.notice(textKey: "error.30411", trace6: ""), .ended)
        case 20903:
            return (.reset(textKey: "error.20903"), .abandoned)
        case 10007:
            if effect.kind == .navigate {
                return (.navigate(route: effect.route ?? "DeleteAccount"), .other)
            }
            return (.notice(textKey: effect.textKey ?? "error.10007", trace6: ""), .other)
        case 10001, 10004, 10005:
            guard let route = effect.route else {
                return (.notice(textKey: effect.textKey ?? LoginService.genericKey, trace6: ""), .other)
            }
            return (.navigate(route: route), .other)
        case 10405:
            // 网络层已按 Effect 进强更分流（APP-13a 共性第 12 条：只消费网络层结论，页面不按码重判）；非强更的 10405 在 map 里
            // 已换成 50001，走不到这里
            return (.silent, .other)
        default:
            break
        }
        if ErrorActionMapper.isBusinessCode(code) {
            return (.notice(textKey: effect.textKey ?? "error.\(code)", trace6: ""), .ended)
        }
        return nil
    }

    private static func generic(_ code: Int, _ traceId: String?, _ effect: ErrorEffect)
        -> (BindPageAction, BindSettledKind) {
        if code == 44001 {
            return (.risk(titleKey: effect.textKey ?? "error.44001"), .ended)
        }
        // 除法单独一行（FU-IOS-0712 R1-02：扫描器对「裸 / 之后同行还有引号」按无法确认边界拒绝）
        let serverFailure = code / 10000 == 5
        let trace = serverFailure || effect.includeTrace6 ? LoginService.trace6(traceId) : ""
        return (.notice(textKey: effect.textKey ?? LoginService.genericKey, trace6: trace), .other)
    }
}
