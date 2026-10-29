@testable import Couli
import Foundation
import SnapshotTesting
import SwiftUI
import UIKit
import XCTest

/// APP-08v-b 订单详情整页基准（brief §2.6 详情 14 态 + 原因稿 12 卡 + 适配；名字与 Android `order-detail-v/` 同名）。
/// 真实 App 组装、visualOrders 同一份数据、固定时钟、与画板同宽同高。默认只比对；`COULI_RECORD_SNAPSHOTS=1` 只录缺图。
/// 原因稿 ①–⑫ 只截状态卡（按 `orderDetail.statusCard` 测量裁出）。申诉结果三态不拍（G-O01）。
@MainActor
final class OrderDetailVisualSnapshotTests: OrderVisualTestCase {
    struct Shot {
        let name: String
        let detail: String
        var height: CGFloat = 844
        var dark = false
        var width: CGFloat = 390
        var size: DynamicTypeSize = .large
        var hidden = false
        var cardOnly = false
    }

    struct Board {
        let name: String
        let detail: String
        let height: CGFloat

        init(_ name: String, _ detail: String, _ height: CGFloat) {
            self.name = name
            self.detail = detail
            self.height = height
        }
    }

    private let artboards: [Board] = [
        Board("OrderDetailEstimated-v2", "detail_estimated", 844),
        Board("OrderDetailSettled-v2", "detail_settled", 900),
        Board("OrderDetailPartClawed-v2", "detail_part_clawed", 920),
        Board("OrderDetailNoRebate-v2", "detail_no_rebate", 880),
        Board("OrderDetailBlacklist-v2", "detail_blacklist", 930),
        Board("OrderDetailAppealPending-v2", "detail_appeal_pending", 930),
        Board("OrderDetailPresale-v2", "detail_presale", 844),
        Board("OrderDetailRightsPending-v2", "detail_rights_pending", 844),
        Board("OrderDetailReviewing-v2", "detail_reviewing", 1109),
        Board("OrderDetailClawedBack-v2", "detail_clawed_back", 912),
        Board("OrderDetailShare-v2", "detail_share", 844),
        Board("OrderDetailPriceCompareNoRebate-v2", "detail_price_compare_no_rebate", 844),
        Board("OrderDetailPriceCompareRisk-v2", "detail_price_compare_risk", 844),
        Board("OrderDetailUnknown", "detail_unknown", 1135),
    ]

    func testArtboardsLight() async throws {
        try await run(artboards.map { Shot(name: "\($0.name)-light", detail: $0.detail, height: $0.height) }
            + [Shot(name: "state-detail-crediting-light", detail: "detail_crediting")])
    }

    func testArtboardsDark() async throws {
        try await run(artboards.map { Shot(name: "\($0.name)-dark", detail: $0.detail, height: $0.height, dark: true) }
            + [Shot(name: "OrderDetailDark-dark", detail: "detail_estimated", height: 1119, dark: true)])
    }

    /// 原因稿 ①–⑫：只截状态卡。
    func testReasonStateCards() async throws {
        try await run((1...12).map {
            Shot(name: String(format: "OrderDetailReasonStates-%02d-light", $0),
                 detail: String(format: "detail_reason_%02d", $0), height: 1000, cardOnly: true)
        })
    }

