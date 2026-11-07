import CouliNetwork
import DesignSystem
import Foundation
import Generated
import ProductSearch
@testable import Search
import XCTest

/// FU-X-CTA-KEY-DRIFT（D10-856）详情底栏：锁内没有的 cta 键，详情模型照常可买、点击照常发出购买意图（走 open / 登录），
/// 底栏按钮有字。现状：ProductDetailState 只判「键非空」，可买判定已符合（加守卫）；按钮动词由 ProductCardMapper 兜底（先红）。
@MainActor
final class CtaKeyDetailTests: XCTestCase {
    private func controller(context: [String: Any]) -> ProductDetailController {
        ProductDetailController(
            api: makeSearchClient(), platform: "taobao", productKey: "tb:milk", itemRef: "ref 1", context: { context }
        )
    }

    private func card(_ key: String) -> String {
        SearchFixtures.card("tb:milk").replacingOccurrences(of: "\"btn.buy.coupon\"", with: "\"\(key)\"")
    }

    /// 已登录与游客各一次：未知键详情照常可买，buyIntent 放行（游客的 401 → 登录由购买执行器处理，与键无关）。
    func testUnknownKeyDetailStillBuys() async {
        for context: [String: Any] in [["loggedIn": true, "privacy": "consented"],
                                       ["loggedIn": false, "privacy": "consented"]] {
            SearchStubProtocol.install { _ in SearchFixtures.ok(self.card("btn.buy.future_x")) }
            let detail = controller(context: context)
            detail.start()
            await eventually { detail.snapshot.phase == .content }
            XCTAssertEqual(detail.snapshot.view?.buttonKeyRaw, "btn.buy.future_x", "原样保留键")
            XCTAssertEqual(detail.snapshot.view?.buyEnabled, true, "\(context)")
            XCTAssertTrue(detail.canBuy, "\(context)")
            XCTAssertTrue(detail.buyIntent(), "\(context)：点了照常发出购买意图")
        }
    }

    /// 详情大卡与底栏用同一映射：未知键时底栏按钮显示「购买」、normal；texts 回键名（`{ $0 }`）也不把键名画到按钮上。
    func testUnknownKeyDetailBarHasBuyText() async throws {
        SearchStubProtocol.install { _ in SearchFixtures.ok(self.card("btn.buy.future_x")) }
        let detail = controller(context: ["loggedIn": true, "privacy": "consented"])
        detail.start()
        await eventually { detail.snapshot.phase == .content }
        let product = try XCTUnwrap(detail.snapshot.product)
        let view = try XCTUnwrap(detail.snapshot.view)
        for texts: (String) -> String in [{ $0 }, { _ in "" }] {
            var logged: [String] = []
            let mapping = ProductCardMapper.map(product, texts: texts, buyEnabled: view.buyEnabled,
                                                onCtaFallback: { logged.append($0) })
            XCTAssertEqual(mapping.data.buyBase, "购买")
            XCTAssertEqual(mapping.data.buyState, .normal)
            XCTAssertEqual(logged, ["btn.buy.future_x"])
        }
    }

    /// 服务端 btn.buy.rebate（staging 现状）：详情可买，底栏一行「购买预估返 ¥2.69」。
    func testRebateKeyDetailBar() async throws {
        SearchStubProtocol.install { _ in SearchFixtures.ok(self.card("btn.buy.rebate")) }
        let detail = controller(context: ["loggedIn": true, "privacy": "consented"])
        detail.start()
        await eventually { detail.snapshot.phase == .content }
        XCTAssertTrue(detail.buyIntent())
        let product = try XCTUnwrap(detail.snapshot.product)
        let mapping = ProductCardMapper.map(
            product, texts: { DefaultTexts.text($0) ?? "" }, buyEnabled: detail.snapshot.view?.buyEnabled ?? false,
            onCtaFallback: { XCTFail("已知键不记诊断：\($0)") }
        )
        let data = mapping.data
        XCTAssertEqual(
            BuyButtonModel.text(base: data.buyBase, rebate: data.rebate, amountHidden: data.amountHidden,
                                context: BuyButtonContext.detail.rawValue),
            "购买预估返 ¥2.69"
        )
    }

    /// 没有 cta / 空键：照旧不可买（R4，服务端违约）。
    func testMissingKeyStillNotBuyable() {
        var product: [String: Any] = ["availability": "ok", "price_fen": 3990, "coupon_fen": 0, "final_price_fen": 3990]
        XCTAssertFalse(ProductDetailState.map(product, context: [:]).buyEnabled)
        product["cta"] = ["text_key": ""]
        XCTAssertFalse(ProductDetailState.map(product, context: [:]).buyEnabled)
        product["cta"] = ["text_key": "btn.buy.future_x"]
        XCTAssertTrue(ProductDetailState.map(product, context: [:]).buyEnabled)
    }
}
