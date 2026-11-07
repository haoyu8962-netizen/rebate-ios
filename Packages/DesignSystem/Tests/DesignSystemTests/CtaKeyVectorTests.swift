@testable import DesignSystem
import Foundation
import Generated
import XCTest

/// FU-X-CTA-KEY-DRIFT（D10-856 / D10-857）：商品卡 cta.text_key 的渲染与未知键兜底。
/// 规则与向量在 specs/cta-key-vectors.json（三端照抄，逐字节一致）；本文件跑向量，并另钉几条 iOS 侧的性质。
///
/// 被测接口（实现者按此提供；本文件不提供假实现）：
/// - `ProductCardMapper.map(_:texts:buyEnabled:nowMillis:onCtaFallback:)`：新增末位参数 `onCtaFallback: (String) -> Void`，
///   缺省值写系统诊断日志；每次映射遇到渲染不出的 cta 键调用一次，只给 text_key 原值。
/// - `ProductCardKeys.buyFallback`：兜底文案键 `btn.buy`。
/// - 列表卡 / 详情大卡按钮整行文字仍由 `BuyButtonModel.text(base:rebate:amountHidden:context:)` 组成（BuyButton.title 同一调用）。
final class CtaKeyVectorTests: XCTestCase {
    private static let now: Int64 = 1_794_022_200_000 // 2026-11-07 11:30:00 +08:00，固定

    // MARK: - 向量

