import CouliNetwork
import DesignSystem
import Foundation
import Home
import HomeCore
import SwiftUI
import UIKit
import XCTest

/// 每个后续游标独立挂起，记录真实端口调用；测试只放应答，不主动调用 loadMore。
final class HomeVisualPagingPort: HomeContractPort, @unchecked Sendable {
    private let page: Data
    private let responses: [String: Data]
    private let lock = NSLock()
    private var calls: [String] = []
    private var pages = 0
    private var released: Set<String> = []
    private var stopped = false
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    let initialCount: Int
    let afterSecondCount: Int
    let finalKeys: [String]

    @MainActor
    init(fillsPair: Bool) throws {
        let golden = try XCTUnwrap(try SnapshotKit.goldenPages()["main_v3"] as? [String: Any])
        let feed = try XCTUnwrap((golden["sections"] as? [[String: Any]])?.first { $0["id"] as? String == "feed" })
        page = try JSONSerialization.data(withJSONObject: ["page_key": "home", "version": 31, "sections": [feed]])
        let sections = try XCTUnwrap(golden["sectionItems"] as? [String: Any])
        let response = try XCTUnwrap(sections["feed"] as? [String: Any])
        let source = try XCTUnwrap((response["items"] as? [[String: Any]])?.first)
        let products: [[String: Any]] = (0..<4).map { index in
            var item = source
            item["product_key"] = "taobao:paging-\(index)"
            item["item_ref"] = "v1.paging.\(index).sig"
            item["link_id"] = "paging-\(index)"
            // 文字、价格、图片相同，仅身份不同：补右列不能因内容不同改变整行高度。
            return item
        }
        initialCount = fillsPair ? 1 : 2
        afterSecondCount = 2
        finalKeys = products.compactMap { $0["product_key"] as? String }
        func data(_ items: [[String: Any]], next: String?) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["items": items, "next_cursor": next as Any? ?? NSNull()])
        }
        responses = try [
            "feed|": data(Array(products.prefix(initialCount)), next: "p2"),
            "feed|p2": data(fillsPair ? [products[1]] : [], next: "p3"),
            "feed|p3": data(Array(products.suffix(2)), next: nil),
        ]
    }

    var itemCalls: [String] {
        lock.withLock { calls }
    }

    var pageCalls: Int {
        lock.withLock { pages }
    }

    func getPage(pageKey _: String, call: HomeCall) async -> ApiResult {
        lock.withLock { pages += 1 }
        guard call.sendAllowed() else { return Self.failure }
        return .success(data: page, traceId: nil, idempotencyKey: nil)
    }

    func listSectionItems(pageKey _: String, sectionId: String, cursor: String?, call: HomeCall) async -> ApiResult {
        let key = sectionId + "|" + (cursor ?? "")
        lock.withLock { calls.append(key) }
        guard call.sendAllowed(), let data = responses[key] else { return Self.failure }
        if cursor != nil {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock {
                    guard !stopped, !released.contains(key) else { return true }
                    waiting[key, default: []].append(continuation)
                    return false
                }
                if resume {
                    continuation.resume()
                }
            }
        }
        return .success(data: data, traceId: nil, idempotencyKey: nil)
    }

    func release(_ cursor: String) {
        let continuations = lock.withLock {
            let key = "feed|" + cursor
            released.insert(key)
            return waiting.removeValue(forKey: key) ?? []
        }
        continuations.forEach { $0.resume() }
    }

    func releaseAll() {
        let continuations = lock.withLock {
            stopped = true
            defer { waiting = [:] }
            return waiting.values.flatMap(\.self)
        }
        continuations.forEach { $0.resume() }
    }

    private static var failure: ApiResult {
        .transportFailure(
            kind: "unexpected-paging-call",
            httpStatus: nil,
            idempotencyKey: nil,
            pendingKeyUnknown: false
        )
    }
}

/// 真实 HomeSduiScreen + UIWindow。读取实际加载圈和 UIScrollView，不复刻加载行位置公式。
@MainActor
final class HomeVisualFeedHost {
    private final class Measurements {
        var cards: [String: CGRect] = [:]
    }

    struct Geometry: Equatable {
        let status: CGRect
        let viewport: CGRect
        let offset: CGPoint
        let cards: [CGRect]
    }

    private let measurements = Measurements()
    let window: UIWindow
    let host: UIHostingController<AnyView>

    init(controller: HomeController) {
        let measurements = measurements
        let probe = CouliLayoutProbe(report: { record in
            if record.role == "product-card" {
                measurements.cards[record.id] = record.rect
            }
        }, remove: { measurements.cards.removeValue(forKey: $0) })
        host = UIHostingController(rootView: AnyView(HomeSduiScreen(controller: controller)
                .environment(\.dynamicTypeSize, .large)
                .environment(\.couliLayoutProbe, probe)))
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }

    func geometry() -> Geometry? {
        host.view.layoutIfNeeded()
        let all = descendants(host.view)
        let scrolls = all.compactMap { $0 as? UIScrollView }
        guard scrolls.count == 1, let scroll = scrolls.first, !measurements.cards.isEmpty else { return nil }
        let viewport = scroll.convert(scroll.bounds, to: window)
        // 排除 refreshable 内部的离屏加载圈；只接受列表可视区里正在显示的唯一加载圈。
        let indicators = all.compactMap { $0 as? UIActivityIndicatorView }.filter { indicator in
            guard indicator.isAnimating, indicator.window != nil,
                  viewport.contains(indicator.convert(indicator.bounds, to: window)) else { return false }
            var ancestor: UIView? = indicator
            while let view = ancestor {
                if view.isHidden || view.alpha == 0 {
                    return false
                }
                ancestor = view.superview
            }
            return true
        }
        guard indicators.count == 1, let indicator = indicators.first else { return nil }
        return Geometry(status: indicator.convert(indicator.bounds, to: window),
                        viewport: viewport, offset: scroll.contentOffset,
                        cards: measurements.cards.sorted { $0.key < $1.key }.map(\.value))
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