    /// 适配：200% × 390 / 320（WAITING、压力值、两按钮），深色 200% 一张，840 底栏铺满，金额隐藏。
    func testAdaptation() async throws {
        let ax = DynamicTypeSize.accessibility3
        try await run([
            Shot(
                name: "OrderDetailEstimated-v2-font200-w390-light",
                detail: "detail_estimated",
                height: 1400,
                size: ax
            ),
            Shot(name: "OrderDetailEstimated-v2-font200-w320-light", detail: "detail_estimated", height: 1600,
                 width: 320, size: ax),
            Shot(name: "OrderDetailEstimated-v2-font200-w390-dark", detail: "detail_estimated", height: 1400,
                 dark: true, size: ax),
            Shot(name: "OrderDetailPriceCompareRisk-v2-font200-w390-light", detail: "detail_stress", height: 1400,
                 size: ax),
            Shot(name: "OrderDetailPriceCompareRisk-v2-font200-w320-light", detail: "detail_stress", height: 1600,
                 width: 320, size: ax),
            Shot(name: "OrderDetailClawedBack-v2-font200-w390-light", detail: "detail_clawed_two", height: 1600,
                 size: ax),
            Shot(name: "OrderDetailClawedBack-v2-font200-w320-light", detail: "detail_clawed_two", height: 1800,
                 width: 320, size: ax),
            Shot(name: "OrderDetailSettled-v2-w840-light", detail: "detail_settled", height: 900, width: 840),
            Shot(name: "OrderDetailPartClawed-hidden-light", detail: "detail_part_clawed", height: 920, hidden: true),
        ])
    }

    /// 无稿页面状态：加载骨架（三块）、通用错误、30701、断网缓存。
    func testPageStates() async throws {
        for (name, reply, dark) in [
            ("state-detail-loading-light", OrderVisualStub.Reply.hold, false),
            ("state-detail-loading-dark", .hold, true),
            ("state-detail-error-light", .error(50001), false),
            ("state-detail-error-dark", .error(50001), true),
            ("state-detail-not-found-light", .error(30701), false),
        ] {
            let page = try fresh(OrderVisualStub.Script(details: ["C": reply]))
            try await page.showDetail("C", .init(dark: dark))
            let image = await page.stable { host, _ in
                switch reply {
                case .hold: host.probes["orderDetail.skeleton.status"] != nil
                default: OrderVisualStub.orderRequests.count == 1
                }
            }
            try assertShot(image, name: name, size: CGSize(width: 390, height: 844))
        }
        let detail = try OrderVisualData.detail("detail_estimated")
        let page = try fresh(OrderVisualStub.Script(details: ["C": .data(detail)]))
        try await page.showDetail("C")
        try await page.prepareStale()
        let image = await page.stable { host, image in
            host.probes["orderDetail.stale"] != nil && host.thumbnailDrawn(image, id: "C")
        }
        try assertShot(image, name: "state-detail-stale-light", size: CGSize(width: 390, height: 844))
    }

    // MARK: - 执行

    private func run(_ shots: [Shot], file: StaticString = #filePath, testName: String = #function,
                     line: UInt = #line) async throws {
        for shot in shots {
            let canvas = OrderVisualHost.Canvas(width: shot.width, height: shot.height, dark: shot.dark,
                                                size: shot.size)
            let (page, image) = try await openDetail(shot.detail, canvas: canvas, hidden: shot.hidden, file: file,
                                                     line: line)
            var output = image
            if shot.cardOnly {
                let card = try XCTUnwrap(page.probes["orderDetail.statusCard"]?.rect, "缺测量 orderDetail.statusCard")
                output = crop(image, to: card.insetBy(dx: -16, dy: -16))
            }
            try assertShot(output, name: shot.name,
                           size: shot.cardOnly ? nil : CGSize(width: shot.width, height: shot.height),
                           file: file, testName: testName, line: line)
        }
    }

    private func crop(_ image: UIImage, to rect: CGRect) -> UIImage {
        let scale = image.scale
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale,
                            height: rect.height * scale).integral
        guard let cg = image.cgImage?.cropping(to: pixels) else { return image }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    private func assertShot(_ image: UIImage?, name: String, size: CGSize?, file: StaticString = #filePath,
                            testName: String = #function, line: UInt = #line) throws {
        let image = try XCTUnwrap(image, "\(name)：没有稳定画面", file: file, line: line)
        if let size {
            XCTAssertEqual(image.size, size, "\(name)：画布尺寸", file: file, line: line)
        }
        withSnapshotTesting(record: ProcessInfo.processInfo
            .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: name,
                               file: file, testName: testName, line: line)
            }
    }
}
