import CouliNetwork
import DesignSystem
import Foundation
import Home
import HomeCore
import SwiftUI
import UIKit
import XCTest

/// 长信息流端口（r2 S1-A）：只有一个信息流区段，`pages` 页 × `perPage` 件，游标立即应答；翻页全由真实加载行触发。
/// 商品轮换 main_v3 信息流的 4 件样例（平台、标题长短、券、标签各不相同，行高不全一样），标题追加「第 N 件」作身份核对。
final class HomeVisualLongFeedPort: HomeContractPort, @unchecked Sendable {
    private let page: Data
    private let responses: [String: Data]
    private let lock = NSLock()
    private var calls: [String] = []

    @MainActor
    init(pages: Int, perPage: Int) throws {
        let golden = try XCTUnwrap(try SnapshotKit.goldenPages()["main_v3"] as? [String: Any])
        let feed = try XCTUnwrap((golden["sections"] as? [[String: Any]])?.first { $0["id"] as? String == "feed" })
        page = try JSONSerialization.data(withJSONObject: ["page_key": "home", "version": 41, "sections": [feed]])
        let sections = try XCTUnwrap(golden["sectionItems"] as? [String: Any])
        let response = try XCTUnwrap(sections["feed"] as? [String: Any])
        let sources = try XCTUnwrap(response["items"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(sources.count, 2)
        let products: [[String: Any]] = (0..<pages * perPage).map { index in
            var item = sources[index % sources.count]
            let title = (item["title"] as? String ?? "") + " 第\(index)件"
            item["title"] = title
            item["product_key"] = "taobao:window-\(index)"
            item["item_ref"] = "v1.window.\(index).sig"
            item["link_id"] = "window-\(index)"
            item["image"] = "https://img.example.test/window/\(index).png"
            return item
        }
        var replies: [String: Data] = [:]
        for number in 0..<pages {
            let key = "feed|" + (number == 0 ? "" : "w\(number)")
            let next: Any = number + 1 < pages ? "w\(number + 1)" : NSNull()
            let items = Array(products[number * perPage..<(number + 1) * perPage])
            replies[key] = try JSONSerialization.data(withJSONObject: ["items": items, "next_cursor": next])
        }
        responses = replies
    }

    var itemCalls: [String] {
        lock.withLock { calls }
    }

    func getPage(pageKey _: String, call: HomeCall) async -> ApiResult {
        guard call.sendAllowed() else { return Self.failure }
        return .success(data: page, traceId: nil, idempotencyKey: nil)
    }

    func listSectionItems(pageKey _: String, sectionId: String, cursor: String?, call: HomeCall) async -> ApiResult {
        let key = sectionId + "|" + (cursor ?? "")
        lock.withLock { calls.append(key) }
        guard call.sendAllowed(), let data = responses[key] else { return Self.failure }
        return .success(data: data, traceId: nil, idempotencyKey: nil)
    }

    private static var failure: ApiResult {
        .transportFailure(kind: "unexpected-window-call", httpStatus: nil, idempotencyKey: nil,
                          pendingKeyUnknown: false)
    }
}

/// 真实 HomeSduiScreen + UIWindow + 列表自己的 UIScrollView。测试只改 contentOffset（等同一次没有惯性的滚动），
/// 不调 loadMore、不碰窗口化的内部状态；同时实际布局的商品卡以 DesignSystem 商品卡自己上报的测量为准（出现即记、消失即删），
/// 每次上报都更新峰值，不靠轮询采样。
@MainActor
final class HomeVisualWindowHost {
    private final class Cards {
        var rects: [String: CGRect] = [:]
        var peak = 0
    }

    /// 某一刻的列表状态：内容坐标（相对滚动内容顶边）里每张已实际布局的商品卡的框。
    struct Frame {
        let offset: CGFloat
        let viewport: CGRect
        let contentHeight: CGFloat
        let cards: [String: CGRect]

        var maxOffset: CGFloat {
            max(0, contentHeight - viewport.height)
        }
    }

    private let cards = Cards()
    let window: UIWindow
    let host: UIHostingController<AnyView>

    init(controller: HomeController) {
        let cards = cards
        let probe = CouliLayoutProbe(report: { record in
            guard record.role == "product-card" else { return }
            cards.rects[record.id] = record.rect
            cards.peak = max(cards.peak, cards.rects.count)
        }, remove: { cards.rects.removeValue(forKey: $0) })
        host = UIHostingController(rootView: AnyView(HomeSduiScreen(controller: controller)
                .environment(\.dynamicTypeSize, .large)
                .environment(\.couliLayoutProbe, probe)))
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
    }

    /// 截至目前同时实际布局的商品卡最大数。
    var peak: Int {
        cards.peak
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }

    var scrollView: UIScrollView? {
        let scrolls = descendants(host.view).compactMap { $0 as? UIScrollView }
        return scrolls.count == 1 ? scrolls.first : nil
    }

    func frame() -> Frame? {
        host.view.layoutIfNeeded()
        guard let scroll = scrollView else { return nil }
        let viewport = scroll.convert(scroll.bounds, to: window)
        let offset = scroll.contentOffset.y
        let content = cards.rects.mapValues { rect in
            CGRect(x: rect.minX, y: rect.minY - viewport.minY + offset, width: rect.width, height: rect.height)
        }
        return Frame(offset: offset, viewport: viewport, contentHeight: scroll.contentSize.height, cards: content)
    }

    /// 无动画设偏移，然后等列表连续三次采样不变（卡片集合、框、内容高度、偏移）。
    func scroll(to target: CGFloat) async throws -> Frame {
        let scroll = try XCTUnwrap(scrollView)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
        return try await settled()
    }

    func settled() async throws -> Frame {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var previous: Frame?
        var stable = 0
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(40))
            guard let current = frame() else {
                stable = 0
                continue
            }
            if let previous, previous.same(as: current) {
                stable += 1
            } else {
                stable = 1
            }
            previous = current
            if stable >= 3 {
                return current
            }
        }
        XCTFail("列表 5 秒内没有稳定")
        return try XCTUnwrap(previous)
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

extension HomeVisualWindowHost.Frame {
    func same(as other: Self) -> Bool {
        guard abs(offset - other.offset) <= 0.01, abs(contentHeight - other.contentHeight) <= 0.01,
              Set(cards.keys) == Set(other.cards.keys) else { return false }
        return cards.allSatisfy { key, rect in
            guard let next = other.cards[key] else { return false }
            return abs(rect.minY - next.minY) <= 0.01 && abs(rect.height - next.height) <= 0.01
        }
    }

    /// 顶边落在视口里的卡（内容坐标）。
    func visible(_ tops: [String: CGFloat]) -> [String] {
        tops.filter { $0.value >= offset && $0.value < offset + viewport.height }.map(\.key)
    }
}
