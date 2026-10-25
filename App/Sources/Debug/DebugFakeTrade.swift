#if DEBUG
import Foundation
import Trade
import TradeJump

/// 本机假服务的购买场景（APP-06b 截图、冒烟与设计稿比对用；只在 Debug / Staging 编译，APP-04 共性 2）。由 `DebugFakeLoginServer`
/// （启动参数 `-CouliFakeLoginServer`）接管时回答；Release 制品扫描查 `marker` 与类名。全部在本机回答，不连任何地址、不做付款。
///
/// - 商品：详情 `tb:t-<场景>`（Product 画板的牛奶：券后 ¥46.78、预估返 ¥1.23–¥2.34）、`jd:t-browser`（保温杯）、`pdd:t-compare`
///   （抽纸 ¥12.34）；link_id = `t-<场景>`。搜索关键词「购买 / buy」回这几张卡（列表上的购买）。
/// - openLink 按 link_id 的场景回答（替换后的 link `t-<场景>-r1` 按未变回答）：
///   `t-ok` 未变（方案 sdk → universal_link → copy_tpwd）、`t-price` 改价、`t-pricegone` 改价且返利归零、`t-gone` 返利归零、
///   `t-coupon` 券失效、`t-compare` 比价无返利、`t-requote` 复核失败照常外跳、`t-slow` 第一次 10 秒（> 8 秒）、同键重发立即回答
///   （同一个 attempt_id）、`t-auth` 30101（web_code）→ 绑定后正常、`t-unavail` 30101 auth_unavailable、`t-pdd` 30111、
///   `t-sdk` 只有 sdk、`t-noinst` 只有 scheme、`t-browser` h5（京东）、`t-maint` / `t-notlaunched` 50301、`t-busy` 42901、
///   `t-blocked` 30153、`t-503` 50303、`t-offshelf` 30141、`t-expired` 30144、`t-norebate` 30103、`t-rebind` 30151
///   （APP-06v-b：30153 类第三种，版式同 30153）。没有 Authorization 头 →
/// 10001。
/// - getTips / markTipRead、listUnionBindings、getUnionAuthUrl、bindUnion 在内存里记状态（每次冷启动重置）。
/// - 启动参数：`-CouliFakeTradeLoggedIn`（冷启动直接是已登录的假账号）、`-CouliFakeTradeNoExternal`（不真的拉起外部 App / 浏览器，
///   截图用）、`-CouliFakeInstalled taobao=false`（假安装状态）、`-CouliFakeTaobaoBinding blocked|active`、`-CouliFakeTipsRead`。
enum DebugFakeTrade {
    static let marker = "COULI_FAKE_TRADE_SERVER_APP06B_IOS_5d81a7"
    static let loggedInArgument = "-CouliFakeTradeLoggedIn"

    private static let lock = NSLock()
    private nonisolated(unsafe) static var taobaoBinding = ""
    private nonisolated(unsafe) static var tipsRead: Set<String> = []
    private nonisolated(unsafe) static var answeredKeys: Set<String> = []
    private nonisolated(unsafe) static var attemptSeq = 0
    private nonisolated(unsafe) static var attempts: [String: String] = [:]
    /// open 已经回过改价的场景：之后的商品详情（重取补齐）按新报价回答。
    private nonisolated(unsafe) static var repriced: Set<String> = []

    struct Answer {
        let code: Int
        let data: String
        var headers: [String: String] = [:]
        var delay: TimeInterval = 0.4
    }

    /// 冷启动时（假服务打开）调用：按启动参数准备会话与状态。
    static func prepare(arguments: [String] = ProcessInfo.processInfo.arguments) {
        lock.withLock {
            taobaoBinding = UserDefaults.standard.string(forKey: "CouliFakeTaobaoBinding") ?? "unbound"
            tipsRead = arguments.contains("-CouliFakeTipsRead") ? ["taobao", "jd", "pdd"] : []
            answeredKeys = []
            repriced = []
            attempts = [:]
        }
    }

