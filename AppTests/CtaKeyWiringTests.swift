@testable import Couli
import DesignSystem
import Foundation
import Generated
import XCTest

/// FU-X-CTA-KEY-DRIFT（D10-856 / D10-857）App 接线：每处画购买按钮的地方用的真实文案函数，遇到锁内没有的 cta 键都显示「购买」、可点；
/// btn.buy.rebate 显示契约原文并填上金额。
/// - 搜索结果卡（SearchView+Results）与详情大卡 / 底栏（ProductDetailScreen）：`AppSearchTexts`（AppSearch.texts / AppTrade.texts）。
/// - 剪贴板多卡弹层（ClipboardCardList）：`AppClipboard.cardMapping`。
/// - 首页商品卡（HomeSectionView）：`HomeDraftTexts`（缺键回键名；首页卡不画购买按钮，buyEnabled: false，只钉不漏键名）。
final class CtaKeyWiringTests: XCTestCase {
    static func card(_ key: String) -> [String: Any] {
        [
            "platform": "taobao", "product_key": "tb:cta", "item_ref": "ref-cta",
            "link_id": "0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5c01", "title": "洗衣液 3kg", "price_fen": 3990,
            "coupon_fen": 1000, "final_price_fen": 2990, "est_net_price_fen": 2721, "rebate_min_fen": 269,
            "rebate_max_fen": 269, "rebate_basis": "normal", "benefit_tags": [String](), "is_presale": false,
            "cta": ["text_key": key], "quoted_at": "2026-11-07T09:30:00+08:00", "stale": false, "age_sec": 12,
            "disclaimer_keys": ["price_basis"], "availability": "ok",
        ]
    }

    private static let now: Int64 = 1_794_022_200_000

    /// 契约锁升到 a89c1ec3a（D10-857 三端统一）。
    func testLockIsCt26t() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return XCTFail("找不到 contract.lock") }
            directory = parent
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("contract.lock"))
        let lock = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let platform = try XCTUnwrap(lock["rebate_platform"] as? [String: Any])
        XCTAssertEqual(platform["commit"] as? String, "a89c1ec3a7f4de0b069742af909eba6545358ea3")
    }

    /// 搜索 / 详情的文案函数：契约字典优先，升锁后 btn.buy 取契约新值「购买」（草稿「去购买」被覆盖）。
    func testSearchTextsDictionaryWins() {
        let texts = AppSearchTexts()
        XCTAssertEqual(texts.text("btn.buy"), "购买")
        XCTAssertEqual(texts.text("btn.buy.rebate"), "购买预估返 {amount}")
        XCTAssertEqual(texts.text("btn.buy.rebate_unknown"), "购买可返利")
        XCTAssertEqual(texts.text("btn.buy.future_x"), "", "缺键空串（兜底在映射里做）")
    }

    /// 搜索结果卡 / 详情：未知键 → 「购买」、normal、记一条诊断；btn.buy.rebate → 「购买预估返 ¥2.69」（列表与详情同一句）。
    func testSearchAndDetailMapping() {
        let texts = AppSearchTexts().text
        var logged: [String] = []
        let unknown = ProductCardMapper.map(Self.card("btn.buy.future_x"), texts: texts, nowMillis: Self.now,
                                            onCtaFallback: { logged.append($0) }).data
        XCTAssertEqual(unknown.buyBase, "购买")
        XCTAssertEqual(unknown.buyState, .normal)
        XCTAssertEqual(logged, ["btn.buy.future_x"])

        let rebate = ProductCardMapper.map(Self.card("btn.buy.rebate"), texts: texts, nowMillis: Self.now,
                                           onCtaFallback: { XCTFail("已知键不记诊断：\($0)") }).data
        XCTAssertEqual(rebate.buyState, .normal)
        for context in [BuyButtonContext.list, .detail] {
            XCTAssertEqual(
                BuyButtonModel.text(base: rebate.buyBase, rebate: rebate.rebate, amountHidden: rebate.amountHidden,
                                    context: context.rawValue),
                "购买预估返 ¥2.69", "\(context)"
            )
        }
    }

    /// 首页文案函数缺键回键名：映射不把键名当按钮文字。
    func testHomeTextsEchoDoesNotLeakKey() {
        let data = ProductCardMapper.map(Self.card("btn.buy.future_x"), texts: { HomeDraftTexts.text($0, [:]) },
                                         buyEnabled: false, nowMillis: Self.now, onCtaFallback: { _ in }).data
        XCTAssertEqual(data.buyBase, "购买")
        XCTAssertEqual(data.buyState, .disabled, "首页卡本来就不可买（buyEnabled: false），不因兜底改变")
    }
}

/// 剪贴板多卡弹层（ClipboardCardList → AppClipboard.cardMapping，缺省文案函数 AppSearchTexts）。
extension ClipboardWiringTests {
    @MainActor
    func testCtaKey_CardListUnknownKeyIsTappable() {
        let fixture = make()
        let unknown = fixture.clipboard.cardMapping(CtaKeyWiringTests.card("btn.buy.future_x")).data
        XCTAssertEqual(unknown.buyBase, "购买")
        XCTAssertEqual(unknown.buyState, .normal)
        let rebate = fixture.clipboard.cardMapping(CtaKeyWiringTests.card("btn.buy.rebate")).data
        XCTAssertEqual(rebate.buyBase, "购买预估返 ¥2.69")
        XCTAssertEqual(rebate.buyState, .normal)
    }
}
