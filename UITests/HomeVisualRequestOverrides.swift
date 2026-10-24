import Foundation
import XCTest

/// 仅派生本次测试的服务端响应；默认不改数据，不影响既有截图或共用 golden 文件。
struct HomeVisualRequestOverrides {
    var adLabel: String?
    var rotatingNotice = false
    /// 测试 v5（r2 S1-A）：信息流换成这么多件各不相同的商品（一页给完，next_cursor 为空），标题追加「第 N 件」。
    var longFeed: Int?

    static let sectionAdLabel = "区块推广占位"
    static let notices = ["测试公告甲：返利按月结算", "测试公告乙：订单状态可查询", "测试公告丙：优惠以下单页为准"]

    func page(_ original: [String: Any]) throws -> [String: Any] {
        let page = try feed(original)
        guard let adLabel else { return page }
        return try labeled(page, adLabel: adLabel)
    }

    private func feed(_ original: [String: Any]) throws -> [String: Any] {
        guard let longFeed else { return original }
        var page = original
        var responses = try XCTUnwrap(page["sectionItems"] as? [String: Any])
        let sources = try XCTUnwrap((responses["feed"] as? [String: Any])?["items"] as? [[String: Any]])
        let items: [[String: Any]] = (0..<longFeed).map { index in
            var item = sources[index % sources.count]
            item["title"] = (item["title"] as? String ?? "") + " " + Self.longFeedTitle(index)
            item["product_key"] = "taobao:window-\(index)"
            item["item_ref"] = "v1.window-\(index).sig"
            item["link_id"] = "window-\(index)"
            return item
        }
        responses["feed"] = ["items": items, "next_cursor": NSNull()]
        page["sectionItems"] = responses
        return page
    }

    static func longFeedTitle(_ index: Int) -> String {
        "第\(index)件"
    }

    private func labeled(_ original: [String: Any], adLabel: String) throws -> [String: Any] {
        var page = original
        var sections = try XCTUnwrap(page["sections"] as? [[String: Any]])
        var responses = try XCTUnwrap(page["sectionItems"] as? [String: Any])
        for kind in ["scroll", "grid", "feed"] {
            let index = try XCTUnwrap(sections.firstIndex { $0["id"] as? String == kind })
            sections[index]["ad_label"] = Self.sectionAdLabel
            var response = try XCTUnwrap(responses[kind] as? [String: Any])
            var items = try XCTUnwrap(response["items"] as? [[String: Any]])
            XCTAssertFalse(items.isEmpty)
            items[0]["ad_label"] = adLabel
            response["items"] = items
            responses[kind] = response
        }
        page["sections"] = sections
        page["sectionItems"] = responses
        return page
    }

    func notice(_ original: Any?) throws -> Any {
        guard rotatingNotice else { return original ?? [:] }
        var page = try XCTUnwrap(original as? [String: Any])
        var sections = try XCTUnwrap(page["sections"] as? [[String: Any]])
        var props = try XCTUnwrap(sections[0]["props"] as? [String: Any])
        let first = try XCTUnwrap((props["items"] as? [[String: Any]])?.first)
        props["mode"] = "scroll"
        props["items"] = Self.notices.enumerated().map { index, text in
            var item = first
            item["item_id"] = "visual-rotating-\(index)"
            item["text"] = text
            item["target"] = NSNull()
            return item
        }
        sections[0]["props"] = props
        page["sections"] = sections
        return page
    }
}