    /// 外跳端口：假服务打开时把系统实现包进 `DebugJumpPorts`（按启动参数给假安装状态、不真的离开 App），否则原样返回。
    @MainActor
    static func ports(wrapping system: AppJumpPorts) -> JumpPorts {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(DebugFakeLoginServer.launchArgument) else { return system }
        let ports = DebugJumpPorts(system: system)
        ports.debugNoExternal = arguments.contains(DebugJumpPorts.noExternalArgument)
        if let raw = UserDefaults.standard.string(forKey: DebugJumpPorts.installedDefaultsKey) {
            var map: [String: String] = [:]
            for pair in raw.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    map[parts[0]] = parts[1]
                }
            }
            ports.debugInstalled = { map[$0] }
        }
        return ports
    }

    /// 假服务打开时用假 web_code 授权（不打开任何授权页，返回演示用的假授权码）；Release 不编译（TODO(N-28) A02 同口径）。
    @MainActor
    static func webCodeAuthorizer() -> WebCodeAuthorizer? {
        let arguments = ProcessInfo.processInfo.arguments
        // `-CouliFakeWebCodeUnavailable`：按生产包（web_code 不可执行）走授权失败（截 ProductAuthFailed 用）
        guard arguments.contains(DebugFakeLoginServer.launchArgument),
              !arguments.contains("-CouliFakeWebCodeUnavailable")
        else { return nil }
        return FakeWebCode()
    }

    @MainActor
    private final class FakeWebCode: WebCodeAuthorizer {
        var available: Bool {
            true
        }

        func authorize(authUrl _: String, state _: String) async -> AuthStepResult {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return .credential(.webCode("debug-fake-auth-code"))
        }
    }

    // MARK: - 回答

    static func answer(path: String, query: [String: String], request: URLRequest, body: [String: Any]) -> Answer? {
        if path.hasPrefix("/v1/products/"), path.contains(":t-") {
            let key = String(path.dropFirst("/v1/products/".count)).removingPercentEncoding ?? ""
            return product(key).map { Answer(code: 0, data: DebugFakeSearch.json($0)) }
        }
        if path == "/v1/products/search", let keyword = query["q"],
           keyword.contains("购买") || keyword.contains("buy") || keyword.contains(":t-") {
            // 「tb:t-sdk」这样的关键词只回那一张卡（截图逐个场景进详情用）
            let keys = keyword.contains(":t-") ? [keyword]
                : ["tb:t-ok", "tb:t-price", "pdd:t-compare", "tb:t-slow", "tb:t-offshelf"]
            let items = keys.compactMap(product)
            return Answer(code: 0, data: DebugFakeSearch.json([
                "items": items, "next_cursor": NSNull(), "has_more": false, "fallback_items": [],
            ]))
        }
        if path.hasPrefix("/v1/links/"), path.hasSuffix("/open") {
            let link = String(path.dropFirst("/v1/links/".count).dropLast("/open".count))
            guard request.value(forHTTPHeaderField: "Authorization") != nil else {
                return Answer(code: 10001, data: "{}")
            }
            return open(link: link, key: request.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
        }
        return tips(path: path, body: body) ?? union(path: path)
    }

    private static func tips(path: String, body: [String: Any]) -> Answer? {
        switch path {
        case "/v1/me/tips":
            let read = lock.withLock { tipsRead }
            var jumpTip: [String: Any] = [:]
            for platform in read {
                jumpTip[platform] = "2026-10-02T09:30:00+08:00"
            }
            return Answer(code: 0, data: DebugFakeSearch.json(["jump_tip": jumpTip, "inviter_before_buy": NSNull()]))
        case "/v1/me/tips/jump_tip/read":
            if let platform = body["platform"] as? String {
                lock.withLock { _ = tipsRead.insert(platform) }
            }
            return Answer(code: 0, data: "{}")
        default:
            return nil
        }
    }

    private static func union(path: String) -> Answer? {
        switch path {
        case "/v1/unions/bindings":
            let taobao = lock.withLock { taobaoBinding }
            return Answer(code: 0, data: DebugFakeSearch.json(["items": [
                ["platform": "taobao", "status": taobao], ["platform": "pdd", "status": "unbound"],
            ]]))
        case "/v1/unions/taobao/auth-url":
            if lock.withLock({ taobaoBinding }) == "blocked" {
                return Answer(code: 30153, data: "{}")
            }
            return Answer(code: 0, data: authUrl)
        case "/v1/unions/pdd/auth-url":
            return Answer(code: 0, data: DebugFakeSearch.json([
                "auth_url": "https://auth.example.invalid/pdd?state=st_02", "state": "st_02", "auth_jump": authJump,
            ]))
        case "/v1/unions/taobao/bindings":
            lock.withLock { taobaoBinding = "active" }
            return Answer(code: 0, data: DebugFakeSearch.json(["platform": "taobao", "status": "active"]))
        default:
            return nil
        }
    }

    private static let authUrl = DebugFakeSearch.json([
        "auth_url": "https://oauth.example.invalid/authorize?state=st_01", "state": "st_01",
        "auth_methods": ["web_code"],
    ])

    private static var authJump: [String: Any] {
        [
            "primary": ["type": "h5", "value": "https://auth.example.invalid/pdd?state=st_02"], "fallbacks": [],
            "expire_at": expireAt,
        ]
    }

    private static var expireAt: String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(900))
    }

    // MARK: - open

    private static func open(link: String, key: String) -> Answer {
        let replaced = link.hasSuffix("-r1")
        let scenario = replaced ? String(link.dropLast(3)) : link
        if !replaced, let error = errorAnswer(scenario) {
            return error
        }
        let first = lock.withLock { answeredKeys.insert(key).inserted }
        let attempt = lock.withLock { () -> String in
            if let existing = attempts[key] {
                return existing
            }
            attemptSeq += 1
            let id = String(format: "0199a3b4-5c6d-7e8f-9a0b-%012d", attemptSeq)
            attempts[key] = id
            return id
        }
        var data: [String: Any] = [
            "attempt_id": attempt, "jump": plan(scenario), "price_changed": false, "old_final_price_fen": 4678,
            "new_final_price_fen": 4678, "new_link_id": NSNull(), "requote_failed": false,
            "new_rebate_min_fen": 123, "new_rebate_max_fen": 234, "availability": "ok",
            "quoted_at": ISO8601DateFormatter().string(from: Date()), "no_rebate_cause": NSNull(),
        ]
        var delay: TimeInterval = 0.6
        if !replaced {
            data.merge(overrides[scenario] ?? [:]) { $1 }
            if ["t-price", "t-pricegone", "t-coupon"].contains(scenario) {
                lock.withLock { _ = repriced.insert(scenario) }
            }
            if scenario == "t-slow" {
                delay = first ? 10 : 0.4
            }
        }
        return Answer(code: 0, data: DebugFakeSearch.json(data), delay: delay)
    }

    /// 各场景对 open 成功响应的改写。
    private static var overrides: [String: [String: Any]] {
        [
            "t-price": ["price_changed": true, "new_final_price_fen": 4990, "new_link_id": "t-price-r1",
                        "new_rebate_min_fen": 131, "new_rebate_max_fen": 250],
            "t-pricegone": ["price_changed": true, "new_final_price_fen": 4990, "new_link_id": "t-pricegone-r1",
                            "new_rebate_min_fen": 0, "new_rebate_max_fen": 0],
            "t-gone": ["new_rebate_min_fen": 0, "new_rebate_max_fen": 0],
            "t-coupon": ["availability": "coupon_gone", "new_final_price_fen": 5678, "new_link_id": "t-coupon-r1"],
            "t-compare": ["old_final_price_fen": 1234, "new_final_price_fen": 1234, "new_rebate_min_fen": 0,
                          "new_rebate_max_fen": 0, "no_rebate_cause": "price_compare"],
            "t-requote": ["requote_failed": true],
        ]
    }

    /// 各场景的错误回答（code, data）。
    private static let errors: [String: (Int, String)] = [
        "t-unavail": (30101, "{\"reason\":\"auth_unavailable\"}"),
        "t-maint": (50301, "{\"reason\":\"maintenance\",\"platform\":\"taobao\"}"),
        "t-notlaunched": (50301, "{\"reason\":\"not_launched\",\"platform\":\"taobao\"}"),
        "t-blocked": (30153, "{}"), "t-503": (50303, "{}"), "t-offshelf": (30141, "{}"), "t-expired": (30144, "{}"),
        "t-norebate": (30103, "{}"), "t-rebind": (30151, "{}"),
    ]

    private static func errorAnswer(_ scenario: String) -> Answer? {
        if let (code, data) = errors[scenario] {
            return Answer(code: code, data: data)
        }
        switch scenario {
        case "t-auth":
            return lock.withLock { taobaoBinding } == "active" ? nil : Answer(code: 30101, data: authUrl)
        case "t-pdd":
            return Answer(code: 30111, data: DebugFakeSearch.json(["auth_jump": authJump]))
        case "t-busy":
            return Answer(code: 42901, data: "{}", headers: ["Retry-After": "10"])
        default:
            return nil
        }
    }

    private static func plan(_ scenario: String) -> [String: Any] {
        let promo = "https://s.click.example.invalid/t?e=demo"
        let steps: [[String: Any]] = switch scenario {
        case "t-sdk": [["type": "sdk", "value": promo]]
        case "t-noinst": [["type": "scheme", "value": "taobao-demo://item?id=demo"]]
        case "t-browser", "t-compare": [["type": "h5", "value": "https://u.example.invalid/demo"]]
        default:
            [
                ["type": "sdk", "value": promo], ["type": "universal_link", "value": promo],
                ["type": "copy_tpwd", "value": "DEMO-TPWD-0001"],
            ]
        }
        return ["primary": steps[0], "fallbacks": Array(steps.dropFirst()), "expire_at": expireAt]
    }
}

