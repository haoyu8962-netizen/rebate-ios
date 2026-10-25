@testable import Couli
import Foundation
import SnapshotTesting
import SwiftUI
import UIKit
import XCTest

/// APP-06v-a 详情页主体的整页基准（brief §2.9、§5）：真实 App 组装、visualCards 同一份数据、与画板同宽同高（390 × 956；下架 844）。
/// 名字与 Android `app/src/test/snapshots/product-v/` 同名，便于三端对照。默认只比对（缺图失败）；`TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1`
/// 只录缺图（`.missing`），不覆盖已有基准。
@MainActor
final class ProductVisualSnapshotTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var host: ProductVisualHost?

    struct Shot {
        let name: String
        var card: String?
        var reply: ProductVisualHost.Reply?
        var statuses: [String: String] = [:]
        var canvas = ProductVisualHost.Canvas()
        var expectImage = true
    }

    override func setUpWithError() throws {
        AppStubProtocol.reset()
        ProductVisualImages.install()
    }

    override func tearDown() async throws {
        host?.close()
        host = nil
        cleanDefaults()
        ProductVisualImages.uninstall()
        AppStubProtocol.reset()
    }

    private func cleanDefaults() {
        // 没建过套件时 suiteName 为空：拼出来的就是整个临时目录，删掉会让 URLSession / AsyncImage 之后再也拿不到图。
        guard !suiteName.isEmpty else { return }
        defaults?.removePersistentDomain(forName: suiteName)
        try? FileManager.default
            .removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName))
    }

    /// 有稿浅色：正常、京东、比价取消后、三张取消后卡面、下架；pdd / 预售无稿。
    func testArtboardStatesLight() async throws {
        try await run([
            Shot(name: "Product-v2-light", card: "tb_coupon_range"),
            Shot(name: "ProductJd-light", card: "jd_no_coupon_single"),
            Shot(name: "state-pdd-light", card: "pdd_coupon", statuses: ["pdd": "on"]),
            Shot(name: "state-presale-light", card: "presale"),
            Shot(name: "ProductPriceCompareCancelled-v2-light", card: "pdd_price_compare", statuses: ["pdd": "on"]),
            Shot(name: "ProductRebateGoneCancelled-v2-light", card: "tb_rebate_gone"),
            Shot(name: "ProductPriceChangedCancelled-v2-light", card: "tb_price_changed"),
            Shot(name: "ProductPriceChangedRebateGoneCancelled-v2-light", card: "tb_price_changed_rebate_gone"),
            Shot(name: "ProductOffShelf-v3-light", card: "tb_off_shelf", canvas: .init(height: 844)),
        ])
    }

    /// 深色定稿（ProductDark 只对上部 956；下架深色 844）与页面级状态深色抽样。
    func testDarkArtboards() async throws {
        try await run([
            Shot(name: "ProductDark-dark", card: "tb_coupon_range", canvas: .init(dark: true)),
            Shot(name: "ProductOffShelfDark-dark", card: "tb_off_shelf", canvas: .init(height: 844, dark: true)),
            Shot(name: "state-loading-dark", reply: .hold, canvas: .init(dark: true), expectImage: false),
            Shot(name: "state-error-dark", reply: .error(50001), canvas: .init(dark: true), expectImage: false),
        ])
    }

    /// 无稿状态（按 ProductCardDegrade-v2 文案与配色推导，compare 写「无稿，按令牌推导」）。
    func testDerivedStates() async throws {
        try await run([
            Shot(name: "state-amount-unknown-light", card: "amount_unknown", statuses: ["pdd": "on"]),
            // v2（评审 r1 S2-4-5）：有价格 + 金额未知（specs/product-visual-extra-cards.json）
            Shot(name: "state-amount-unknown-priced-light", card: "pdd_amount_unknown_priced", statuses: ["pdd": "on"]),
            Shot(name: "state-price-unavailable-light", card: "price_unavailable"),
            Shot(name: "state-stale-light", card: "stale"),
            Shot(name: "state-ad-label-light", card: "ad_label"),
            Shot(name: "state-guest-light", card: "login_required"),
            Shot(name: "state-maintenance-light", card: "tb_coupon_range", statuses: ["taobao": "maintenance"]),
            Shot(name: "state-not-launched-light", card: "tb_coupon_range", statuses: ["taobao": "not_launched"]),
        ])
    }

    /// 页面级状态（§2.7）：加载骨架、通用错误（trace6）、30143、进页即下架（G-D05）。
    func testPageStatesLight() async throws {
        try await run([
            Shot(name: "state-loading-light", reply: .hold, expectImage: false),
            Shot(name: "state-error-light", reply: .error(50001), expectImage: false),
            Shot(name: "state-ref-expired-light", reply: .error(30143), expectImage: false),
            Shot(name: "state-off-shelf-entry-light", reply: .error(30141), expectImage: false),
        ])
    }

    /// 适配（§4.4、§4.5）：≥200% × 390 / 320（AX3）、840 大屏。
    func testAdaptation() async throws {
        let ax = DynamicTypeSize.accessibility3
        try await run([
            Shot(name: "Product-v2-font200-w390-light", card: "tb_coupon_range", canvas: .init(size: ax)),
            Shot(name: "ProductDark-font200-w390-dark", card: "tb_coupon_range", canvas: .init(dark: true, size: ax)),
            Shot(name: "Product-v2-font200-w320-light", card: "tb_coupon_range", canvas: .init(width: 320, size: ax)),
            Shot(
                name: "ProductJd-font200-w320-light",
                card: "jd_no_coupon_single",
                canvas: .init(width: 320, size: ax)
            ),
            Shot(name: "Product-v2-w840-light", card: "tb_coupon_range", canvas: .init(width: 840)),
        ])
    }

    // MARK: - 执行

    private func run(_ shots: [Shot], file: StaticString = #filePath, testName: String = #function,
                     line: UInt = #line) async throws {
        for shot in shots {
            try await take(shot, file: file, testName: testName, line: line)
        }
    }

    private func take(_ shot: Shot, file: StaticString, testName: String, line: UInt) async throws {
        host?.close()
        host = nil
        AppStubProtocol.reset()
        cleanDefaults()
        suiteName = "product-visual-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let page: ProductVisualHost = if let id = shot.card {
            try ProductVisualHost(suiteName: suiteName, defaults: defaults,
                                  card: ProductVisualCards.screenshotCard(id), statuses: shot.statuses)
        } else {
            try ProductVisualHost(suiteName: suiteName, defaults: defaults, platform: "taobao",
                                  productKey: "tb:visual-milk", reply: shot.reply ?? .hold)
        }
        host = page
        await page.show(shot.canvas)
        guard let image = await page.stableImage(expectImage: shot.expectImage, file: file, line: line) else { return }
        XCTAssertEqual(image.size, CGSize(width: shot.canvas.width, height: shot.canvas.height),
                       "\(shot.name)：画布尺寸", file: file, line: line)
        if shot.expectImage {
            XCTAssertTrue(ProductVisualImages.served.contains { $0.contains("/product-v/") },
                          "\(shot.name)：没有请求商品测试位图，不能录空白页", file: file, line: line)
        }
        withSnapshotTesting(record: ProcessInfo.processInfo
            .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: shot.name,
                               file: file, testName: testName, line: line)
            }
    }
}
