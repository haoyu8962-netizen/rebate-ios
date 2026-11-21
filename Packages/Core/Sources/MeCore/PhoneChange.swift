import CouliNetwork
import Foundation
import WalletCore

// APP-13a-2 换手机号（设置 → 账号与安全 → 手机号，页内子页，不注册路由，G22）：入口闸、号码规整、页面状态与 App 要给的端口。
// 执行器见 PhoneChangeController*.swift；页面见 Features/Me/PhoneChangeScreen*.swift。

/// 换号入口的发布闸（D10-2203 ⑤，与路由 since 同一道闸：since 为 nil = 本端未发布，Release 关）。
/// TODO(B1-20b)：B1-20b 部署 staging 后开门小单把它改成版本号。
/// 开门前置（D10-2281）：FU-IOS-PHONECHANGE-STEPUP-TITLE（面板按 action 换标题 / 说明行）必须先完成，不带此缺口对用户开放。
public enum PhoneChangeEntry {
    public static let sinceIOS: String? = nil
}

/// MeCore 的号码规整与脱敏（brief §11 第 11 项）：与 Login `PhoneNumber.normalize(_:).normalized` / `PhoneNumber.masked` 逐字一致
/// （BR-ID-05 细则「手机号规范化」：NFKC；删全部空白、零宽字符与连字符；去 +86 / 0086 / 86；1[3-9] 开头的 11 位 ASCII 数字）。
/// 只用于发码限流槽、未决记录摘要与 Done 显示；提交体里的号码只去首尾空白、原样上送（G33）。App 层另有逐字对照测试。
public enum MePhone {
    public static func normalize(_ raw: String) -> String? {
        var text = stripped(raw.precomposedStringWithCompatibilityMapping)
        if text.hasPrefix("+86") {
            text = String(text.dropFirst(3))
        } else if text.hasPrefix("0086"), digits(String(text.dropFirst(4)), count: 11) {
            text = String(text.dropFirst(4))
        } else if text.hasPrefix("86"), digits(String(text.dropFirst(2)), count: 11) {
            text = String(text.dropFirst(2))
        }
        let scalars = Array(text.unicodeScalars)
        guard digits(text, count: 11), scalars[0] == "1", ("3"..."9").contains(scalars[1]) else { return nil }
        return text
    }

    /// 11 位 → 前 3 后 4（BR-ID-33）；其余原样。
    public static func masked(_ normalized: String) -> String {
        guard normalized.count == 11 else { return normalized }
        return String(normalized.prefix(3)) + "****" + String(normalized.suffix(4))
    }

    private static func digits(_ text: String, count: Int) -> Bool {
        text.unicodeScalars.count == count && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    private static func stripped(_ text: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !removable(scalar) {
            view.append(scalar)
        }
        return String(view)
    }

    private static func removable(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || [0x200B, 0x200C, 0x200D, 0xFEFF].contains(scalar.value) || scalar == "-"
            || (0x2010...0x2015).contains(scalar.value)
    }
}

public enum PhoneChangeStep: Equatable, Sendable {
    case step1, step2, done, pending
}

public enum PhoneChangeDialog: Equatable, Sendable {
    /// 44001 PhoneChangeNewBlocked：标题键（字典有 risk_msg.<code> 用它，否则 error.44001）；正文 phone_change.risk_blocked.desc；
    /// 【知道了】(dismissDialog)、【联系客服申诉】(contactService)。
    case risk(titleKey: String, id: Int)
    /// 30414（发码 / 验证 / 提交三处同一个）：error.30414 +【联系客服】；【知道了】与【联系客服】之后都回设置页（D10-2203 补 (b)）。
    case unavailable(id: Int)
    /// 放弃上一次提交的二次确认（绑定原键；补充句 phone_change.pending.abandon_note；点遮罩不关）。
    case abandon(key: String, id: Int)

    public var id: Int {
        switch self {
        case let .risk(_, id), let .unavailable(id), let .abandon(_, id): id
        }
    }
}

/// 待确认卡（取自本机未决记录）。
public struct PhoneChangePendingCard: Equatable, Sendable {
    public let key: String
    /// 本机脱敏的提交号码（记录摘要里的 phone）；取不到为 nil（卡片用 fallback 句）。
    public let maskedPhone: String?
    public let submittedAtMillis: Int64

