import Foundation
import Generated

// MARK: - 客服入口

public struct CsDecision: Equatable, Sendable {
    public let sheetRaw: String
    public let openUrl: String?
    public let copyText: String?
    public let buttons: [String]
}

/// 统一客服出口的决策（G20）：kf 缺失或不是 https → 只有帮助中心；未装微信 → 复制链接 + 帮助；已装或未知 → 打开微信（拉不起 → 打不开）。
public enum CsEntryDecision {
    public static let helpOnly = "help_only"
    public static let handoff = "handoff"
    public static let openFailed = "open_failed"
    public static let wechatMissing = "wechat_missing"
    public static let goHelp = "go_help"
    public static let copyLink = "copy_link"
    public static let retry = "retry"
    public static let openWechat = "open_wechat"

    public static func httpsUrl(_ kfUrl: String?) -> Bool {
        guard let kfUrl else { return false }
        return kfUrl.range(of: "^https://[^\\s/?#]+[^\\s]*$", options: .regularExpression) != nil
    }

    public static func model(kfUrl: String?, wechat: String, openResult: String?) -> CsDecision {
        guard let kfUrl, httpsUrl(kfUrl) else {
            return CsDecision(sheetRaw: helpOnly, openUrl: nil, copyText: nil, buttons: [goHelp])
        }
        if wechat == "no" {
            return CsDecision(sheetRaw: wechatMissing, openUrl: nil, copyText: kfUrl, buttons: [copyLink, goHelp])
        }
        if openResult == "failed" {
            return CsDecision(sheetRaw: openFailed, openUrl: kfUrl, copyText: kfUrl, buttons: [retry, copyLink, goHelp])
        }
        return CsDecision(sheetRaw: handoff, openUrl: kfUrl, copyText: nil, buttons: [openWechat, goHelp])
    }

    public static func of(kfUrl: String?, wechat: String, openResult: String?) -> [String: Any] {
        let model = model(kfUrl: kfUrl, wechat: wechat, openResult: openResult)
        return [
            "sheetRaw": model.sheetRaw, "openUrl": model.openUrl ?? NSNull(), "copyText": model.copyText ?? NSNull(),
            "buttons": model.buttons,
        ]
    }
}

/// 客服链接（G20、AC-S1-134 ④）：原样 kf.url，不拼任何账号标识与发起页路由名。
public enum CsLink {
    /// 发起页与账号刻意不进链接（G20）；参数留给三端同一签名与测试核对。
    public static func build(kfUrl: String, fromRoute _: String, account _: [String: Any]) -> String {
        kfUrl
    }
}
