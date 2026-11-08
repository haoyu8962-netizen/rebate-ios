import CouliNetwork
import Foundation
import Generated

extension RealNameController {
    /// 一次实名提交：输入、键与固定身份。
    struct Attempt {
        let input: RealNameInput
        let key: String
        let owner: WalletOwner
    }

    /// 保留的幂等键（只在内存）。
    struct Retained {
        let input: RealNameInput
        let key: String
        var unknown: Bool
    }

    /// 一次失败结果之后键是否保留（nil = 结束，下次用新键）：断连记下「出现过结果未知」并保留；前置码、40901、10004 id_verification
    /// 保留；出现过结果未知时 10405 / 5xxxx / 42901 也保留；其余码结束。
    static func keyAfter(_ result: ApiResult, code: Int?, reopenConsent: Bool, held: Retained) -> Retained? {
        var next = held
        if case .transportFailure = result {
            next.unknown = true
        }
        guard let code else { return next }
        if sameKeyCodes.contains(code) || reopenConsent || (next.unknown && keepsUnknownKey(code)) {
            return next
        }
        return nil
    }

    static let busyCode = 40901
    static let consentCode = 10004
    static let maintenanceCode = 50301
    /// 保留原键的前置码（补办后沿用原键，ErrorActionMapper 1xxxx 前置）。
    static let sameKeyCodes: Set<Int> = [10001, 10005, 40901]

    /// 结果未知之后不结束键的码（错误码表：10405 不写幂等记录、不结束未决幂等键；5xxxx、42901 同为不结束，D10-1018）。
    static func keepsUnknownKey(_ code: Int) -> Bool {
        code == 10405 || code == 42901 || code / 10000 == 5
    }

    static func code(_ result: ApiResult) -> Int? {
        if case let .failure(code, _, _, _, _, _) = result {
            return code
        }
        return nil
    }

    /// 页内错误条：50301 不用缺主语的「{platform_name}维护中」，回落 error.50001 + trace6（D10-887 ②）；其余 5xxxx 照统一分类。
    static func notice(_ error: WalletError, code: Int?, id: Int) -> Notice {
        if code == maintenanceCode {
            return Notice("error.50001", id: id, traceId: error.traceId, showTrace6: true)
        }
        let key: String = if code == 20001 {
            "error.20001"
        } else if let code, code / 10000 != 5, DefaultTexts.text("error.\(code)") != nil {
            "error.\(code)"
        } else {
            error.textKey
        }
        return Notice(key, id: id, traceId: error.traceId, showTrace6: error.showTrace6)
    }
}