    public init(key: String, maskedPhone: String?, submittedAtMillis: Int64) {
        self.key = key
        self.maskedPhone = maskedPhone
        self.submittedAtMillis = submittedAtMillis
    }

    /// 页面读的提交号码（就是 `maskedPhone`：本机脱敏的新号，不是当前号；Features/Me 按 G-S04 不出现脱敏当前号的字样，换名读）。
    public var submittedPhoneDigits: String? {
        maskedPhone
    }
}

/// 换号子页的页面状态（token 不在这里：只在执行器内存，带失效世代，共性第 39、43 条）。
public struct PhoneChangeState: Equatable, Sendable {
    public var step: PhoneChangeStep = .step1
    // 第 1 步（验证当前手机号；不显示当前号码，D10-2203 ③）
    public var oldCode = ""
    public var oldSending = false
    public var oldResendLeftSec: Int64 = 0
    public var verifying = false
    public var oldError: MeNotice?
    // 第 2 步（验证新手机号）
    public var newPhone = ""
    public var newCode = ""
    public var newSending = false
    public var newResendLeftSec = 0
    public var newCodeSent = false
    public var submitting = false
    public var phoneError: MeNotice?
    public var codeError: MeNotice?
    public var notice: MeNotice?
    // 结局
    public var doneMaskedPhone: String?
    public var pending: PhoneChangePendingCard?
    public var pendingNotice: MeNotice?
    public var pendingBusy = false
    public var dialog: PhoneChangeDialog?
    /// 10003 面板说明行的脱敏新号（FU-IOS-PHONECHANGE-STEPUP-TITLE，D10-2281）：打开面板时按这次要放行的请求固定（提交 = 提交摘要的号，
    /// 确认 = 打开时待确认卡的号；空串当 nil），之后改输入框、卡片刷新都不变（共性第 17 条）；面板一收起就清空。nil = 不显示说明行。
    public var panelMaskedPhone: String?
    /// 读屏播报（每条一次）：assertive=true 打断式（20002 / 20003、待确认卡出现），false 礼貌（「已发送」）。
    public var announce: MeNotice?
    /// 页面数据版本（表单世代）：回调捕获渲染时的值，执行时核对。换步、重置、换代时加一；输入不加。
    public var version = 0

    public init() {}

    /// Done 页读的新号（就是 `doneMaskedPhone`：实际发送的固定摘要；Features/Me 换名读，同 `submittedPhoneDigits`）。
    public var donePhoneDigits: String? {
        doneMaskedPhone
    }
}

// MARK: - App 给的端口（D10-2203 ①：MeCore 定端口，App 用 BindPhoneService 适配；首次绑定代码不搬家）

/// 绑手机写请求的固定身份（Login BindPhoneOwner 的同形：网络归属 + 会话作用域）。
public struct PhoneBindOwner: Equatable, Sendable {
    public let request: RequestOwnership
    public let scope: String?

    public init(request: RequestOwnership, scope: String?) {
        self.request = request
        self.scope = scope
    }

    public var account: String? {
        request.account
    }
}

/// 一次绑手机写请求的共享结局（同 Login BindSettledKind）。
public enum PhoneBindSettledKind: Equatable, Sendable {
    case done, ended, abandoned, pending, other
}

/// 共享未决通知（BindPhoneService.notifyPending 的同形，共性第 18、24、47 条）。
public struct PhoneBindSettled: Equatable, Sendable {
    public let account: String
    public let kind: PhoneBindSettledKind
    public let owner: PhoneBindOwner

    public init(account: String, kind: PhoneBindSettledKind, owner: PhoneBindOwner) {
        self.account = account
        self.kind = kind
        self.owner = owner
    }
}

/// 第 2 步 bind 发码的结果（同 Login BindSmsResult）。
public enum PhoneBindSms: Equatable, Sendable {
    case sent, rateLimited, silent
    case field(textKey: String)
    case risk(titleKey: String)
    case navigate(route: String)
    case notice(textKey: String, trace6: String)
}

/// 换号写请求（提交 / 确认 / 放弃）的原始结果：共享结算（phoneGate、成功结算、未决通知）已在 BindPhoneService 按固定身份做完。
/// `notified`：随后会有一条共享未决通知（本页据此不把自己的结果当成别处结算）。
public struct PhoneBindArrival: Sendable {
    public let result: ApiResult
    public let kind: PhoneBindSettledKind
    public let gated: Bool
    public let notified: Bool

