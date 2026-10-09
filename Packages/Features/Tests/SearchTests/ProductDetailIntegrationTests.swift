import CouliNetwork
import DesignSystem
import Foundation
import ProductSearch
@testable import Search
import XCTest

@MainActor
final class ProductDetailIntegrationTests: XCTestCase {
    private let consented: [String: Any] = ["loggedIn": true, "privacy": "consented"]

    private func controller(_ api: SearchApi, context: [String: Any]? = nil) -> ProductDetailController {
        let value = context ?? consented
        return ProductDetailController(
            api: api, platform: "taobao", productKey: "tb:milk", itemRef: "ref 1", context: { value }
        )
    }

    func testDetailRequestCarriesPathAndItemRef() async {
        SearchStubProtocol.install { _ in SearchFixtures.ok(SearchFixtures.card("tb:milk")) }
        let detail = controller(makeSearchClient())
        detail.start()
        await eventually { detail.snapshot.phase == .content }
        XCTAssertEqual(SearchStubProtocol.requests.first?.path, "/v1/products/tb:milk")
        XCTAssertEqual(SearchStubProtocol.requests.first?.query["item_ref"], "ref 1")
        XCTAssertEqual(detail.snapshot.view?.buttonKeyRaw, "btn.buy.coupon")
        XCTAssertTrue(detail.buyIntent())
    }

    func testBasicModeIsPublicAndAnonymousRequestAllowed() async {
        SearchStubProtocol.install { _ in SearchFixtures.ok(SearchFixtures.card("tb:milk")) }
        let detail = controller(makeSearchClient(privacy: PrivacyRaw.basic), context: ["loggedIn": false,
                                                                                       "privacy": "basic"])
        detail.start()
        await eventually { detail.snapshot.phase == .content }
        XCTAssertEqual(detail.snapshot.view?.publicMode, true)
    }

    func testOffShelfAndExpiredAreErrorsWithoutBuy() async {
        for code in [30141, 30143] {
            SearchStubProtocol.install { _ in SearchFixtures.fail(code) }
            let detail = controller(makeSearchClient())
            detail.start()
            await eventually { detail.snapshot.phase == .error }
            XCTAssertEqual(detail.snapshot.error?.code, code)
            XCTAssertEqual(detail.snapshot.error?.textKey, "error.\(code)")
            XCTAssertFalse(detail.buyIntent())
        }
    }

    func testPriceUnavailableKeepsUnknownAndDisablesBuy() async {
        let card = SearchFixtures.card("tb:milk", price: "null", availability: "price_unavailable")
        SearchStubProtocol.install { _ in SearchFixtures.ok(card) }
        let detail = controller(makeSearchClient())
        detail.start()
        await eventually { detail.snapshot.phase == .content }
        XCTAssertEqual(detail.snapshot.view?.priceUnavailable, true)
        XCTAssertEqual(detail.snapshot.view?.buyEnabled, false)
        let product = detail.snapshot.product ?? [:]
        let mapping = ProductCardMapper.map(product, texts: { $0 })
        XCTAssertEqual(mapping.data.priceUnavailableText, ProductCardKeys.priceUnavailable)
        XCTAssertEqual(mapping.data.price.mainAmount, "", "价格缺失不补 0")
        XCTAssertNil(mapping.data.estNet)
        XCTAssertNil(mapping.quotedAt)
        XCTAssertEqual(mapping.data.buyState, .retryLater(ProductCardKeys.retryLater))
    }

    func testNullPriceWithoutAvailabilityIsStillUnavailable() {
        let product: [String: Any] = [
            "platform": "taobao", "price_fen": NSNull(), "coupon_fen": 0, "final_price_fen": NSNull(),
            "rebate_basis": "normal", "availability": "ok",
        ]
        XCTAssertTrue(ProductCardMapper.priceUnavailable(product))
        XCTAssertTrue(ProductDetailState.priceUnavailable(product))
        let unknown: [String: Any] = ["platform": "pdd", "price_fen": NSNull(), "rebate_basis": "amount_unknown"]
        XCTAssertFalse(ProductCardMapper.priceUnavailable(unknown), "金额未知卡本来就不显示价格")
    }

    func testStaleDetailFlag() {
        let stale: [String: Any] = ["stale": false, "age_sec": 301]
        XCTAssertTrue(ProductDetailState.stale(stale))
        XCTAssertFalse(ProductDetailState.stale(["stale": false, "age_sec": 300]))
    }

    func testLeaveDiscardsLateDetailResponse() async {
        let api = ManualSearchApi()
        let detail = controller(api)
        detail.start()
        await eventually { api.count == 1 }
        detail.leave()
        XCTAssertFalse(api.isValid(0))
        api.respond(0, SearchFixtures.envelope(0, data: SearchFixtures.card("tb:milk")))
        await settle()
        XCTAssertEqual(detail.snapshot.phase, .loading)
        XCTAssertNil(detail.snapshot.product)
    }

    func testRateLimitedRetryBlocked() async {
        let api = ManualSearchApi()
        let detail = controller(api)
        detail.start()
        await eventually { api.count == 1 }
        api.respond(0, SearchFixtures.envelope(42901, data: "{}"))
        await eventually { detail.snapshot.phase == .error }
        XCTAssertTrue(detail.snapshot.retryBlocked)
        XCTAssertFalse(detail.retry())
    }
}
