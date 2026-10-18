#if DEBUG
import Foundation
import Generated
import UIKit

/// 本机假服务的搜索与商品详情场景（APP-06a 截图、冒烟与设计稿比对用；只在 Debug / Staging 编译，APP-04 共性 2）。
/// 由 `DebugFakeLoginServer`（启动参数 `-CouliFakeLoginServer`）接管时回答；Release 制品扫描查 `marker` 与类名。
///
/// - `/v1/config`：包内配置原样，只把淘宝 / 京东 / 拼多多的 search_status 都设为 on（截三个 Tab 用；
///   启动参数 `-CouliFakeSearchAllOff` 时都设为 off；`-CouliFakePlatformStatus taobao=maintenance` 改平台购买状态）。
/// - 搜索：任意关键词第一页 3 张（Search 画板），has_more=true，第二页 2 张到底。关键词：
///   「空 / none」无结果 + 推荐 2 张；「慢 / slow」3 秒后回答；「失败 / fail」50401；「关闭 / disabled」京东回 50304 search_disabled；
///   「频繁 / busy」42901（Retry-After 10）；「翻页 / pageerr」第二页 50401；「状态 / states」详情各状态样例（无返利、
///   已下架 30141、信息失效 30143、缓存降级、价格不可用；拼多多 Tab 另有金额未知卡）。只看有券、价格区间、券后价排序在本机执行。
/// - 详情：`tb:milk` 回 Product 画板的数据；`*:offshelf` → 30141；`*:expired` → 30143；其余按搜索卡数据。
/// - 商品图（共性 22）：卡片 image 指向本机假图片地址（`DebugFakeSearchImages` 在本机生成图片回答，不连网）；
///   「状态」样例里无返利卡的图片地址回 404（失败占位）、价格不可用卡 image 为 null（空占位）。
enum DebugFakeSearch {
    static let marker = "COULI_FAKE_SEARCH_SERVER_APP06A_IOS_7c2d94"

    struct Answer {
        let code: Int
        let data: String
        var headers: [String: String] = [:]
        var delay: TimeInterval = 0.3
        var traceId = "0199a3b4-5c6d-7e8f-9a0b-1c2d3e0a1b2c"
    }

