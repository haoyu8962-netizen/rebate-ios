#if DEBUG
@testable import Couli
import Foundation
import XCTest

/// specs/home-sdui-vectors.json 的 `preview` 组（G24）。HomePreviewPolicy 只在 App 的 Debug / Staging 源码里（类名含 debug_only 路由名，
/// 不能进包），所以执行器放在这里；写法照 Codex 原稿：Router 丢弃多余参数，只把 page_key / token 交给策略，返回 screenRaw / pageKey / token
/// 与五个副作用布尔值，逐项比较。
final class HomePreviewVectorTests: XCTestCase {
    func testPreviewVectors() throws {
        let root = try HomeAppSamples.vectors()
        let rows = try XCTUnwrap(root["preview"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 4)
        for row in rows {
            let name = try XCTUnwrap(row["name"] as? String)
            let raw = try XCTUnwrap(row["routeParams"] as? [String: Any])
            let pageKey = try XCTUnwrap(raw["page_key"] as? String)
            let token = try XCTUnwrap(raw["token"] as? String)
            let actual = HomePreviewPolicy.of(
                routeParams: ["page_key": pageKey, "token": token],
                result: try XCTUnwrap(row["result"] as? [String: Any])
            )
            var expected = try XCTUnwrap(row["expect"] as? [String: Any])
            expected["pageKey"] = pageKey
            expected["token"] = token
            for (key, value) in expected {
                let got = try XCTUnwrap(actual[key], "\(name).\(key) 缺字段")
                XCTAssertEqual(
                    try JSONSerialization.data(withJSONObject: [got], options: [.sortedKeys]),
                    try JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]),
                    "\(name).\(key)"
                )
            }
        }
    }
}
#endif
