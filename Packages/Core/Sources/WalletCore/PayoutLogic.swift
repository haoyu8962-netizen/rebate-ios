import Foundation

/// 收款账号页的显示（PayoutAccountBound / BoundBank）：只显示服务端返回的脱敏字段（BR-WDR-02、BR-ID-33）。
public struct PayoutAccountDisplay: Equatable, Sendable {
    public let bound: Bool
    public let methodRaw: String?
    public let maskedAccount: String?
    public let bankName: String?
    public let maskedPayee: String?
    public let changeRemaining: Int64?
    /// 认识的方式（alipay、bank_card）才出【更换收款账号】；不认识的（含 wechat）只显示脱敏串。
    public let known: Bool

    public static let unbound = PayoutAccountDisplay(
        bound: false, methodRaw: nil, maskedAccount: nil, bankName: nil, maskedPayee: nil, changeRemaining: nil,
        known: false
    )

    /// 「支付宝 138****5678」「招商银行 6214****1234」（Withdraw 收款账号行、待确认句的 {payout_account}）。
    public func line(_ texts: WalletTexts) -> String? {
        guard bound else { return nil }
        let account = maskedAccount ?? ""
        switch methodRaw {
        case WalletJSON.alipay:
            return texts.text("payout.channel.alipay") + " " + account
        case WalletJSON.bankCard:
            return [bankName.flatMap { $0.isEmpty ? nil : $0 }, account].compactMap(\.self).joined(separator: " ")
        default:
            return account
        }
    }
}

public enum PayoutAccountView {
    public static func view(_ account: PayoutAccount) -> PayoutAccountDisplay {
        switch account {
        case .unbound:
            .unbound
        case let .bound(bound):
            PayoutAccountDisplay(
                bound: true, methodRaw: bound.method, maskedAccount: bound.maskedAccount, bankName: bound.bankName,
                maskedPayee: bound.maskedPayeeName, changeRemaining: bound.changeRemainingThisMonth, known: bound.known
            )
        }
    }
}

/// 收款账号表单（用户填写的原文；只在内存，不进日志、恢复记录与截图）。
public struct PayoutForm: Equatable, Sendable, CustomStringConvertible {
    public var method: String
    public var alipayLogonId: String
    public var cardNo: String
    public var bankName: String
    public var payeeName: String

    public init(
        method: String = WalletJSON.alipay, alipayLogonId: String = "", cardNo: String = "", bankName: String = "",
        payeeName: String = ""
    ) {
        self.method = method
        self.alipayLogonId = alipayLogonId
        self.cardNo = cardNo
        self.bankName = bankName
        self.payeeName = payeeName
    }

    /// 不打印完整内容（BR-ID-33 细则）。
    public var description: String {
        "PayoutForm(method=\(method))"
    }
}

/// 表单规整的结果：`body` 为 savePayoutAccount 的请求体（不合格为 nil），`fieldErrors` 为要在旁边提示的字段名（契约字段名）。
public struct PayoutFormResult: Equatable, Sendable {
    public let body: [String: String]?
    public let fieldErrors: [String]
}

/// 收款账号表单（G12、G13、G14）：客户端只去掉首尾空白再原样提交；不做 Luhn、不做手机号或邮箱规范化、不判断卡类型（这些由服务端校验，
/// 20001 按 data.fields 在对应字段旁提示）。必填为空、超出契约长度（登录号 128、卡号 32、开户行与姓名 64）或卡号含数字、空格、连字符以外的
/// 字符时不提交（iOS I03，同 Android A10）。
public enum PayoutAccountForm {
    public static let payoutMethod = "payout_method"
    public static let alipayLogonId = "alipay_logon_id"
    public static let cardNo = "card_no"
    public static let bankName = "bank_name"
    public static let payeeName = "payee_name"
    public static let logonMax = 128
    public static let cardMax = 32
    public static let nameMax = 64
    static let cardChars = "^[0-9 \\-]*$"

    public static func build(_ form: PayoutForm) -> PayoutFormResult {
        var errors: [String] = []
        var body = [payoutMethod: form.method]
        if form.method == WalletJSON.bankCard {
            let card = trim(form.cardNo)
            let bank = trim(form.bankName)
            if card.isEmpty || card.count > cardMax || card.range(of: cardChars, options: .regularExpression) == nil {
                errors.append(cardNo)
            }
            if bank.isEmpty || bank.unicodeScalars.count > nameMax {
                errors.append(bankName)
            }
            body[cardNo] = card
            body[bankName] = bank
        } else {
            let logon = trim(form.alipayLogonId)
            if logon.isEmpty || logon.unicodeScalars.count > logonMax {
                errors.append(alipayLogonId)
            }
            body[alipayLogonId] = logon
        }
        let payee = trim(form.payeeName)
        if payee.isEmpty || payee.unicodeScalars.count > nameMax {
            errors.append(payeeName)
        }
        body[payeeName] = payee
        return PayoutFormResult(body: errors.isEmpty ? body : nil, fieldErrors: errors)
    }

