import Foundation

/// 从生效配置（/v1/config 的 data：current → LKG → 包内）里取两类容器与桥要用的取值。纯函数，缺字段一律按最保守的取值。
public enum WebConfigReader {
    /// app.getConfig 可以给 H5 的键（TODO(N-22)：契约没有登记 H5 白名单；保守地只给不含地址、规则表、客服、文案与法务版本的
    /// 展示类配置，与 Android 相同）。
    public static let h5ConfigKeys: Set<String> = ["features", "h5_release", "display", "claim", "help_links"]

    /// 可信 H5 源（TrustedWebView 只加载它们、桥只认它们）：**只取** bridge_origins 里的完整 https origin（APP-04 三端共性第 3 条）。
    /// h5_base_url 只是页面地址的前缀，不当白名单用。`configJson` 是 ConfigStore 的生效配置（当前版本 → 上一次成功拉取后写进
    /// App 私有目录的 LKG → 包内版本；包内没有 bridge_origins，所以没有服务端配置时白名单为空，WebPage 不打开）。
    /// TODO(N-22)：契约没有给 /v1/config 定义签名，无从「验签」；契约补上签名后，LKG 与当前版本验签失败时这里应得到空集。
    /// bridge_origins 在 openapi 里是 FreeForm、示例为 {}，形状未定；这里只接受「完整 origin 字符串的数组」，其他形状一律为空。
    public static func trustedOrigins(configJson: String) -> [String] {
        let config = JSONKind.object(configJson) ?? [:]
        return JSONKind.strings(config, "bridge_origins").compactMap(BridgeProtocol.normalizeOrigin)
    }

    /// 自有分享域（share.open 的第 ② 步，整主机相等）。
    public static func shareDomains(configJson: String) -> [String] {
        JSONKind.strings(JSONKind.object(configJson) ?? [:], "share_domains").map(BridgeProtocol.normalizeHost)
    }

    /// nav_host_sample_bp 没有下发时的缺省值（BR-ATTR-29，三端共性第 39 条）。
    public static let defaultNavHostSampleBp = 1000

    /// external_page.nav_host_sample_bp（万分比，0–10000）；缺失或不是整数按缺省 1000；服务端显式下发 0 即关闭采样。
    public static func navHostSampleBp(configJson: String) -> Int {
        let page = JSONKind.object(configJson)?["external_page"] as? [String: Any]
        guard let number = JSONKind.number(page?["nav_host_sample_bp"]), JSONKind.isInteger(number) else {
            return defaultNavHostSampleBp
        }
        return min(max(number.intValue, 0), NavHostSample.rollBound)
    }

    /// features.flags 里的布尔开关；缺失或不是布尔为 `defaultValue`。
    public static func flag(configJson: String, name: String, defaultValue: Bool) -> Bool {
        let features = JSONKind.object(configJson)?["features"] as? [String: Any]
        return JSONKind.bool((features?["flags"] as? [String: Any])?[name]) ?? defaultValue
    }

    /// app.getConfig：只返回 H5 白名单里的键（openapi：Subset of /v1/config limited to the keys whitelisted for H5）。
    public static func h5Values(configJson: String, keys: [String]) -> [String: Any] {
        let config = JSONKind.object(configJson) ?? [:]
        var values: [String: Any] = [:]
        for key in keys where h5ConfigKeys.contains(key) {
            if let value = config[key] {
                values[key] = value
            }
        }
        return values
    }
}
