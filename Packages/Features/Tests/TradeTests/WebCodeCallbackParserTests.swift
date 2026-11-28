import Foundation
@testable import Trade
import XCTest

/// FU-IOS-TB-WEBCODE-A：淘宝 web_code 回跳解析（D10-2717 定值：只认 `couli://auth/taobao`，error 只有 `error=1`）。
/// 向量是本仓自拟（CT-17l 合并后再对齐契约向量）。规则见 WebCodeCallback.swift 的类型注释：
/// - 前缀逐字 `couli://auth/taobao?`（scheme / host / path 大小写敏感、不得有端口 / userinfo / 多余 path 段），不得有 `#`，整串 ≤ 8192；
/// - 按 `&` / `=` 切，任一键重复、百分号编码非法（截断、非十六进制、解出非 UTF-8）→ nil；`+` 不当空格；
/// - 只认 code / state / error，其他键忽略；认的键解码后须匹配 `[A-Za-z0-9_-]*`；state 1...128、code 1...4096；
/// - 有 error：`error=1` → `.incomplete(state:)`，其他取值 → nil，带 error 一律不出 `.code`。
/// 「state 与本机记录不符」「同一 state 第二次回跳」不归解析器判（见 WebCodeInboxTests 与 AppTests 的授权器用例）。
final class WebCodeCallbackParserTests: XCTestCase {
    private let prefix = "couli://auth/taobao?"

    private func parse(_ raw: String) -> WebCodeCallback? {
        WebCodeCallbackParser.parse(raw)
    }