    public init(result: ApiResult, kind: PhoneBindSettledKind, gated: Bool, notified: Bool) {
        self.result = result
        self.kind = kind
        self.gated = gated
        self.notified = notified
    }
}

/// 一次换号提交的原键、原体与展示摘要（10003 后原键原体重放；Done 取实际发送的固定摘要，共性第 17 条）。
public struct PhoneChangeSubmission: Equatable, Sendable {
    public let key: String
    public let body: String
    public let summary: String
    public let maskedPhone: String?
}

/// 绑手机的会话级服务（App：BindPhoneService 适配）。都在主线程调用；`owner` 只比较。
@MainActor
public protocol PhoneBindPort: AnyObject {
    func identity() -> PhoneBindOwner
    func isCurrent(_ owner: PhoneBindOwner) -> Bool
    /// phoneGate（提交、确认、放弃与 BindPhone 页共用一份，共性第 8 条）此刻禁用。
    func writeGated(_ owner: PhoneBindOwner) -> Bool
    /// phoneGate 本体（页面订阅禁用期开始 / 结束重绘）。
    var writeGate: RetryAfterGate { get }
    /// 流程 token 的失效世代（绑定成功——本页或别处——时推进，共性第 39、43 条）。
    func tokenEpoch() -> UInt64
    /// 固定作用域此刻仍未变（线程安全；发码 / 验证 42901 结算用，共性第 49 条）。
    func scopeStill(_ owner: PhoneBindOwner) -> @Sendable () -> Bool
    /// 会话状态同步出口（同步调用，换代后旧子页在这里作废，共性第 36 条）。返回取消闭包。
    func observeSession(_ listener: @escaping @MainActor () -> Void) -> () -> Void
    func subscribe(_ listener: @escaping @MainActor (PhoneBindSettled) -> Void) -> () -> Void
    func pendingStatus(_ owner: PhoneBindOwner) async -> PendingLookup
    /// bind 发码：`phone` 已规范化（与 BindPhone 页同一份「账号 + 规范化号码 + bind」截止时间，共性第 15、30 条）。
    func smsRemainingSec(_ owner: PhoneBindOwner, phone: String) -> Int
    func smsSending(_ owner: PhoneBindOwner, phone: String) -> Bool
    func sendCode(_ owner: PhoneBindOwner, phone: String, completion: @escaping @MainActor (PhoneBindSms) -> Void)
    /// 更换提交：原键原体（`submission`），带第 1 步 / 面板的 token。
    func submitChange(
        _ owner: PhoneBindOwner, _ submission: PhoneChangeSubmission, stepUpToken: String?,
        completion: @escaping @MainActor (PhoneBindArrival) -> Void
    )
    /// 【确认上一次提交】：原键原体（网络层取未决记录），可带 token（面板验证后）。
    func confirmChange(
        _ owner: PhoneBindOwner, key: String, stepUpToken: String?,
        completion: @escaping @MainActor (PhoneBindArrival) -> Void
    )
    /// 【确定放弃】：作废原键（action = phone_change）。
    func abandonChange(
        _ owner: PhoneBindOwner, key: String, completion: @escaping @MainActor (PhoneBindArrival) -> Void
    )
}

/// 换号子页要的全部外部依赖（App 在 `AppMe.connect(wallet:)` 之后给出）。
@MainActor
public protocol PhoneChangePorts: AnyObject {
    /// 钱包二次验证的会话级依赖（gates.sms / gates.verify、SmsDeadlines、StepUpTokenCache、共享结算）：与提现 / 收款 / 注销面板同一份。
    func stepUpDeps() -> WalletDeps
    /// 钱包环境此刻的固定身份（一次读取；只在子页构造时调用）。
    func walletOwner() -> WalletOwner
    var bind: PhoneBindPort { get }
}

/// 设置页（子页宿主）：只关发起的这一个子页。
@MainActor
protocol PhoneChangeHost: AnyObject {
    func closePhoneChange(_ sub: PhoneChangeController)
}
