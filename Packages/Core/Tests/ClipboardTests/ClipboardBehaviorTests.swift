@testable import Clipboard
import CouliNetwork
import Foundation
import XCTest

/// 剪贴板纯逻辑的执行层行为（向量之外）：记录的落盘与清理、24 小时去重不被容量淘汰、写入口、一次前台一次判定、parse 请求体与结果映射、
/// 手动粘贴与自动识别同一套过滤。
final class ClipboardBehaviorTests: XCTestCase {
    func testLedgerReportsUnpersistedWritesAndClearThrows() {
        let store = MemoryClipboardHashStore()
        let ledger = ClipboardWriteLedger(store: store)
        XCTAssertTrue(ledger.record("a"))
        store.failWrites = true
        XCTAssertFalse(ledger.record("b"), "没落盘返回 false（共性第 23、25 条）")
        XCTAssertFalse(ledger.contains("b"))
        XCTAssertThrowsError(try ledger.clear(), "撤回清理删除失败要抛错（共性第 14 条）")
        store.failWrites = false
        XCTAssertNoThrow(try ledger.clear())
        XCTAssertFalse(ledger.contains("a"))
    }

    func testLedgerStoresOnlyHashesAndChangeCounts() {
        let store = MemoryClipboardHashStore()
        let ledger = ClipboardWriteLedger(store: store)
        ledger.record("秘密原文 https://e.tb.cn/x")
        ledger.recordChangeCount(42)
        XCTAssertTrue(ledger.containsChangeCount(42))
        XCTAssertFalse(ledger.containsChangeCount(43))
        for key in [ClipboardWriteLedger.hashKey, ClipboardWriteLedger.changeKey] {
            XCTAssertFalse(store.read(key)?.contains("秘密") ?? false, "本机只存 hash")
            XCTAssertFalse(store.read(key)?.contains("e.tb.cn") ?? false)
        }
        XCTAssertEqual(store.read(ClipboardWriteLedger.hashKey), ClipboardText.sha256("秘密原文 https://e.tb.cn/x"))
    }

    func testPromptHistoryKeepsAllWithin24HoursAndExpires() {
        var now: Int64 = 1_000_000
        let history = PromptHistory(clock: { now })
        for index in 0..<120 {
            history.record("h\(index)")
        }
        XCTAssertEqual(history.stamps().count, 120, "24 小时内的记录不按容量淘汰（共性第 7 条）")
        now += ClipboardClassifier.promptWindowMs
        history.record("new")
        XCTAssertEqual(history.stamps().map(\.hash), ["new"], "满 24 小时的记录到期清理")
    }

    @MainActor
    func testWriterRecordsBeforeWritingAndRefusesOnFailure() {
        let store = MemoryClipboardHashStore()
        let system = CountingClipboard()
        let writer = ClipboardWriter(system: system, ledger: ClipboardWriteLedger(store: store))
        XCTAssertTrue(writer.write("tpwd"))
        XCTAssertEqual(system.writes, 1)
        XCTAssertTrue(ClipboardWriteLedger(store: store).containsChangeCount(system.changeCount))
        store.failWrites = true
        XCTAssertFalse(writer.write("other"))
        XCTAssertEqual(system.writes, 1, "hash 没记上不写系统剪贴板")
    }

    @MainActor
    func testWatcherOncePerForeground() {
        var events: [String] = []
        let watcher = ClipboardWatcher { event, round in
            events.append(event)
            _ = round
        }
        watcher.onActive()
        watcher.consume(watcher.round)
        watcher.onActive()
        watcher.onActive()
        XCTAssertEqual(events, [ClipboardReadPolicy.eventColdStart], "没经过后台的重新激活不算回前台")
        XCTAssertTrue(watcher.readThisForeground)
        watcher.onBackground()
        XCTAssertFalse(watcher.inForeground)
        watcher.onActive()
        XCTAssertEqual(events, [ClipboardReadPolicy.eventColdStart, ClipboardReadPolicy.eventForeground])
        XCTAssertFalse(watcher.readThisForeground, "新的一次前台重新判定")
        let stale = watcher.round - 1
        watcher.consume(stale)
        XCTAssertFalse(watcher.readThisForeground, "旧轮次的消费不作数")
    }

    func testParseBodyOnlyCarriesUploadAndScene() throws {
        let body = ParseInputService.body("https://e.tb.cn/a\n降噪蓝牙耳机")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
        XCTAssertEqual(object, ["text": "https://e.tb.cn/a\n降噪蓝牙耳机", "scene": "clipboard"])
        let envelope = #"{"scene":"clipboard","text":""}"#
        XCTAssertEqual(ParseInputService.body(String(repeating: "a", count: 5000)).count, 4000 + envelope.count)
    }

