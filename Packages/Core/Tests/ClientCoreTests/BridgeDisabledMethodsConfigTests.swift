import ClientCore
import Foundation
import XCTest

/// F-X-24 / vectors.md A1–A11。通过真正的 ConfigStore 接收配置，再读生效集合；测试不实现解析规则。
final class BridgeDisabledMethodsConfigTests: XCTestCase {
    func testA1MissingDefaultsWithoutWarning() {
        check(nil, expected: [], warns: false)
    }

    func testA2EmptyArrayDefaultsWithoutWarning() {
        check("[]", expected: [], warns: false)
    }

    func testA3OneMethod() {
        check(#"["clipboard.read"]"#, expected: ["clipboard.read"], warns: false)
    }

    func testA4TwoMethods() {
        check(#"["clipboard.read","net.signedRequest"]"#,
              expected: ["clipboard.read", "net.signedRequest"], warns: false)
    }

    func testA5UnknownWellFormedMethodIsKept() {
        check(#"["unknown.method"]"#, expected: ["unknown.method"], warns: false)
    }

    func testA6NonArrayRejectsWholeKey() {
        check(#""clipboard.read""#, expected: [], warns: true)
    }

    func testA7NonStringItemRejectsWholeKey() {
        check(#"["clipboard.read",1]"#, expected: [], warns: true)
    }

    func testA8BadPatternRejectsWholeKey() {
        check(#"["clipboard.read","Bad.Name"]"#, expected: [], warns: true)
    }

    func testA9DuplicateRejectsWholeKey() {
        check(#"["clipboard.read","clipboard.read"]"#, expected: [], warns: true)
    }

    func testA10NullIsInvalidNotMissing() {
        check("null", expected: [], warns: true)
    }

    func testA11MissingDotRejectsWholeKey() {
        check(#"["clipboardread"]"#, expected: [], warns: true)
    }

    /// 与其他桥配置相同：snapshotJson 选当前文档 → 冷启动 LKG → 包内；失败和 304 不改变生效文档。
    func testEffectiveDocumentFollowsColdStartLKGFailure304AndRefresh() throws {
        let fixture = Fixture(bundled: #"{"bridge_disabled_methods":["app.getEnv"]}"#)
        XCTAssertEqual(fixture.store.bridgeDisabledMethods(), ["app.getEnv"])
        fixture.file.value = #"{"v":1,"etag":"e1","data":{"bridge_disabled_methods":["clipboard.read"]}}"#
        fixture.store.onColdStart()
        XCTAssertEqual(fixture.store.sourceRaw, ConfigStore.sourceLKG)
        XCTAssertEqual(fixture.store.bridgeDisabledMethods(), ["clipboard.read"])
        fixture.reply(.init(kindRaw: ConfigReply.failure, bodyJson: nil, etag: nil))
        XCTAssertEqual(fixture.store.bridgeDisabledMethods(), ["clipboard.read"])
        fixture.store.onForeground()
        fixture.reply(.init(kindRaw: ConfigReply.notModified, bodyJson: nil, etag: "e1"))
        XCTAssertEqual(fixture.store.bridgeDisabledMethods(), ["clipboard.read"])
        fixture.store.onForeground()
        fixture.reply(.init(kindRaw: ConfigReply.ok, bodyJson: #"{"bridge_disabled_methods":[]}"#, etag: "e2"))
        XCTAssertEqual(fixture.store.sourceRaw, ConfigStore.sourceCurrent)
        XCTAssertEqual(fixture.store.bridgeDisabledMethods(), [])
        XCTAssertNotNil(fixture.file.value)
        try fixture.store.clearForEnvironmentSwitch()
        XCTAssertEqual(fixture.store.bridgeDisabledMethods(), ["app.getEnv"])
        XCTAssertNil(fixture.file.value)
    }

    /// A1/A6–A11 的缺省不能被旧文档的禁用名单覆盖；其他桥键同样从当前 snapshotJson 读取。
    func testMissingOrInvalidCurrentKeyDoesNotResurrectOldDisabledList() {
        for raw in [nil, "null", #"["clipboard.read",1]"#, #"["clipboard.read","Bad.Name"]"#] as [String?] {
            let fixture = Fixture(bundled: #"{"bridge_disabled_methods":["app.getEnv"]}"#)
            fixture.store.onColdStart()
            fixture.reply(.init(kindRaw: ConfigReply.ok,
                                bodyJson: #"{"bridge_disabled_methods":["clipboard.read"]}"#, etag: "e1"))
            fixture.store.onForeground()
            fixture.reply(.init(kindRaw: ConfigReply.ok, bodyJson: document(raw), etag: "e2"))
            var warnings: [String] = []
            XCTAssertEqual(fixture.store.bridgeDisabledMethods(warn: { warnings.append($0) }), [])
            XCTAssertEqual(warnings, raw == nil ? [] : ["bridge_disabled_methods"])
        }
    }

    private func check(
        _ raw: String?, expected: Set<String>, warns: Bool, file: StaticString = #filePath, line: UInt = #line
    ) {
        let fixture = Fixture()
        fixture.store.onColdStart()
        fixture.reply(.init(kindRaw: ConfigReply.ok, bodyJson: document(raw), etag: "vector"))
        XCTAssertEqual(fixture.store.sourceRaw, ConfigStore.sourceCurrent, file: file, line: line)
        var warnings: [String] = []
        let actual = fixture.store.bridgeDisabledMethods(warn: { warnings.append($0) })
        XCTAssertEqual(actual, expected, file: file, line: line)
        // 严格比较整条记录：恰一条、只含键名，不泄漏原值或逐项警告。
        XCTAssertEqual(warnings, warns ? ["bridge_disabled_methods"] : [], file: file, line: line)
        XCTAssertEqual(fixture.store.value(key: "dict_version"), #""fx24""#, file: file, line: line)
    }

    private func document(_ raw: String?) -> String {
        let field = raw.map { #", "bridge_disabled_methods":\#($0)"# } ?? ""
        return #"{"dict_version":"fx24"\#(field)}"#
    }

    private final class Fixture {
        let file = MemoryFile()
        var replies: [(ConfigReply) -> Void] = []
        let bundled: String
        lazy var store = ConfigStore(
            readFile: file.read, writeFile: file.write,
            fetcher: { [unowned self] _, done in replies.append(done) }, clock: { 1 }, bundled: bundled
        )

        init(bundled: String = "{}") {
            self.bundled = bundled
        }

        func reply(_ value: ConfigReply) {
            XCTAssertEqual(replies.count, 1, "前提：只有一次配置拉取在途")
            guard !replies.isEmpty else { return }
            replies.removeFirst()(value)
        }
    }
}
