import Foundation

/// 表单字段错误的定位与播报（APP-09 共性第 24、36、74 条，brief §0「字段错误即时播报一次，焦点移到错误提示」；iOS R1-11）：
/// - 每个错误事件（本地校验一次、20001 一次，各有编号）只定位一次；目标是表单顺序里**第一个**出错的字段——它的错误提示是可访问焦点与滚动目标；
/// - 事件登记后，等目标字段的错误视图出现（或随事件编号重新执行）才定位：滚动到它、移焦点、按事件编号播报一次；之后的重绘不再定位、不再播报。
/// 只在主线程使用（视图的 @State）。
public struct FieldErrorCue: Equatable, Sendable {
    /// 待定位的事件（`L<编号>` 本地校验，`F<编号>` 服务端 20001）。
    public private(set) var event: String?
    /// 待定位事件的目标字段。
    public private(set) var target: String?
    /// 最近一次已经定位并播报过的事件。
    public private(set) var handled: String?

    public init() {}

    /// 收款账号表单的字段顺序（自上而下：收款方式组、账号 / 卡号与开户行、收款人）。
    public static func payoutOrder(method: String) -> [String] {
        let middle = method == WalletJSON.bankCard
            ? [PayoutAccountForm.cardNo, PayoutAccountForm.bankName] : [PayoutAccountForm.alipayLogonId]
        return [PayoutAccountForm.payoutMethod] + middle + [PayoutAccountForm.payeeName]
    }

    /// 实名表单的字段顺序（姓名在上、身份证号在下；iOS R2-06）。
    public static let realNameOrder = ["name", "id_no"]

    /// 登记一个错误事件：目标取 `order` 里第一个出错的字段（不在表单里的字段名排在最后，按出现顺序）。同一事件不重复登记。
    public mutating func arm(event: String, errors: [String], order: [String]) {
        guard event != handled, event != self.event, !errors.isEmpty else { return }
        let ranked = errors.enumerated().sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.element) ?? order.count + lhs.offset
            let right = order.firstIndex(of: rhs.element) ?? order.count + rhs.offset
            return left < right
        }
        self.event = event
        target = ranked.first?.element
    }

    /// `field` 的错误视图已出现（或随事件编号重新执行）：是待定位事件的目标就返回该事件（调用方滚动、移焦点、播报一次），之后不再返回。
    public mutating func appeared(_ field: String) -> String? {
        guard let event, field == target else { return nil }
        handled = event
        self.event = nil
        target = nil
        return event
    }
}