    /// R1-03：整体 30132 用请求绑定的本地标题预填，不读 data.raw；R1-02：整体 10405 只在网络层判定确需强更时交执行层进强更。
    func testWholeFailureUsesBoundTitleAndDefersForceUpdate() {
        let raw = Data(#"{"raw":"服务端回显的原文"}"#.utf8)
        let unrecognized = ParseInputService.outcome(.failure(
            code: 30132, msg: "", data: raw, traceId: "t", effect: ErrorEffect(code: 30132, kind: .toast),
            idempotencyKey: nil
        ), title: "降噪蓝牙耳机")
        XCTAssertEqual(unrecognized.action?.prefill, "降噪蓝牙耳机")
        let untitled = ParseInputService.outcome(.failure(
            code: 30132, msg: "", data: raw, traceId: "t", effect: ErrorEffect(code: 30132, kind: .toast),
            idempotencyKey: nil
        ))
        XCTAssertNil(untitled.action?.prefill, "没有标题留空，不拿 data.raw")
        let forced = ParseInputService.outcome(.failure(
            code: 10405, msg: "", data: Data(#"{"min_supported_version":"9.9.0"}"#.utf8), traceId: "t",
            effect: ErrorEffect(code: 10405, kind: .forceUpdate), idempotencyKey: nil
        ))
        XCTAssertEqual(forced.action?.networkForced, true)
        XCTAssertEqual(forced.action?.minSupportedVersion, "9.9.0")
        let refreshOnly = ParseInputService.outcome(.failure(
            code: 10405, msg: "", data: nil, traceId: "t", effect: ErrorEffect(code: 10405, kind: .toast),
            idempotencyKey: nil
        ))
        XCTAssertEqual(refreshOnly.action?.networkForced, false, "网络层没判定强更的 10405 不进强更")
    }

    func testOutcomeMapping() {
        var effect = ErrorEffect(code: 42901, kind: .disableButton)
        effect.disableMillis = 0
        let limited = ParseInputService.outcome(.failure(
            code: 42901, msg: "", data: nil, traceId: "t", effect: effect, idempotencyKey: nil
        ))
        XCTAssertEqual(limited.action?.disableMs, 5000, "Retry-After 为 0 也按 5 秒（A11）")
        let dropped = ParseInputService.outcome(.localReject(reason: LocalRejectReason.callCancelled))
        XCTAssertTrue(dropped.dropped, "归属失效：只丢弃")
        let transport = ParseInputService.outcome(.transportFailure(
            kind: "timeout", httpStatus: nil, idempotencyKey: nil, pendingKeyUnknown: false
        ))
        XCTAssertEqual(transport.action?.textKey, "error.50001")
        let inline = ParseResultAction.map(
            response: ["code": 0, "data": ["results": [["hit": ["raw": "x"], "error_code": 10405]]]],
            errorCode: nil, retryAfter: nil, traceId: nil
        )
        XCTAssertEqual(inline.actionRaw, ParseResultAction.forceUpdate)
        XCTAssertTrue(inline.inline, "行内 10405 由执行层进强更")
        let overall = ParseResultAction.map(response: nil, errorCode: 10405, retryAfter: nil, traceId: nil)
        XCTAssertFalse(overall.inline, "整体 10405 由网络层处理")
        let unknown = ParseResultAction.map(response: nil, errorCode: 59999, retryAfter: nil, traceId: "abc123456")
        XCTAssertEqual(unknown.textKey, "error.59999")
        XCTAssertEqual(unknown.showTrace6, true)
    }

    func testManualPasteUsesSameFiltersAsAutoDetect() {
        let rules = ClipboardRules.defaults
        let domains = ["share.example.test"]
        let long = "https://e.tb.cn/" + String(repeating: "a", count: 600)
        XCTAssertEqual(
            ManualPasteAction.decide(entry: "home", text: long, rules: rules).actionRaw,
            ManualPasteAction.searchPrefill, "过长不上传（共性第 22 条）"
        )
        XCTAssertEqual(
            ManualPasteAction.decide(entry: "home", text: "http://x", rules: rules).actionRaw,
            ManualPasteAction.searchPrefill, "过短不上传"
        )
        let landing = ManualPasteAction.decide(
            entry: "home", text: "https://share.example.test/i/K7M2QX", rules: rules, shareDomains: domains
        )
        XCTAssertEqual(landing.actionRaw, ManualPasteAction.invite, "邀请落地页只本地抽码（共性第 13 条）")
        XCTAssertEqual(landing.code, "K7M2QX")
        let mixed = ManualPasteAction.decide(
            entry: "search_typing", text: "https://e.tb.cn/h.A1 https://share.example.test/i/K7M2QX 邀请码 K7M2QX",
            rules: rules, shareDomains: domains
        )
        XCTAssertEqual(mixed.uploadText, "https://e.tb.cn/h.A1", "商品与邀请混合时只上传商品片段")
        XCTAssertEqual(
            ManualPasteAction.decide(entry: "home", text: "邀请码 K7M2QX", rules: rules, selfWritten: true).actionRaw,
            ManualPasteAction.none, "App 自写的纯邀请内容静默"
        )
        XCTAssertEqual(
            ManualPasteAction.decide(entry: "home", text: "https://e.tb.cn/h.A1x", rules: rules, selfWritten: true)
                .actionRaw,
            ManualPasteAction.searchPrefill, "App 自写的商品内容不上传（共性第 17 条）"
        )
    }

    func testLandingLinkMatchingIsStrict() {
        let domains = ["share.example.test"]
        XCTAssertTrue(ClipboardClassifier.inviteLanding("https://SHARE.example.test/i/K7M2QX", shareDomains: domains))
        XCTAssertFalse(ClipboardClassifier.inviteLanding(
            "https://a.share.example.test/i/K7M2QX",
            shareDomains: domains
        ))
        XCTAssertFalse(ClipboardClassifier.inviteLanding(
            "https://share.example.test:8443/i/K7M2QX",
            shareDomains: domains
        ))
        XCTAssertFalse(ClipboardClassifier.inviteLanding("https://share.example.test/x/K7M2QX", shareDomains: domains))
    }
}

@MainActor
private final class CountingClipboard: SystemClipboard {
    var changeCount = 0
    var writes = 0

    func detectLink(_ completion: @escaping @MainActor (Bool) -> Void) {
        completion(false)
    }

    func write(_: String) {
        writes += 1
        changeCount += 1
    }
}