    private func assertCode(
        _ raw: String, code: String, state: String, _ why: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            parse(raw), .code(code: code, state: state), "\(why)：应解析为 .code：\(raw.prefix(120))",
            file: file, line: line
        )
    }

    private func assertRejected(_ raw: String, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(parse(raw), "\(why)：应丢弃（nil）：\(raw.prefix(120))", file: file, line: line)
    }

    // MARK: - 常量（D10-2717 定值，底座已是真值）

    func testConstantsFollowTheRulingValues() {
        XCTAssertEqual(WebCodeCallbackParser.scheme, "couli")
        XCTAssertEqual(WebCodeCallbackParser.host, "auth")
        XCTAssertEqual(WebCodeCallbackParser.path, "/taobao")
        XCTAssertEqual(WebCodeCallbackParser.prefix, prefix)
        XCTAssertEqual(WebCodeCallbackParser.maxLength, 8192)
        XCTAssertEqual(WebCodeCallbackParser.stateMaxLength, 128)
        XCTAssertEqual(WebCodeCallbackParser.codeMaxLength, 4096)
    }

    // MARK: - 正向

    func testCodeAndStateParseToCode() {
        assertCode("couli://auth/taobao?code=TOP_a1B2-c3D4e5&state=st_9f8E7d6C5b4A3", code: "TOP_a1B2-c3D4e5",
                   state: "st_9f8E7d6C5b4A3", "中转页成功回跳")
        assertCode("couli://auth/taobao?state=S1&code=C1", code: "C1", state: "S1", "参数顺序无关")
    }

    func testStateAccessorReturnsTheAssociatedState() {
        XCTAssertEqual(WebCodeCallback.code(code: "C1", state: "S_code").state, "S_code")
        XCTAssertEqual(WebCodeCallback.incomplete(state: "S_inc").state, "S_inc")
    }

    func testErrorOneIsIncomplete() {
        XCTAssertEqual(parse("couli://auth/taobao?state=S1&error=1"), .incomplete(state: "S1"), "error=1 按未完成")
        XCTAssertEqual(parse("couli://auth/taobao?error=1&state=S1"), .incomplete(state: "S1"), "参数顺序无关")
        XCTAssertEqual(
            parse("couli://auth/taobao?code=C1&state=S1&error=1"), .incomplete(state: "S1"),
            "带 error=1 时即使有 code 也只是未完成，不出 .code"
        )
    }

    func testUnknownKeysAreIgnored() {
        assertCode("couli://auth/taobao?code=C1&state=S1&from=h5&v=2", code: "C1", state: "S1", "多余的键忽略")
        assertCode("couli://auth/taobao?from=h5&code=C1&state=S1", code: "C1", state: "S1", "多余的键在前面")
    }

    func testValidPercentEncodingIsDecodedBeforeTheCharsetCheck() {
        assertCode("couli://auth/taobao?code=C%31&state=S%5F1", code: "C1", state: "S_1", "合法百分号编码先解码")
        assertCode("couli://auth/taobao?code=C%2d1&state=S1", code: "C-1", state: "S1", "小写十六进制同样合法")
    }

    func testLengthBoundariesAreAccepted() {
        let state128 = String(repeating: "s", count: 128)
        assertCode("\(prefix)code=C1&state=\(state128)", code: "C1", state: state128, "state 恰 128 字符")
        let code4096 = String(repeating: "c", count: 4096)
        assertCode("\(prefix)code=\(code4096)&state=S1", code: code4096, state: "S1", "code 恰 4096 字符")
        let head = "\(prefix)code=C1&state=S1&pad="
        let exact = head + String(repeating: "p", count: 8192 - head.count)
        XCTAssertEqual(exact.count, 8192, "前提：整串恰 8192")
        assertCode(exact, code: "C1", state: "S1", "整串恰 8192 字符")
    }

    // MARK: - 反向（底座恒 nil，这些在底座上就绿）

    func testLengthLimitsAreEnforced() {
        assertRejected("\(prefix)code=C1&state=\(String(repeating: "s", count: 129))", "state 129 字符")
        assertRejected("\(prefix)code=\(String(repeating: "c", count: 4097))&state=S1", "code 4097 字符")
        let head = "\(prefix)code=C1&state=S1&pad="
        let over = head + String(repeating: "p", count: 8193 - head.count)
        XCTAssertEqual(over.count, 8193, "前提：整串 8193")
        assertRejected(over, "整串超过 8192")
    }

    func testMissingOrEmptyFieldsAreRejected() {
        assertRejected("couli://auth/taobao?code=C1", "缺 state")
        assertRejected("couli://auth/taobao?code=C1&state=", "state 为空")
        assertRejected("couli://auth/taobao?state=S1", "缺 code 又没有 error")
        assertRejected("couli://auth/taobao?code=&state=S1", "code 为空")
        assertRejected("couli://auth/taobao?error=1", "error=1 缺 state")
        assertRejected("couli://auth/taobao?state=&error=1", "error=1 且 state 为空")
        assertRejected("couli://auth/taobao?", "查询串为空")
        assertRejected("couli://auth/taobao", "没有查询串")
        assertRejected("", "空串")
    }

    func testErrorValuesOtherThanOneAreRejected() {
        for value in ["0", "2", "01", "true", "", "1 ", "%31%31", "-1"] {
            assertRejected("couli://auth/taobao?state=S1&error=\(value)", "error=\(value) 不是定值 1")
            assertRejected("couli://auth/taobao?code=C1&state=S1&error=\(value)", "带 error=\(value) 时不出 .code")
        }
    }

    func testPrefixMustMatchLiterally() {
        assertRejected("COULI://auth/taobao?code=C1&state=S1", "scheme 大写")
        assertRejected("Couli://auth/taobao?code=C1&state=S1", "scheme 首字母大写")
        assertRejected("couli://AUTH/taobao?code=C1&state=S1", "host 大写")
        assertRejected("couli://auth/Taobao?code=C1&state=S1", "path 大写")
        assertRejected("couli-debug://auth/taobao?code=C1&state=S1", "调试 scheme")
        assertRejected("couli-dev://auth/taobao?code=C1&state=S1", "scheme 前缀相同")
        assertRejected("https://auth/taobao?code=C1&state=S1", "https")
        assertRejected("couli:auth/taobao?code=C1&state=S1", "少了 //")
        assertRejected(" couli://auth/taobao?code=C1&state=S1", "前导空格")
        assertRejected("auth/taobao?code=C1&state=S1", "没有 scheme")
    }

    func testWrongHostOrPathIsRejected() {
        assertRejected("couli://oauth/taobao?code=C1&state=S1", "host 是 oauth（设计稿旧建议值）")
        assertRejected("couli://r/taobao?code=C1&state=S1", "host 是 r（路由深链）")
        assertRejected("couli:///taobao?code=C1&state=S1", "没有 host")
        assertRejected("couli://authx/taobao?code=C1&state=S1", "host 前缀相同")
        assertRejected("couli://auth/jd?code=C1&state=S1", "path 是 /jd")
        assertRejected("couli://auth/taobao/x?code=C1&state=S1", "path 多一段")
        assertRejected("couli://auth/taobao/?code=C1&state=S1", "path 带尾斜杠")
        assertRejected("couli://auth?code=C1&state=S1", "没有 path")
        assertRejected("couli://auth/taobaox?code=C1&state=S1", "path 前缀相同")
        assertRejected("couli://auth/%74aobao?code=C1&state=S1", "path 编码过")
    }

    func testFragmentPortAndUserinfoAreRejected() {
        assertRejected("couli://auth/taobao?code=C1&state=S1#x", "带 fragment")
        assertRejected("couli://auth/taobao?code=C1&state=S1#", "带空 fragment")
        assertRejected("couli://auth/taobao?code=C1#&state=S1", "fragment 在中间")
        assertRejected("couli://auth:80/taobao?code=C1&state=S1", "带端口")
        assertRejected("couli://u@auth/taobao?code=C1&state=S1", "带 userinfo")
        assertRejected("couli://u:p@auth/taobao?code=C1&state=S1", "带 userinfo 与口令")
    }

    func testDuplicateKeysVoidTheWholeCallback() {
        assertRejected("couli://auth/taobao?code=C1&code=C2&state=S1", "code 两次")
        assertRejected("couli://auth/taobao?code=C1&code=C1&state=S1", "code 两次（同值）")
        assertRejected("couli://auth/taobao?code=C1&state=S1&state=S2", "state 两次")
        assertRejected("couli://auth/taobao?state=S1&error=1&error=1", "error 两次")
        assertRejected("couli://auth/taobao?code=C1&state=S1&from=a&from=b", "不认的键重复也整串作废")
    }

    func testIllegalPercentEncodingIsRejected() {
        assertRejected("couli://auth/taobao?code=C%zz1&state=S1", "非十六进制 %zz")
        assertRejected("couli://auth/taobao?code=C1&state=S%", "截断的 %")
        assertRejected("couli://auth/taobao?code=C1&state=S%4", "截断的 %4")
        assertRejected("couli://auth/taobao?code=C%FF1&state=S1", "解出非 UTF-8")
        assertRejected("couli://auth/taobao?code=C%C31&state=S1", "残缺的 UTF-8 序列")
        assertRejected("couli://auth/taobao?code=C1&state=S1&from=%zz", "不认的键编码非法也整串作废")
    }

    func testCharactersOutsideTheAllowedSetAreRejected() {
        let cases: [(String, String)] = [
            ("code=C+1&state=S1", "+ 不当空格，也不在白名单"),
            ("code=C%2B1&state=S1", "编码的 +"),
            ("code=C%201&state=S1", "编码的空格"),
            ("code=C 1&state=S1", "原样空格"),
            ("code=C%001&state=S1", "NUL"),
            ("code=C1&state=S%0A1", "换行"),
            ("code=C1&state=S1\n", "末尾换行"),
            ("code=C%261&state=S1", "编码的 &"),
            ("code=C%3D1&state=S1", "编码的 ="),
            ("code=C1=2&state=S1", "值里带 ="),
            ("code=C.1&state=S1", "点"),
            ("code=C~1&state=S1", "波浪号"),
            ("code=C1&state=S%221", "引号"),
            ("code=%3Cscript%3E&state=S1", "尖括号"),
            ("code=%E4%B8%AD&state=S1", "非 ASCII（编码）"),
            ("code=中&state=S1", "非 ASCII（原样）"),
            ("code=C1&state=S%2F1", "斜杠"),
        ]
        for (query, why) in cases {
            assertRejected(prefix + query, why)
        }
    }
}
