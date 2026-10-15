import Foundation
import Generated

// MARK: - 昵称

/// 修改昵称的输入判定（G27，BR-ID-39）：去首尾空白后 1–16 个扩展字素簇才可保存（iOS 用 `String.count`）；与当前昵称相同不可保存。
public struct NicknameCheck: Equatable, Sendable {
    public let trimmed: String
    public let length: Int
    public let saveEnabled: Bool
}

public enum NicknameInput {
    public static let max = 16

    public static func model(current: String, input: String) -> NicknameCheck {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = trimmed.count
        let same = trimmed == current.trimmingCharacters(in: .whitespacesAndNewlines)
        return NicknameCheck(trimmed: trimmed, length: length, saveEnabled: (1...max).contains(length) && !same)
    }

    public static func check(current: String, input: String) -> [String: Any] {
        let model = model(current: current, input: input)
        return ["trimmed": model.trimmed, "length": model.length, "saveEnabled": model.saveEnabled]
    }
}

/// 写操作的结果分流（昵称、申诉）。
public struct WriteOutcome: Equatable, Sendable {
    public static let saved = "saved"
    public static let progress = "progress"
    public static let fieldError = "field_error"
    public static let showError = "show_error"
    public static let retryAfter = "retry_after"
    public static let errorTrace6 = "error_trace6"
    public static let forceUpdate = "force_update"
    public static let riskNotice = "risk_notice"

    public let actionRaw: String
    public let textKey: String?
    public let keepInput: Bool
    public let disableMs: Int64?

    public init(_ actionRaw: String, textKey: String? = nil, keepInput: Bool = false, disableMs: Int64? = nil) {
        self.actionRaw = actionRaw
        self.textKey = textKey
        self.keepInput = keepInput
        self.disableMs = disableMs
    }

    var json: [String: Any] {
        var out: [String: Any] = ["actionRaw": actionRaw]
        if let textKey {
            out["textKey"] = textKey
        }
        if keepInput {
            out["keepInput"] = true
        }
        if let disableMs {
            out["disableMs"] = disableMs
        }
        return out
    }
}

/// 错误码 → 文案键与禁用时长。
public enum MeCodes {
    public static let networkKey = "me.network_error"
    public static let rateKey = "error.42901"
    public static let defaultRetryMillis: Int64 = 5000

    /// Retry-After 头（秒）→ 禁用毫秒；缺省或非法 5 秒。
    public static func retryAfterMillis(_ raw: String?) -> Int64 {
        let text = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let seconds = Int64(text), seconds > 0
        else { return defaultRetryMillis }
        return seconds * 1000
    }

    /// 5xxxx 的文案键：字典里有 error.<code> 用它，否则回落 error.50001（APP-06a 第 12 条）。
    public static func serverErrorKey(_ code: Int) -> String {
        DefaultTexts.text("error.\(code)") != nil ? "error.\(code)" : "error.50001"
    }

    /// 表内业务码的文案键（字典没有为 nil：调用方按服务端 msg →「操作未完成，请稍后再试」兜底，G13）。
    public static func codeTextKey(_ code: Int) -> String? {
        DefaultTexts.text("error.\(code)") != nil ? "error.\(code)" : nil
    }

    static func code(_ result: [String: Any]) -> Int {
        JSONKind.int64(result["code"]).map { Int($0) } ?? -1
    }

    /// 写操作结果的共同分流（向量形状：kind ok / transport / error，code、data、headers、traceId）。
    static func common(_ result: [String: Any]) -> WriteOutcome? {
        if result["kind"] as? String == "transport" {
            return WriteOutcome(WriteOutcome.showError, textKey: networkKey, keepInput: true)
        }
        let code = code(result)
        switch code {
        case 42901:
            let headers = result["headers"] as? [String: Any]
            let raw = (headers?["Retry-After"] ?? headers?["retry-after"]) as? String
            return WriteOutcome(WriteOutcome.retryAfter, textKey: rateKey, keepInput: true,
                                disableMs: retryAfterMillis(raw))
        case 50000...59999:
            return WriteOutcome(WriteOutcome.errorTrace6, textKey: serverErrorKey(code), keepInput: true)
        case 10405:
            return WriteOutcome(WriteOutcome.forceUpdate)
        case 10006:
            return WriteOutcome(WriteOutcome.riskNotice)
        default:
            return nil
        }
    }
}

/// 保存昵称的结果分流（G01；不自动重试写请求）。
public enum NicknameOutcome {
    public static func model(result: [String: Any]) -> WriteOutcome {
        if result["kind"] as? String == "ok" {
            return WriteOutcome(WriteOutcome.saved)
        }
        if let common = MeCodes.common(result) {
            return common
        }
        let code = MeCodes.code(result)
        if code == 20001 {
            let sensitive = (result["data"] as? [String: Any])?["reason"] as? String == "nickname_sensitive"
            return WriteOutcome(
                WriteOutcome.fieldError, textKey: sensitive ? "error.20001.nickname_sensitive" : "error.20001",
                keepInput: true
            )
        }
        return WriteOutcome(WriteOutcome.showError, textKey: MeCodes.codeTextKey(code), keepInput: true)
    }

    public static func of(result: [String: Any]) -> [String: Any] {
        model(result: result).json
    }
}
