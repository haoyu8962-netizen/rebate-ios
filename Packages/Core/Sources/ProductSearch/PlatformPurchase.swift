import Foundation

/// 平台购买状态（`/v1/config.features.platform_status.<platform>`，契约 PlatformPurchaseStatus；APP-06a R2-01）。
/// 03 §7.4 购买流程 50301 一行：「点击前卡片状态取 platform_status，点击时以 open 的响应为准」；BR-TEXT-14 表 B：
/// maintenance → 购买按钮置灰「稍后再试」；not_launched → 购买按钮置灰并显示「{platform_name}返利即将开放」。
public enum PlatformPurchase: String, Sendable, Equatable {
    case on
    case maintenance
    case notLaunched = "not_launched"

    /// 原始取值 → 状态。TODO(N-27)：三层配置都没有该平台、或取值不在契约枚举里时怎么显示未规定；这里按 on
    /// （点击前不拦，点击时以 open 的 50301 为准，03 §7.4），rule-gaps 已登记。
    public static func parse(_ raw: String?) -> PlatformPurchase {
        raw.flatMap(PlatformPurchase.init(rawValue:)) ?? .on
    }

    /// 能否发出购买意图。
    public var allowsBuy: Bool {
        self == .on
    }
}

/// 详情页与搜索列表读平台购买状态的配置能力（生产为 App 的 AppConfig → ConfigStore.platformStatus；测试用假实现）。
@MainActor
public protocol PurchaseStatusSource: AnyObject {
    /// `features.platform_status.<platform>` 的原始取值（当前 → LKG → 包内逐个平台回落）；没有为 nil。
    func purchaseStatus(platform: String) -> String?
    /// 订阅配置变化（含 304 确认）；返回的令牌释放或 cancel 时注销。
    func observePurchaseStatus(_ handler: @escaping @MainActor () -> Void) -> SearchObservation
}

public extension PurchaseStatusSource {
    /// 此刻的状态（每次现取，不用缓存的旧值）。
    func purchase(platform: String) -> PlatformPurchase {
        PlatformPurchase.parse(purchaseStatus(platform: platform))
    }
}
