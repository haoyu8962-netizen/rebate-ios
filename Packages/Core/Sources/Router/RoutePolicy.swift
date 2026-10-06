import Foundation

/// 守卫用到的路由名单。名单的唯一维护处在规划，这里逐条注明出处；改名单先改规划与契约。
public enum RoutePolicy {
    public static let home = "Home"
    public static let login = "Login"
    public static let bindPhone = "BindPhone"
    public static let messages = "Messages"
    public static let forceUpdate = "ForceUpdate"
    public static let realName = "RealName"
    public static let externalPage = "ExternalPage"
    public static let webPage = "WebPage"

    /// 基本模式可达的路由：首页、搜索、商品详情与五个无需登录的页面（03 §4.4「无需登录的页面」，BR-ID-02）。
    public static let basicModeRoutes: Set<String> = [
        "Home", "Search", "ProductDetail", "Settings", "PrivacyCenter", "Agreement", "About", "Help",
    ]

    /// 强更检查结果未知时可打开的只读页面（BR-ID-10 细则「路由入口矩阵」）。
    public static let updateUnknownReadonlyRoutes: Set<String> = [
        "Home", "Search", "ProductDetail", "LinkLanding", "OrderList", "OrderDetail", "Wallet",
        "WithdrawRecords", "Ledger", "Earnings", "Messages", "Rules", "Help", "Notice", "Agreement", "About",
    ]

    /// 低于最低版本时只放行从强更页进入的这几个路由（03 §4.1）。
    public static let forceUpdateSecondaryRoutes: Set<String> = [
        "PrivacyCenter", "Agreement", "Login", "DeleteAccount",
    ]

    /// 不登记 pending_action 的路由：四个需二次验证的操作及其前置步骤（BR-ID-10 细则「不适用的动作」）。
    /// 缺前置时只进前置页，完成后回到发起页，由用户重新点击。
    public static let noPendingActionRoutes: Set<String> = [
        "Withdraw", "PayoutAccount", "LaborAgreement", "RealName", "DeleteAccount",
    ]

    /// 资金与实名页面：丢弃全部传入参数后照常打开（03 §4.4「资金与实名页面」，BR-WDR-01）。
    public static let paramsDroppedRoutes: Set<String> = [
        "Withdraw", "PayoutAccount", "LaborAgreement", "RealName",
    ]
}

/// 版本号比较：按点分隔的十进制整数逐段比较，缺的段按 0。
enum AppVersion {
    /// `version` 不低于 `minimum` 时为 true；任一方解析不了按 false（保守：当作版本过低）。
    static func isAtLeast(_ version: String, _ minimum: String) -> Bool {
        guard let lhs = parse(version), let rhs = parse(minimum) else {
            return false
        }
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left > right
            }
        }
        return true
    }

    private static func parse(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else {
                return nil
            }
            numbers.append(number)
        }
        return numbers
    }
}
