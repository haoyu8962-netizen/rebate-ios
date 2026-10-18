import Combine
import CouliNetwork
import Foundation
@testable import Home
import HomeCore
import XCTest

/// 截图用的本机替身（商品数字照 Main 稿；图片一律当作已加载）。
@MainActor
enum SnapshotKit {
    static func goldenPages() throws -> [String: Any] {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            directory = directory.deletingLastPathComponent()
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("specs/home-sdui-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["goldenPages"] as? [String: Any])
    }

    /// Main 稿的组合页（公告、轮播、金刚区、今日精选、双入口、超市百货、商品流）；字段与 goldenPages 同一套。
    static func main(withPopup: Bool = false) throws -> [String: Any] {
        let pages = try goldenPages()
        func sections(_ name: String) -> [Any] {
            ((pages[name] as? [String: Any])?["sections"] as? [Any]) ?? []
        }
        var all: [Any] = [[
            "id": "notice_main", "type": "notice_bar", "version": 1,
            "props": ["items": [[
                "item_id": "n1", "content_version": 1, "text": "确认收货后，返利随联盟月度结算入账", "target": NSNull(),
                "closable": true, "start_at": "2026-10-01T00:00:00+08:00", "end_at": NSNull(),
            ]]],
            "data_source": ["kind": "static"],
        ]]
        for name in ["banner", "default_home", "product_scroll", "product_grid", "feed_infinite"] {
            all += sections(name)
        }
        if withPopup {
            all += sections("popup")
        }
        return ["page_key": "home", "version": 31, "sections": all]
    }

    static func deps(page: [String: Any], defaults: UserDefaults) -> HomeDeps {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-snap-\(UUID().uuidString)")
        let time: @Sendable () -> Int64 = { 1_791_604_800_000 }
        return HomeDeps(
            port: SnapshotPort(page: page), articles: SnapshotArticles(), lkg: HomeLkgStore(root: root),
            prefs: HomePrefsStore(defaults: defaults), signals: SnapshotSignals(), timers: SnapshotTimers(),
            clock: time,
            images: SnapshotImages(), bundled: { HomeBundled.data() }, appVersion: "1.10.0",
            gate: RetryAfterGate(clock: time), dedupe: CardErrorDedupeBox(), track: { _ in }, open: { _ in },
            forceUpdate: {}, text: { key, _ in SnapshotTexts.values[key] ?? HomeTextDrafts.values[key] ?? key }
        )
    }
}

private final class SnapshotPort: HomeContractPort, @unchecked Sendable {
    private let data: Data

    init(page: [String: Any]) {
        data = (try? JSONSerialization.data(withJSONObject: page, options: [.sortedKeys])) ?? Data()
    }

    func getPage(pageKey _: String, call _: HomeCall) async -> ApiResult {
        .success(data: data, traceId: nil, idempotencyKey: nil)
    }

    func listSectionItems(pageKey _: String, sectionId _: String, cursor _: String?,
                          call _: HomeCall) async -> ApiResult {
        let items: [[String: Any]] = SnapshotSample.all.enumerated().map { index, sample in
            sample.card(index)
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["items": items, "next_cursor": NSNull()])) ?? Data()
        return .success(data: data, traceId: nil, idempotencyKey: nil)
    }
}

/// 截图用文案（第 4 版，P2）：口径说明三句照 BR-PRICE-03 / 17 默认文案（与搜索页草稿表同一句）。实现若经注入的文案函数取口径说明，
/// 截图里显示的是文案而不是键名。
enum SnapshotTexts {
    static let values: [String: String] = [
        "price_basis": "券后价按单件计算，不含运费及会员价等优惠，以下单页为准",
        "price_basis.general": "价格按单件计算，不含运费及会员价等优惠，以下单页为准",
        "rebate_estimate": "预估返利以平台结算为准，未结算或订单失效时不返",
    ]
}

/// 截图商品（Main 稿的数字）。
private struct SnapshotSample {
    let platform: String
    let title: String
    let price: Int64
    let coupon: Int64
    let rebate: Int64

    static let all = [
        SnapshotSample(platform: "taobao", title: "林间果 每日坚果 30袋", price: 2290, coupon: 300, rebate: 110),
        SnapshotSample(platform: "jd", title: "洁澄 洗衣液 3kg 薰衣草香", price: 2680, coupon: 0, rebate: 90),
        SnapshotSample(platform: "taobao", title: "洗衣凝珠 52 颗 持久留香 低泡易漂", price: 1860, coupon: 300, rebate: 78),
        SnapshotSample(platform: "pdd", title: "厨房纸巾 4 卷 加厚 吸油吸水", price: 1290, coupon: 300, rebate: 30),
    ]

    func card(_ index: Int) -> [String: Any] {
        [
            "product_key": "test:p\(index)", "item_ref": "v1.test.p\(index).sig", "platform": platform, "title": title,
            "image": "https://img.example.com/p/\(index).png", "shop_name": "示例旗舰店", "price_fen": price,
            "coupon_fen": coupon, "final_price_fen": price - coupon, "est_net_price_fen": price - coupon - rebate,
            "rebate_min_fen": rebate, "rebate_max_fen": rebate, "rebate_basis": "normal",
            "benefit_tags": coupon > 0 ? ["有券"] : [], "is_presale": false, "link_id": "link.p\(index)",
            "cta": ["text_key": "btn.buy"], "quoted_at": "2026-10-10T10:00:00+08:00", "stale": false, "age_sec": 30,
            "source": "\(platform)_union",
            "disclaimer_keys": [coupon > 0 ? "price_basis" : "price_basis.general", "rebate_estimate"],
            "availability": "ok",
        ]
    }
}

private final class SnapshotArticles: HomeArticlesApi, @unchecked Sendable {
    func send(
        _: ApiCall, isValid _: @escaping @Sendable () -> Bool, sendAllowed _: @escaping @Sendable () -> Bool,
        expected _: RequestOwnership?
    ) async -> ApiResult {
        let notice: [String: Any] = [
            "item_id": "api1", "content_version": 1, "text": "确认收货后，返利随联盟月度结算入账", "target": NSNull(),
            "closable": true, "start_at": "2026-10-01T00:00:00+08:00", "end_at": NSNull(),
        ]
        let article: [String: Any] = [
            "article_id": "a1", "category": "notice", "title": "t", "version": 1,
            "published_at": "2026-10-01T00:00:00+08:00", "notice": notice,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: ["items": [article], "next_cursor": NSNull()])) ??
            Data()
        return .success(data: data, traceId: nil, idempotencyKey: nil)
    }
}

@MainActor
private final class SnapshotSignals: HomeSignals {
    let visible = true
    /// 第 6 版（T-06）：截图固定轮播帧。生产规则是读屏开启时不自动轮播（HomeController 渲染时 autoplay = 可见且非读屏），这里报读屏
    /// 开启，轮播停在第一帧，等图片时跨过轮播间隔也不会换帧；其余渲染不读这个值。
    let screenReader = true

    func blockers() -> Set<String> {
        []
    }

    var changed: AnyPublisher<Void, Never> {
        Empty().eraseToAnyPublisher()
    }
}

@MainActor
private final class SnapshotTimers: HomeTimers {
    func after(_: Int64, _: @escaping @MainActor () -> Void) -> HomeTimerHandle {
        HomeTimerHandle {}
    }
}

private final class SnapshotImages: HomeImageLoader, Sendable {
    func load(_ url: String) async -> Bool {
        url.hasPrefix("https://")
    }
}

extension HomeUiState {
    func section(_ id: String) -> HomeSectionUi? {
        sections.first { $0.id == id }
    }
}