    func testVectorFileShape() throws {
        let file = try loadVectors()
        XCTAssertEqual(file["version"] as? Int, 1)
        XCTAssertEqual(file["contractCommit"] as? String, "a89c1ec3a7f4de0b069742af909eba6545358ea3")
        let cases = try XCTUnwrap(file["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        let ids = cases.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids.count, cases.count, "每条都有 id")
        XCTAssertEqual(Set(ids).count, ids.count, "id 不重复")
        for row in cases {
            XCTAssertFalse((row["note"] as? String ?? "").isEmpty, "\(row["id"] ?? "?")：note 不能为空")
        }
    }

    func testVectors() throws {
        let file = try loadVectors()
        let base = try XCTUnwrap(file["baseCard"] as? [String: Any])
        let cases = try XCTUnwrap(file["cases"] as? [[String: Any]])
        for row in cases {
            let id = row["id"] as? String ?? "?"
            let label = "\(id)：\(row["note"] as? String ?? "")"
            var card = base
            for (key, value) in row["card"] as? [String: Any] ?? [:] {
                card[key] = value is NSNull ? nil : value
            }
            let texts = try textsFunction(row["texts"] as? String ?? "", label)
            let expect = try XCTUnwrap(row["expect"] as? [String: Any], label)
            var diagnostics: [String] = []
            let mapping = ProductCardMapper.map(
                card, texts: texts, buyEnabled: row["buyEnabled"] as? Bool ?? true, nowMillis: Self.now,
                onCtaFallback: { diagnostics.append($0) }
            )
            let data = mapping.data
            XCTAssertEqual(data.buyBase, expect["buyBase"] as? String, "\(label) buyBase")
            XCTAssertEqual(stateRaw(data.buyState), expect["state"] as? String, "\(label) state")
            if let key = expect["diagnostic"] as? String {
                XCTAssertEqual(diagnostics, [key], "\(label) 诊断恰好一条、只带 text_key")
            } else {
                XCTAssertEqual(diagnostics, [], "\(label) 不记诊断")
            }
            XCTAssertFalse(data.buyBase.contains("{") || data.buyBase.contains("}"), "\(label) 按钮不出现花括号")
            XCTAssertFalse(data.buyBase.hasPrefix("btn."), "\(label) 按钮不出现键名")
            for (context, title) in expect["title"] as? [String: String] ?? [:] {
                XCTAssertNotNil(BuyButtonContext(rawValue: context), "\(label) title 的页面名")
                let shown = BuyButtonModel.text(
                    base: data.buyBase, rebate: data.rebate, amountHidden: data.amountHidden, context: context
                )
                XCTAssertEqual(shown, title, "\(label) title.\(context)")
            }
        }
    }

    // MARK: - 性质（iOS 侧另钉）

    /// 锁内没有的 cta 键也能点：多种新键、多种 texts 写法，按钮都有字、状态 normal、不出现键名或花括号。
    func testAnyUnknownKeyIsTappableWithBuyText() {
        let keys = ["btn.buy.future_x", "btn.buy.rebate.v2", "cta.v4.buy_now", "x", "btn.buy.rebate_suffix.new",
                    "BTN.BUY", "btn.buy.{amount}", "购买按钮"]
        let modes: [(String, (String) -> String)] = [
            ("contract", { DefaultTexts.text($0) ?? "" }),
            ("echo", { DefaultTexts.text($0) ?? $0 }),
            ("none", { _ in "" }),
        ]
        for key in keys {
            for (mode, texts) in modes {
                var diagnostics: [String] = []
                let data = ProductCardMapper.map(
                    card(cta: key), texts: texts, nowMillis: Self.now, onCtaFallback: { diagnostics.append($0) }
                ).data
                XCTAssertEqual(data.buyBase, "购买", "\(key) / \(mode)")
                XCTAssertEqual(data.buyState, .normal, "\(key) / \(mode)：缺键本身不置灰")
                XCTAssertEqual(diagnostics, [key], "\(key) / \(mode)")
            }
        }
    }

    /// 兜底先经调用方的 texts 取 btn.buy（草稿 / 下发文案可覆盖），texts 给出可用文字就用它。
    func testFallbackGoesThroughCallerTextsFirst() {
        XCTAssertEqual(ProductCardKeys.buyFallback, "btn.buy")
        let texts: (String) -> String = { $0 == "btn.buy" ? "立即购买" : "" }
        let data = ProductCardMapper.map(card(cta: "btn.buy.future_x"), texts: texts, nowMillis: Self.now,
                                         onCtaFallback: { _ in }).data
        XCTAssertEqual(data.buyBase, "立即购买")
        XCTAssertEqual(data.buyState, .normal)
    }

    /// 诊断不带用户数据：只有 text_key 原值，不含标题、商品键、item_ref、link_id、店铺、价格。
    func testDiagnosticCarriesOnlyTheKey() {
        var raw = card(cta: "btn.buy.future_x")
        raw["title"] = "张三 13800001111 的收货地址"
        raw["shop_name"] = "某某旗舰店"
        var diagnostics: [String] = []
        _ = ProductCardMapper.map(raw, texts: { DefaultTexts.text($0) ?? "" }, nowMillis: Self.now,
                                  onCtaFallback: { diagnostics.append($0) })
        XCTAssertEqual(diagnostics, ["btn.buy.future_x"])
        let joined = diagnostics.joined()
        for secret in ["张三", "13800001111", "tb:cta", "ref-cta", "0199a3b4", "某某旗舰店", "2990", "29.9"] {
            XCTAssertFalse(joined.contains(secret), "诊断里不该有 \(secret)")
        }
    }

    /// 已知键不记诊断，也不改动原有键的取字（旧键保留不用但仍是字典原文）。
    func testKnownKeysLogNothing() {
        for key in ["btn.buy", "btn.buy.coupon", "btn.buy.no_rebate", "btn.buy.rebate"] {
            var diagnostics: [String] = []
            let data = ProductCardMapper.map(card(cta: key), texts: { DefaultTexts.text($0) ?? "" },
                                             nowMillis: Self.now, onCtaFallback: { diagnostics.append($0) }).data
            XCTAssertEqual(diagnostics, [], key)
            XCTAssertEqual(data.buyState, .normal, key)
            XCTAssertFalse(data.buyBase.isEmpty, key)
        }
    }

    /// btn.buy.rebate：按钮上的金额与同卡返利标签的金额是同一个格式化结果；加载 / 禁用态显示的动词也不带花括号。
    func testRebateKeyUsesSameAmountAsTag() throws {
        let data = ProductCardMapper.map(card(cta: "btn.buy.rebate"), texts: { DefaultTexts.text($0) ?? "" },
                                         nowMillis: Self.now, onCtaFallback: { _ in }).data
        let amount = try XCTUnwrap(data.rebate.singleAmount)
        XCTAssertEqual(amount, CouliFormat.money(fen: 269))
        XCTAssertEqual(data.buyBase, "购买预估返 " + amount)
        XCTAssertTrue(data.rebate.text.contains(amount), "返利标签同一金额")
    }

    /// btn.buy.rebate 的读屏：可见文字开头，不读出花括号，「预估返」只读一次（不重复读金额）。
    func testRebateKeySpokenLabelReadsAmountOnce() {
        let data = ProductCardMapper.map(card(cta: "btn.buy.rebate"), texts: { DefaultTexts.text($0) ?? "" },
                                         nowMillis: Self.now, onCtaFallback: { _ in }).data
        for context in BuyButtonContext.allCases {
            let spoken = BuyButtonModel.accessibilityLabel(
                base: data.buyBase, rebate: data.rebate, amountHidden: data.amountHidden, context: context.rawValue
            )
            XCTAssertTrue(spoken.hasPrefix("购买"), "\(context)：\(spoken)")
            XCTAssertFalse(spoken.contains("{"), "\(context)：\(spoken)")
            XCTAssertEqual(spoken.components(separatedBy: "预估返").count - 1, 1, "\(context)：\(spoken)")
        }
    }

    /// 平台状态（maintenance / not_launched）照旧压过兜底：按钮置灰显示平台文案。
    func testPurchaseStatusStillWinsOverFallback() {
        let texts: (String) -> String = { key in
            switch key {
            case "platform.taobao": "淘宝"
            case ProductCardKeys.retryLater: "稍后再试"
            default: DefaultTexts.text(key) ?? ""
            }
        }
        let data = ProductCardMapper.map(card(cta: "btn.buy.future_x"), texts: texts, nowMillis: Self.now,
                                         onCtaFallback: { _ in }).data
        XCTAssertEqual(
            ProductCardMapper.applyPurchaseStatus(data, statusRaw: "maintenance", texts: texts).buyState,
            .retryLater("稍后再试")
        )
        XCTAssertEqual(
            ProductCardMapper.applyPurchaseStatus(data, statusRaw: "not_launched", texts: texts).buyState,
            .retryLater("淘宝返利即将开放")
        )
        XCTAssertEqual(ProductCardMapper.applyPurchaseStatus(data, statusRaw: "on", texts: texts).buyState, .normal)
    }

    /// 升锁后包内契约字典（a89c1ec3a）里购买按钮的几条原文。
    func testLockedDictionaryHasBuyKeys() {
        XCTAssertEqual(DefaultTexts.text("btn.buy"), "购买")
        XCTAssertEqual(DefaultTexts.text("btn.buy.rebate"), "购买预估返 {amount}")
        XCTAssertEqual(DefaultTexts.text("btn.buy.rebate_unknown"), "购买可返利")
        XCTAssertEqual(DefaultTexts.text("rebate_login_to_view"), "登录查看返利")
    }

    // MARK: - 辅助

    private func card(cta key: String) -> [String: Any] {
        [
            "platform": "taobao", "product_key": "tb:cta", "item_ref": "ref-cta",
            "link_id": "0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5c01", "title": "洗衣液 3kg", "price_fen": 3990,
            "coupon_fen": 1000, "final_price_fen": 2990, "est_net_price_fen": 2721, "rebate_min_fen": 269,
            "rebate_max_fen": 269, "rebate_basis": "normal", "benefit_tags": [String](), "is_presale": false,
            "cta": ["text_key": key], "quoted_at": "2026-11-07T09:30:00+08:00", "stale": false, "age_sec": 12,
            "disclaimer_keys": ["price_basis"], "availability": "ok",
        ]
    }

    private func stateRaw(_ state: BuyButtonState) -> String {
        switch state {
        case .normal: "normal"
        case .loading: "loading"
        case .disabled: "disabled"
        case .retryLater: "retry_later"
        }
    }

    private func textsFunction(_ mode: String, _ label: String) throws -> (String) -> String {
        switch mode {
        case "contract": return { DefaultTexts.text($0) ?? "" }
        case "echo": return { DefaultTexts.text($0) ?? $0 }
        case "none": return { _ in "" }
        default:
            XCTFail("\(label)：未知 texts 模式 \(mode)")
            throw CocoaError(.featureUnsupported)
        }
    }

    private func loadVectors() throws -> [String: Any] {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().standardizedFileURL
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "contract.lock（从 \(#filePath) 向上）"])
            }
            directory = parent
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("specs/cta-key-vectors.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
