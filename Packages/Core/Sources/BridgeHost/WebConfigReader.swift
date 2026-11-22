import Foundation

/// 从生效配置（/v1/config 的 data：current → LKG → 包内）里取两类容器与桥要用的取值。纯函数，缺字段一律按最保守的取值。
public enum WebConfigReader {
    /// app.getConfig 可以给 H5 的键（TODO(N-22)：契约没有登记 H5 白名单；保守地只给不含地址、规则表、客服、文案与法务版本的
    /// 展示类配置，与 Android 相同）。
    public static let h5ConfigKeys: Set<String> = ["features", "h5_release", "display", "claim", "help_links"]

    // 可信 H5 源不在这里读（N-22，D10-2539）：旧的「只读 bridge_origins 字符串数组」读法没有验签，已删除。白名单改为
    // ConfigStore 持有的验签通过的上次可用值（`ConfigStore.trustedOrigins`，验签见 `BridgeOriginsVerifier`）；h5_base_url 仍不当白名单。

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
