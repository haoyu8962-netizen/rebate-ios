import Foundation

/// 授权页隔离（03 §5.1「授权页不进容器」；APP-04 三端共性第 7 条）：初始地址与之后每一次导航都先过这里，命中即拦下。
/// 授权页登记表还没有进契约（TODO(N-22)），这里保守地内置常见登录授权域（Apple、微信 / QQ、华为、淘宝 / 支付宝、京东、
/// 抖音、微博、百度、Google），并对任何主机上的 OAuth 授权路径一律拦下：宁可多拦，不能因为「没命中联盟规则」就放行授权页。
/// 名单与 Android 同一份。
public enum AuthPages {
    /// 整域（含子域）命中即视为授权页。
    public static let hosts: Set<String> = [
        "appleid.apple.com", "idmsa.apple.com",
        "open.weixin.qq.com", "graph.qq.com", "xui.ptlogin2.qq.com",
        "oauth-login.cloud.huawei.com", "id1.cloud.huawei.com",
        "oauth.taobao.com", "oauth.m.taobao.com", "login.taobao.com", "login.m.taobao.com",
        "auth.alipay.com", "openauth.alipay.com",
        "oauth.jd.com", "open-oauth.jd.com", "passport.jd.com", "plogin.m.jd.com",
        "open.douyin.com", "api.weibo.com", "passport.baidu.com", "openapi.baidu.com", "accounts.google.com",
    ]

    /// 路径里出现这些段（不分大小写）即按授权页处理。
    private static let pathSegments: Set<String> = ["oauth", "oauth2", "authorize", "oauth2.0"]

    /// https 地址用与链接形态表同一套规范化（`NormalizedURL`：反斜杠、点段含 `%2e`、主机小写去末尾点，路径百分号解码一次），
    /// 所以 `%6fauth` 一类的编码绕不过去（三端共性第 35 条）。其他 scheme 按同样的步骤近似处理（容器本来就不加载它们）。
    public static func isAuthPage(_ url: String) -> Bool {
        let host: String
        let decoded: String
        if let normalized = NormalizedURL.parse(url) {
            host = normalized.host
            decoded = normalized.path.lowercased()
        } else {
            guard let components = URLComponents(string: NormalizedURL.browserForm(url)), let rawHost = components.host
            else { return false }
            host = BridgeProtocol.normalizeHost(rawHost)
            let path = NormalizedURL.removeDotSegments(components.percentEncodedPath)
            decoded = (path.removingPercentEncoding ?? path).lowercased()
        }
        if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return true
        }
        return decoded.split(separator: "/").contains { pathSegments.contains(String($0)) }
    }
}

/// external_page_nav_host 抽样埋点（BR-ATTR-29 细则「覆盖限制与待定事项」；APP-04 三端共性第 12 条）：只记注册域、框架类型与是否命中
/// 规则，不记路径与参数。采样率是 /v1/config external_page.nav_host_sample_bp（万分比，缺省 0 = 不报）。
public enum NavHostSample {
    public static let rollBound = 10000

    /// 二级公共后缀（常见国家域下的 com、net、org 等）。TODO(N-22)：没有公共后缀表，按这组常见情形近似（与 Android 相同）。
    private static let secondLevel: Set<String> = ["com", "net", "org", "gov", "edu", "co", "ac"]

    /// `roll` 取 0..<10000 的均匀随机数。
    public static func sampled(bp: Int, roll: Int) -> Bool {
        roll < min(max(bp, 0), rollBound)
    }

    /// 主机的注册域（eTLD+1 的近似）：小写、去掉末尾的点；IP 地址原样；取不到时为 nil。
    public static func registeredDomain(_ host: String?) -> String? {
        guard let host else { return nil }
        let clean = BridgeProtocol.normalizeHost(host)
        guard !clean.isEmpty else { return nil }
        let labels = clean.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let isIP = labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        if isIP || labels.count <= 2 {
            return clean
        }
        if secondLevel.contains(labels[labels.count - 2]), labels[labels.count - 1].count == 2 {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }
}

/// 商品回流（APP-04 三端共性第 8 条）：交给 Router 的商品意图带「去掉片段」的 URL。
public enum ProductIntentURL {
    public static func withoutFragment(_ url: String) -> String {
        url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? url
    }
}