    /// 卡号输入框的过滤：只允许数字、空格、连字符，最多 32 字；其余字符整段不接受（保持原值）。
    public static func acceptCardNo(current: String, next: String) -> String {
        next.count <= cardMax && next.range(of: cardChars, options: .regularExpression) != nil ? next : current
    }

    static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    /// 截到契约长度（按 Unicode 标量计，与服务端字符数一致）。
    public static func clip(_ text: String, max: Int) -> String {
        guard text.unicodeScalars.count > max else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(max))
        return String(scalars)
    }
}

/// 待确认摘要（本机按 BR-ID-33 细则的格式生成，只用于待确认展示；G15）。`account` 为 nil 时用 fallback 句（不输出完整登录号）。
public struct PayoutPendingSummaryView: Equatable, Sendable {
    public let method: String
    public let account: String?
    public let payee: String?
}

public enum PayoutPendingSummary {
    public static func summarize(_ form: PayoutForm,
                                 texts: WalletTexts = WalletDraftTexts()) -> PayoutPendingSummaryView {
        let payeeText = PayoutAccountForm.trim(form.payeeName)
        let payee = payeeText.unicodeScalars.last.map { "**" + String($0) }
        let account: String?
        if form.method == WalletJSON.bankCard {
            let digits = form.cardNo.filter(\.isASCII).filter(\.isNumber)
            let bank = PayoutAccountForm.trim(form.bankName)
            account = digits.count >= 4 && !bank.isEmpty
                ? texts.format("payout.bank_tail", ["bank": bank, "tail": String(digits.suffix(4))]) : nil
        } else {
            account = alipay(PayoutAccountForm.trim(form.alipayLogonId))
        }
        return PayoutPendingSummaryView(method: form.method, account: account, payee: payee)
    }

    /// 支付宝登录号：邮箱形式按 @ 前 2 / 1 / 0 位 +「***」+ @ 域名；只保留数字后为 11 位按 3+4；其余（如 +86 前缀）不定义，返回 nil。
    static func alipay(_ logon: String) -> String? {
        if let at = logon.lastIndex(of: "@") {
            let local = logon[..<at]
            guard !local.isEmpty else { return nil }
            let keep = local.count > 2 ? 2 : (local.count == 2 ? 1 : 0)
            return String(local.prefix(keep)) + "***" + String(logon[at...])
        }
        let digits = logon.filter(\.isASCII).filter(\.isNumber)
        guard digits.count == 11 else { return nil }
        return String(digits.prefix(3)) + "****" + String(digits.suffix(4))
    }

    /// 编进未决记录的摘要（JSON：method / account / payee，都是脱敏串）。
    public static func encode(_ view: PayoutPendingSummaryView) -> String {
        WalletJSON.text([
            "method": view.method, "account": view.account ?? NSNull(), "payee": view.payee ?? NSNull(),
        ] as [String: Any])
    }

    /// 从未决记录的摘要读回（坏数据按全空）。
    public static func decode(_ summary: String) -> PayoutPendingSummaryView? {
        guard let object = WalletJSON.parse(Data(summary.utf8)) as? [String: Any],
              let method = object["method"] as? String
        else { return nil }
        return PayoutPendingSummaryView(
            method: method, account: object["account"] as? String, payee: object["payee"] as? String
        )
    }
}

/// 实名表单（§2.8、G01）：姓名去首尾空白；身份证号只收数字与 X，18 位，小写 x 转大写；不做校验位计算。
public struct RealNameInput: Equatable, Sendable, CustomStringConvertible {
    public let name: String
    public let idNo: String
    public let submitEnabled: Bool

    public var description: String {
        "RealNameInput(submitEnabled=\(submitEnabled))"
    }
}

public enum RealNameForm {
    static let idPattern = "^[0-9]{17}[0-9X]$"
    public static let nameMax = 64

    public static func normalize(name: String, idNo: String) -> RealNameInput {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let id = idNo.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "x", with: "X")
        let ok = !trimmed.isEmpty && trimmed.unicodeScalars.count <= nameMax
            && id.range(of: idPattern, options: .regularExpression) != nil
        return RealNameInput(name: trimmed, idNo: id, submitEnabled: ok)
    }

    /// 身份证号输入框的过滤：只收数字与 x / X（转大写），最多 18 位；其余字符整段不接受。
    public static func acceptIdNo(current: String, next: String) -> String {
        let upper = next.replacingOccurrences(of: "x", with: "X")
        let valid = upper.count <= 18 && upper.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "X" }
        return valid ? upper : current
    }
}