    static func config() -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(DefaultConfig.json.utf8))) as? [String: Any]
        else { return DefaultConfig.json }
        var features = object["features"] as? [String: Any] ?? [:]
        var status = features["search_status"] as? [String: Any] ?? [:]
        // `-CouliFakeSearchAllOff`：三个平台都关（截「无可搜索平台」用，共性 26）。
        let value = ProcessInfo.processInfo.arguments.contains("-CouliFakeSearchAllOff") ? "off" : "on"
        for platform in ["taobao", "jd", "pdd"] {
            status[platform] = value
        }
        features["search_status"] = status
        DebugFakeFlags.apply(to: &features)
        // `-CouliFakePlatformStatus taobao=maintenance,jd=not_launched`：改平台购买状态（R2-01 截图用；其余平台按包内配置）。
        if let raw = UserDefaults.standard.string(forKey: "CouliFakePlatformStatus") {
            var purchase = features["platform_status"] as? [String: Any] ?? [:]
            for pair in raw.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    purchase[parts[0]] = parts[1]
                }
            }
            features["platform_status"] = purchase
        }
        object["features"] = features
        return json(object)
    }

    static func answer(path: String, query: [String: String]) -> Answer? {
        if path == "/v1/products/search" {
            return search(query)
        }
        if path.hasPrefix("/v1/products/") {
            let key = String(path.dropFirst("/v1/products/".count)).removingPercentEncoding ?? ""
            return detail(key)
        }
        return nil
    }

    // MARK: - 搜索

    private static func search(_ query: [String: String]) -> Answer {
        let keyword = query["q"] ?? ""
        let platform = query["platform"] ?? "taobao"
        let page2 = query["cursor"] != nil
        func has(_ words: String...) -> Bool {
            words.contains { keyword.contains($0) }
        }
        if has("失败", "fail") {
            return Answer(code: 50401, data: "{}")
        }
        if has("频繁", "busy") {
            return Answer(code: 42901, data: "{}", headers: ["Retry-After": "10"])
        }
        if has("关闭", "disabled"), platform == "jd" {
            return Answer(code: 50304, data: json(["platform": "jd", "reason": "search_disabled"]))
        }
        if has("翻页", "pageerr"), page2 {
            return Answer(code: 50401, data: "{}")
        }
        if has("空", "none") {
            let data: [String: Any] = [
                "items": [], "next_cursor": NSNull(), "has_more": false, "fallback_items": fallback(platform),
            ]
            return Answer(code: 0, data: json(data))
        }
        var items = has("状态", "states") ? states(platform) : (page2 ? second(platform) : first(platform))
        items = filtered(items, query)
        let more = !page2 && !has("状态", "states")
        let data: [String: Any] = [
            "items": items, "next_cursor": more ? "debug-cursor-p2" : NSNull(), "has_more": more, "fallback_items": [],
        ]
        var answer = Answer(code: 0, data: json(data))
        if has("慢", "slow") {
            answer.delay = 3
        }
        return answer
    }

    private static func filtered(_ items: [[String: Any]], _ query: [String: String]) -> [[String: Any]] {
        var result = items
        if query["has_coupon"] == "true" {
            result = result.filter { ($0["coupon_fen"] as? Int ?? 0) > 0 }
        }
        if let min = query["price_min_fen"].flatMap(Int.init) {
            result = result.filter { ($0["final_price_fen"] as? Int).map { $0 >= min } ?? false }
        }
        if let max = query["price_max_fen"].flatMap(Int.init) {
            result = result.filter { ($0["final_price_fen"] as? Int).map { $0 <= max } ?? false }
        }
        if query["sort"] == "final_price_asc" {
            result.sort { ($0["final_price_fen"] as? Int ?? .max) < ($1["final_price_fen"] as? Int ?? .max) }
        }
        return result
    }

    private static func prefix(_ platform: String) -> String {
        ["taobao": "tb", "jd": "jd", "pdd": "pdd"][platform] ?? platform
    }

    private static func first(_ platform: String) -> [[String: Any]] {
        let pre = prefix(platform)
        return [
            card(platform, key: "\(pre):milk", title: "全脂纯牛奶 250ml × 24 盒 整箱装 早餐奶 学生奶 送礼礼盒款 生产日期新鲜",
                 price: 2345, coupon: 1000, rebate: (56, 112), estNet: 1289, tags: ["有券"],
                 keys: ["price_basis", "rebate_compare"]),
            card(platform, key: "\(pre):milk200", title: "纯牛奶 200ml × 12 盒 多规格可选",
                 price: 1234, coupon: 0, rebate: (0, 99), estNet: nil, tags: ["规格以下单页为准"],
                 keys: ["price_basis.general", "rebate_compare"], basis: "price_compare_risk"),
            card(platform, key: "\(pre):organic", title: "有机纯牛奶 250ml × 24 盒 预售 下月发货",
                 price: 9999, coupon: 0, rebate: (250, 500), estNet: 9749, tags: [], keys: ["price_basis.general"],
                 presale: true),
        ]
    }

    private static func second(_ platform: String) -> [[String: Any]] {
        let pre = prefix(platform)
        return [
            card(platform, key: "\(pre):paper", title: "抽纸 3 层 120 抽 × 24 包 家用整箱装",
                 price: 1734, coupon: 500, rebate: (56, 56), estNet: 1178, tags: ["有券"], keys: ["price_basis"]),
            card(platform, key: "\(pre):rice", title: "东北长粒香大米 10kg 新米",
                 price: 8800, coupon: 0, rebate: (321, 321), estNet: 8479, tags: [], keys: ["price_basis.general"]),
        ]
    }

    private static func fallback(_ platform: String) -> [[String: Any]] {
        second(platform)
    }

    private static func states(_ platform: String) -> [[String: Any]] {
        let pre = prefix(platform)
        var items: [[String: Any]] = [
            card(platform, key: "\(pre):norebate", title: "无返利商品：家用保温杯 500ml",
                 price: 5900, coupon: 1000, rebate: (0, 0), estNet: nil, tags: ["有券"], keys: ["price_basis"],
                 basis: "no_rebate", cta: "btn.buy.no_rebate", image: DebugFakeSearchImages.brokenURL),
            card(platform, key: "\(pre):offshelf", title: "已下架商品：电动牙刷", price: 19900, coupon: 0,
                 rebate: (500, 500), estNet: 19400, tags: [], keys: ["price_basis.general"]),
            card(platform, key: "\(pre):expired", title: "信息已失效的商品：猫粮 2kg", price: 6900, coupon: 0,
                 rebate: (200, 200), estNet: 6700, tags: [], keys: ["price_basis.general"]),
            card(platform, key: "\(pre):stale", title: "缓存降级报价：洗衣凝珠 52 颗", price: 4990, coupon: 500,
                 rebate: (120, 120), estNet: 4370, tags: ["有券"], keys: ["price_basis"], stale: true),
        ]
        var unavailable = card(platform, key: "\(pre):noprice", title: "价格不可用的商品：卷纸 27 卷", price: 0,
                               coupon: 0, rebate: (0, 0), estNet: nil, tags: [], keys: ["price_basis.general"])
        for field in ["price_fen", "coupon_fen", "final_price_fen", "est_net_price_fen", "rebate_min_fen",
                      "rebate_max_fen", "link_id"] {
            unavailable[field] = NSNull()
        }
        unavailable["availability"] = "price_unavailable"
        unavailable["image"] = NSNull()
        items.append(unavailable)
        if platform == "pdd" {
            items.append([
                "product_key": NSNull(), "item_ref": NSNull(), "platform": "pdd", "title": NSNull(), "image": NSNull(),
                "price_fen": NSNull(), "coupon_fen": NSNull(), "final_price_fen": NSNull(),
                "est_net_price_fen": NSNull(), "rebate_min_fen": NSNull(), "rebate_max_fen": NSNull(),
                "rebate_basis": "amount_unknown", "benefit_tags": [], "is_presale": false,
                "link_id": "0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a99", "cta": ["text_key": "btn.buy"],
                "quoted_at": NSNull(), "stale": false, "age_sec": NSNull(), "source": "pdd_union",
                "disclaimer_keys": [], "availability": "unknown",
            ])
        }
        return items
    }

    // MARK: - 剪贴板 parse（APP-07）

    /// `/v1/inputs/parse`：按上传片段（只有链接与「」标题）里的场景词回答——默认 1 张卡（详情样例卡 tb:milk）；`multi` 两条（1 张卡 +
    /// 1 条 30131）；`multi30132` 两条（1 张卡 + 1 条 30132）；`busy` 42901（Retry-After 10）；`fail` 50001；`unsupported` 30131；
    /// `unrec` 30132；`inline10405` 行内 10405；`slow` 3 秒后回答。全部在本机回答，不连任何地址。
    static func parse(_ body: [String: Any]) -> Answer {
        let text = body["text"] as? String ?? ""
        let trace = "0199a3b4-5c6d-7e8f-9a0b-1c2d3e000002"
        func has(_ word: String) -> Bool {
            text.contains(word)
        }
        if has("busy") {
            return Answer(code: 42901, data: "{}", headers: ["Retry-After": "10"], traceId: trace)
        }
        if has("fail") {
            return Answer(code: 50001, data: "{}", traceId: trace)
        }
        if has("unsupported") {
            return Answer(code: 30131, data: "{}", traceId: trace)
        }
        if has("unrec") {
            return Answer(code: 30132, data: "{}", traceId: trace)
        }
        var milk = card("taobao", key: "tb:milk", title: "全脂纯牛奶 250ml × 24 盒 整箱装 早餐奶 学生奶", price: 5678,
                        coupon: 1000, rebate: (123, 234), estNet: 4555, tags: ["有券"],
                        keys: ["price_basis", "rebate_estimate"])
        milk["shop_name"] = "乳品生活旗舰店"
        milk["link_id"] = "0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a99"
        let hit: [String: Any] = ["platform": "taobao", "kind": "url", "raw": "https://e.tb.cn/h.Demo01?tk=Sample"]
        var results: [[String: Any]] = [["hit": hit, "card": milk]]
        if has("multi30132") {
            results.append(["hit": ["platform": "taobao", "kind": "text", "raw": "「全脂纯牛奶 250ml」"], "error_code": 30132])
        } else if has("multi") {
            results.append(["hit": ["platform": "taobao", "kind": "url", "raw": "https://e.tb.cn/unsupported"],
                            "error_code": 30131])
        } else if has("inline10405") {
            results = [["hit": hit, "error_code": 10405]]
        }
        return Answer(code: 0, data: json(["results": results]), delay: has("slow") ? 3 : 0.3, traceId: trace)
    }

    // MARK: - 详情

    private static func detail(_ key: String) -> Answer {
        if key.hasSuffix(":offshelf") {
            return Answer(code: 30141, data: "{}")
        }
        if key.hasSuffix(":expired") {
            return Answer(code: 30143, data: "{}")
        }
        let platform = ["tb": "taobao", "jd": "jd", "pdd": "pdd"][String(key.split(separator: ":").first ?? "")]
            ?? "taobao"
        if key.hasSuffix(":milk") {
            var product = card(platform, key: key, title: "全脂纯牛奶 250ml × 24 盒 整箱装 早餐奶 学生奶", price: 5678,
                               coupon: 1000, rebate: (123, 234), estNet: 4555, tags: ["有券"],
                               keys: ["price_basis", "rebate_estimate"])
            product["shop_name"] = "乳品生活旗舰店"
            product["shop_type"] = "tmall"
            return Answer(code: 0, data: json(product))
        }
        let all = (first(platform) + second(platform) + states(platform))
        guard var product = all.first(where: { ($0["product_key"] as? String) == key }) else {
            return Answer(code: 30143, data: "{}")
        }
        product["shop_name"] = "示例旗舰店"
        return Answer(code: 0, data: json(product))
    }

    // MARK: - 工具

    // swiftlint:disable:next function_parameter_count
    private static func card(
        _ platform: String, key: String, title: String, price: Int, coupon: Int, rebate: (Int, Int), estNet: Int?,
        tags: [String], keys: [String], basis: String = "normal", presale: Bool = false, stale: Bool = false,
        cta: String? = nil, image: String? = nil
    ) -> [String: Any] {
        let final = price - coupon
        var benefit = tags
        if presale {
            benefit.append("预售")
        }
        return [
            "product_key": key, "item_ref": "debug-ref-" + key, "platform": platform, "title": title,
            "image": image ?? DebugFakeSearchImages.url(for: key), "price_fen": price, "coupon_fen": coupon,
            "final_price_fen": final, "est_net_price_fen": estNet ?? final,
            "rebate_min_fen": rebate.0, "rebate_max_fen": rebate.1, "rebate_basis": basis,
            "benefit_tags": benefit, "is_presale": presale, "link_id": "0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a70",
            "cta": ["text_key": cta ?? (coupon > 0 ? "btn.buy.coupon" : "btn.buy")],
            "quoted_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(stale ? -2160 : -12)),
            "stale": stale, "age_sec": stale ? 2160 : 12, "source": "\(platform)_union",
            "disclaimer_keys": keys, "availability": "ok",
        ]
    }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// 本机假商品图（APP-06a 共性 22，只在 Debug / Staging 编译）：系统 AsyncImage 走 URLSession.shared，所以在假服务启用时
/// 全局登记本类，只接管假图片主机的请求，按地址在本机画一张图回答；`brokenURL` 回 404（失败占位）。不连任何地址。
final class DebugFakeSearchImages: URLProtocol {
    static let host = "img.example.invalid"
    static let brokenURL = "https://\(host)/broken.png"

    static func url(for key: String) -> String {
        let name = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "p"
        return "https://\(host)/p/\(name).png"
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let broken = url.path.hasPrefix("/broken")
        let data = broken ? Data() : Self.image(seed: url.path)
        let response = HTTPURLResponse(
            url: url, statusCode: broken ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": broken ? "text/plain" : "image/png"]
        )
        client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// 按地址取色画一张 240×240 的示意商品图（底色 + 白色圆角瓶身 + 色块标签）。
    private static func image(seed: String) -> Data {
        let hue = CGFloat(seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240))
        let image = renderer.image { context in
            UIColor(hue: hue, saturation: 0.25, brightness: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 70, y: 40, width: 100, height: 160), cornerRadius: 18).fill()
            UIColor(hue: hue, saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 82, y: 100, width: 76, height: 50), cornerRadius: 8).fill()
        }
        return image.pngData() ?? Data()
    }
}
#endif
