import Combine
import CouliNetwork
import Foundation
import Generated
@testable import HomeCore
import Router
import XCTest

// 首页执行器测试的替身（本机、确定性；不连网、不睡）。只把端口换成替身：控制器、存储、策略都是生产实现。
// 计数一律在端口入口同步记录（清单 C「计数在调用入口」）；完成信号用生产的 `HomeController.whenIdle()`。

/// 向量文件与常用换算。
enum HomeVectors {
    typealias JSONObject = [String: Any]

    static func root() throws -> JSONObject {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().standardizedFileURL
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { throw failure("向上找不到 contract.lock") }
            directory = parent
        }
        let url = directory.appendingPathComponent("specs/home-sdui-vectors.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? JSONObject, "向量根不是对象")
    }

    static func golden(_ name: String, _ root: JSONObject? = nil) throws -> JSONObject {
        let all = try XCTUnwrap((root ?? self.root())["goldenPages"] as? JSONObject)
        return try XCTUnwrap(all[name] as? JSONObject, "goldenPages 没有 \(name)")
    }

    static func goldenData(_ name: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: golden(name), options: [.sortedKeys])
    }

    /// 带 +08:00 的时刻 → 绝对毫秒。
    static func millis(_ iso: String) throws -> Int64 {
        guard iso.hasSuffix("+08:00") else { throw failure("时刻必须带 +08:00：\(iso)") }
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: iso), "非法 ISO 时刻 \(iso)")
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func canonical(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    static func data(_ object: JSONObject) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "HomeVectors", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// 测试页面与数据（商品数字照 Main 稿；文字都是明显的测试值）。
enum HomeKit {
    typealias JSONObject = [String: Any]

    /// 2026-10-10 12:00（上海）。
    static let noon: Int64 = 1_791_604_800_000

    static func page(version: Int, _ sections: [JSONObject]) -> JSONObject {
        ["page_key": "home", "version": version, "sections": sections]
    }

    static func banner(
        _ id: String, images: [String] = ["https://img.example.com/b1.png"], adLabel: Any? = nil,
        autoplay: Int = 0, action: JSONObject = ["route": "Help"], condition: Any? = nil
    ) -> JSONObject {
        var section: JSONObject = [
            "id": id, "type": "banner", "version": 1,
            "props": ["height_ratio": 0.4, "autoplay_ms": autoplay],
            "data_source": ["kind": "static", "items": images.map { ["image": $0, "action": action] }],
        ]
        if let adLabel {
            section["ad_label"] = adLabel
        }
        if let condition {
            section["condition"] = condition
        }
        return section
    }

    static func activity(_ id: String, titles: [String], action: JSONObject = ["route": "Help"]) -> JSONObject {
        [
            "id": id, "type": "activity_entry", "version": 1, "props": [:] as JSONObject,
            "data_source": ["kind": "static", "items": titles.map { ["title": $0, "action": action] }],
        ]
    }

    static func notice(_ id: String, items: [JSONObject], mode: String? = nil) -> JSONObject {
        var props: JSONObject = ["items": items]
        if let mode {
            props["mode"] = mode
        }
        return ["id": id, "type": "notice_bar", "version": 1, "props": props, "data_source": ["kind": "static"]]
    }

    static func noticeApi(_ id: String) -> JSONObject {
        ["id": id, "type": "notice_bar", "version": 1, "props": ["mode": "static"], "data_source": ["kind": "api"]]
    }

    static func noticeItem(
        _ itemId: String, version: Int = 1, closable: Bool = true, start: String = "2026-10-01T00:00:00+08:00",
        end: String? = nil, text: String = "测试公告", target: JSONObject? = nil
    ) -> JSONObject {
        [
            "item_id": itemId, "content_version": version, "text": text,
            "target": target.map { $0 as Any } ?? NSNull(), "closable": closable, "start_at": start,
            "end_at": end.map { $0 as Any } ?? NSNull(),
        ]
    }

    static func popup(
        _ id: String = "popup", image: String = "https://img.example.com/popup.png", dailyMax: Int = 1,
        window: [String] = ["09:00", "22:00"], action: JSONObject? = [
            "route": "AuthSheet",
            "params": ["platform": "taobao"],
        ]
    ) -> JSONObject {
        [
            "id": id, "type": "popup", "version": 1,
            "props": ["image": image, "daily_max": dailyMax, "time_window": window],
            "data_source": ["kind": "static", "items": action.map { [["action": $0]] } ?? []],
        ]
    }

    static func pool(_ id: String, type: String = "product_scroll", adLabel: Any? = nil) -> JSONObject {
        let props: JSONObject = type == "product_grid" ? ["columns": 2, "title": "超市百货"] : ["title": "今日精选"]
        var section: JSONObject = [
            "id": id, "type": type, "version": 1, "props": props,
            "data_source": ["kind": "product_pool", "pool_id": "test_\(id)", "limit": 20],
        ]
        if let adLabel {
            section["ad_label"] = adLabel
        }
        return section
    }

    static func feed(_ id: String = "feed") -> JSONObject {
        [
            "id": id, "type": "feed_infinite", "version": 1,
            "data_source": ["kind": "union_material", "platforms": ["taobao", "jd", "pdd"], "mix": "interleave"],
        ]
    }

    // swiftlint:disable:next large_tuple
    private static let samples: [(platform: String, title: String, price: Int64, coupon: Int64, rebate: Int64)] = [
        ("taobao", "林间果 每日坚果 30袋", 2290, 300, 110),
        ("jd", "洁澄 洗衣液 3kg 薰衣草香", 2680, 0, 90),
        ("taobao", "洗衣凝珠 52 颗 持久留香 低泡易漂", 1860, 300, 78),
        ("jd", "电动牙刷替换刷头 4 支装 软毛通用款", 3200, 0, 160),
        ("taobao", "抽纸 3 层 120 抽 × 24 包 家用整箱装", 1734, 500, 56),
        ("pdd", "厨房纸巾 4 卷 加厚 吸油吸水", 1290, 300, 30),
    ]

    /// 契约 ProductCard 形状的测试商品（product_key 是 `test:p<index>`）。
    static func product(_ index: Int, key: String? = nil, adLabel: Any? = nil) -> JSONObject {
        let sample = samples[index % samples.count]
        var card: JSONObject = [
            "product_key": key ?? "test:p\(index)", "item_ref": "v1.test.p\(index).sig", "platform": sample.platform,
            "title": sample.title, "image": "https://img.example.com/p/\(index).png", "shop_name": "示例旗舰店",
            "price_fen": sample.price, "coupon_fen": sample.coupon, "final_price_fen": sample.price - sample.coupon,
            "est_net_price_fen": sample.price - sample.coupon - sample.rebate, "rebate_min_fen": sample.rebate,
            "rebate_max_fen": sample.rebate, "rebate_basis": "normal",
            "benefit_tags": sample.coupon > 0 ? ["有券"] : [], "is_presale": false, "link_id": "link.p\(index)",
            "cta": ["text_key": "btn.buy"], "quoted_at": "2026-10-10T10:00:00+08:00", "stale": false, "age_sec": 30,
            "source": "\(sample.platform)_union",
            "disclaimer_keys": [sample.coupon > 0 ? "price_basis" : "price_basis.general", "rebate_estimate"],
            "availability": "ok",
        ]
        if let adLabel {
            card["ad_label"] = adLabel
        }
        return card
    }

    /// 契约合法的零返利商品（rebate_basis = no_rebate，返利 0，到手价 = 券后价）；过滤只由服务端决定，客户端照样显示。
    static func zeroRebateProduct(_ index: Int) -> JSONObject {
        var card = product(index, key: "test:z\(index)")
        let final = card["final_price_fen"] ?? 0
        card["rebate_min_fen"] = 0
        card["rebate_max_fen"] = 0
        card["rebate_basis"] = "no_rebate"
        card["est_net_price_fen"] = final
        card["disclaimer_keys"] = ["price_basis"]
        return card
    }

    /// 零返利与正返利混排的一页（顺序：p0、z1、p2、z3、z4、p5）。
    static func mixedRebateItems(next: String?) -> ApiResult {
        let cards: [JSONObject] = [
            product(0),
            zeroRebateProduct(1),
            product(2),
            zeroRebateProduct(3),
            zeroRebateProduct(4),
            product(5),
        ]
        return ok(["items": cards, "next_cursor": next.map { $0 as Any } ?? NSNull()])
    }

    static let mixedRebateKeys = ["test:p0", "test:z1", "test:p2", "test:z3", "test:z4", "test:p5"]

    static func items(_ range: Range<Int>, next: String?) -> ApiResult {
        ok(["items": range.map { product($0) }, "next_cursor": next.map { $0 as Any } ?? NSNull()])
    }

    static func ok(_ data: JSONObject, trace: String = "trace-test-000001") -> ApiResult {
        .success(data: HomeVectors.data(data), traceId: trace, idempotencyKey: nil)
    }

    /// 业务错误（经生产的 ErrorActionMapper 得到 effect；42901 的 Retry-After 按真实头解析）。
    static func failure(_ code: Int, retryAfter: String? = nil, trace: String? = "trace-test-ABC123") -> ApiResult {
        let operation = ApiOperations.byId("listArticles")!
        let headers = retryAfter.map { ["Retry-After": $0] } ?? [:]
        let effect = ErrorActionMapper.map(ErrorActionInput(
            code: code, data: [:], operation: operation, headers: headers, isReplay: false,
            state: ErrorActionState(update: "supported", sessionScope: "full", appVersion: "1.10.0")
        ))
        return .failure(code: code, msg: "test", data: nil, traceId: trace, effect: effect, idempotencyKey: nil)
    }

    static let offline = ApiResult.transportFailure(
        kind: "disconnect", httpStatus: nil, idempotencyKey: nil, pendingKeyUnknown: false
    )
    static let timeout = ApiResult.transportFailure(
        kind: "timeout", httpStatus: nil, idempotencyKey: nil, pendingKeyUnknown: false
    )
    static let http500 = ApiResult.transportFailure(
        kind: "no_envelope", httpStatus: 500, idempotencyKey: nil, pendingKeyUnknown: false
    )

    /// listArticles(category=notice) 的两条测试公告（data 形状 ArticleListData）。
    static func notices(_ items: [JSONObject]? = nil) -> ApiResult {
        let list = items ?? [
            noticeItem("api1", text: "确认收货后，返利随联盟月度结算入账"),
            noticeItem("api2", closable: false, end: "2099-01-01T00:00:00+08:00", text: "测试公告：国庆期间结算顺延"),
        ]
        return ok([
            "items": list.enumerated().map { index, notice in
                [
                    "article_id": "a\(index + 1)", "category": "notice", "title": "t", "version": 1,
                    "published_at": "2026-10-01T00:00:00+08:00", "notice": notice,
                ] as JSONObject
            },
            "next_cursor": NSNull(),
        ])
    }
}
