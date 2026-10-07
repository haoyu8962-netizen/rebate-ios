@testable import ClientCore
import XCTest

/// APP-04 三端共性第 18 条：规则表要完整校验，含坏正则或坏条目就整表算坏表，回落到 LKG → 包内。
final class LinkPatternsValidationTests: XCTestCase {
    private func table(version: String, host: String, paths: String, category: String = "union_host") -> String {
        #"{"link_patterns":{"version":""# + version + #"","rules":[{"platform":"taobao","category":""# + category
            + #"","hosts":[""# + host + #""],"path_patterns":"# + paths + "}]}}"
    }

    func testBadRegexFallsBackToLastGoodLayer() throws {
        let current = table(version: "c", host: "taobao.example.test", paths: #"["(["]"#)
        let lkg = table(version: "l", host: "lkg.example.test", paths: "[]")
        let bundled = table(version: "b", host: "bundled.example.test", paths: "[]")
        let chosen = try XCTUnwrap(ConfigResolver.linkPatterns(current: current, lkg: lkg, bundled: bundled))
        XCTAssertTrue(chosen.contains("lkg.example.test"), chosen)
        let both = try XCTUnwrap(ConfigResolver.linkPatterns(current: current, lkg: current, bundled: bundled))
        XCTAssertTrue(both.contains("bundled.example.test"), both)
    }

    func testMalformedRuleMakesTheWholeTableBad() {
        for paths in [#"[1]"#, #""x""#] {
            let bad = table(version: "c", host: "taobao.example.test", paths: paths)
            XCTAssertNil(ConfigResolver.linkPatterns(current: bad, lkg: nil, bundled: nil), paths)
        }
        let emptyHost = table(version: "c", host: "", paths: "[]")
        XCTAssertNil(ConfigResolver.linkPatterns(current: emptyHost, lkg: nil, bundled: nil))
        let good = table(version: "c", host: "taobao.example.test", paths: #"["^/item$"]"#)
        XCTAssertNotNil(ConfigResolver.linkPatterns(current: good, lkg: nil, bundled: nil))
    }

    /// 第 2 轮评审 R2-01（三端共性第 40 条）：类别不在契约枚举里（拼错的 union_hots）→ 整表回落到 LKG。
    func testCategoryOutsideContractEnumFallsBack() throws {
        let lkg = table(version: "l", host: "lkg.example.test", paths: "[]")
        for category in ["union_hots", "UNION_HOST", "", "__unknown__"] {
            let current = table(version: "c", host: "taobao.example.test", paths: "[]", category: category)
            let chosen = try XCTUnwrap(ConfigResolver.linkPatterns(current: current, lkg: lkg, bundled: nil))
            XCTAssertTrue(chosen.contains("lkg.example.test"), category)
        }
        for category in ["union_host", "product", "promo"] {
            let current = table(version: "c", host: "taobao.example.test", paths: "[]", category: category)
            let chosen = try XCTUnwrap(ConfigResolver.linkPatterns(current: current, lkg: lkg, bundled: nil))
            XCTAssertTrue(chosen.contains("taobao.example.test"), category)
        }
    }

    /// 主机不是合法主机名（带协议、路径、端口、用户信息、空白、通配、末尾点）→ 整表回落到 LKG。
    func testHostWithSchemeOrPathFallsBack() throws {
        let lkg = table(version: "l", host: "lkg.example.test", paths: "[]")
        let bad = [
            "https://taobao.example.test", "taobao.example.test/item", "taobao.example.test:443",
            "user@taobao.example.test", " taobao.example.test", "*.taobao.example.test", "taobao.example.test.",
            "-taobao.example.test", "taobao..example.test",
        ]
        for host in bad {
            let current = table(version: "c", host: host, paths: "[]")
            let chosen = try XCTUnwrap(ConfigResolver.linkPatterns(current: current, lkg: lkg, bundled: nil))
            XCTAssertTrue(chosen.contains("lkg.example.test"), host)
        }
        for host in ["taobao.example.test", "M.TAOBAO.example.test", "xn--fiqs8s.example.test", "a-b.example.test"] {
            XCTAssertTrue(ConfigResolver.isHostName(host), host)
        }
    }
}
