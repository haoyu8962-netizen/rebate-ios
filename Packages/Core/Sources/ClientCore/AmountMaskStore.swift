import Combine
import Foundation

/// 金额隐藏（BR-TEXT-10 细则「金额隐藏」，APP-09 G23、G24）：本机偏好（不随账号、不随环境清除、不上传，卸载即清）。订单列表与详情、钱包页的
/// 眼睛按钮切换同一份；「我的」页（APP-12）以后也用它。隐藏后各页把规定的金额显示为「****」；接口与计算不变。
///
/// APP-08 建在 OrderCore，APP-09 按 G24 挪到共用的 ClientCore：存储（App 传入的 UserDefaults，生产为 `.standard`）与键
/// `amount_mask.hidden` 不变（不做迁移，iOS I10）；OrderCore 保留同名 typealias，订单页与 APP-08 的测试照常引用。
@MainActor
public final class AmountMaskStore: ObservableObject {
    public static let key = "amount_mask.hidden"
    @Published public private(set) var hidden: Bool
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = defaults.bool(forKey: Self.key)
    }

    public func toggle() {
        set(!hidden)
    }

    public func set(_ value: Bool) {
        hidden = value
        defaults.set(value, forKey: Self.key)
    }
}
