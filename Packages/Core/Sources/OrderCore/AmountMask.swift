import Foundation

/// 金额隐藏（BR-TEXT-10 细则「金额隐藏」，G21）：本机偏好（不随账号，卸载即清），订单列表与详情的眼睛按钮切换；APP-09 的「我的」、钱包复用
/// 同一份。隐藏后预估返、实返、推广收益、扣回、返利显示「****」，实付与已付定金不隐藏；接口与计算不变。
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