// MARK: - 商品

extension DebugFakeTrade {
    private static func product(_ key: String) -> [String: Any]? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let scenario = parts[1]
        var card: [String: Any] = switch parts[0] {
        case "pdd":
            base(key: key, platform: "pdd", title: "云朵柔 抽纸 3 层 × 120 抽 24 包 家用整箱", price: 1534, coupon: 300,
                 rebate: (32, 32), estNet: 1202, shop: "云朵柔官方旗舰店")
        case "jd":
            base(key: key, platform: "jd", title: "保温杯 500ml 不锈钢 带茶隔 办公便携", price: 8900, coupon: 0,
                 rebate: (234, 234), estNet: 8666, shop: "家居生活自营店")
        default:
            base(key: key, platform: "taobao", title: "全脂纯牛奶 250ml × 24 盒 整箱装 早餐奶 学生奶", price: 5678,
                 coupon: 1000, rebate: (123, 234), estNet: 4555, shop: "乳品生活旗舰店")
        }
        card["link_id"] = scenario
        // 改价之后的权威报价（补齐券前价、券额用；与 open 响应的新券后价一致）
        if lock.withLock({ repriced.contains(scenario) }) {
            let fresh: [String: Any] = switch scenario {
            case "t-coupon": ["price_fen": 5678, "coupon_fen": 0, "final_price_fen": 5678, "est_net_price_fen": 5444]
            default: ["price_fen": 5990, "coupon_fen": 1000, "final_price_fen": 4990, "est_net_price_fen": 4859,
                      "rebate_min_fen": 131, "rebate_max_fen": 250]
            }
            card.merge(fresh) { $1 }
        }
        return card
    }

    // swiftlint:disable:next function_parameter_count
    private static func base(
        key: String, platform: String, title: String, price: Int, coupon: Int, rebate: (Int, Int), estNet: Int,
        shop: String
    ) -> [String: Any] {
        [
            "product_key": key, "item_ref": "debug-ref-" + key, "platform": platform, "title": title,
            "image": DebugFakeSearchImages.url(for: key), "price_fen": price, "coupon_fen": coupon,
            "final_price_fen": price - coupon, "est_net_price_fen": estNet,
            "rebate_min_fen": rebate.0, "rebate_max_fen": rebate.1, "rebate_basis": "normal",
            "benefit_tags": coupon > 0 ? ["有券"] : [], "is_presale": false,
            "cta": ["text_key": coupon > 0 ? "btn.buy.coupon" : "btn.buy"],
            "quoted_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-12)),
            "stale": false, "age_sec": 12, "source": "\(platform)_union",
            "disclaimer_keys": ["price_basis", "rebate_estimate"], "availability": "ok", "shop_name": shop,
        ]
    }
}
#endif
