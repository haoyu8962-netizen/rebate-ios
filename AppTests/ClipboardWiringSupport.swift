import ClientCore
import Clipboard
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Router
import XCTest

/// APP-07 接线测试（续）：行内 10405、多卡、旧回调、撤回清理。
extension ClipboardWiringTests {
    // MARK: - 行内 10405、多卡

    func testInline10405EntersServerForcedUpdate() async {
        let fixture = make()
        fixture.clipboard.sceneActive()
        fixture.api.reply = .inline(code: 10405)
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await settle()
        XCTAssertEqual(fixture.state.forced, 1, "行内 10405 主动进强更（共性第 20 条）")
    }

    func testMultipleResultsListAndInlineRateLimit() async throws {
        let fixture = make()
        fixture.clipboard.sceneActive()
        fixture.api.reply = .multi(errorCode: 42901)
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await settle()
        guard case let .cardList(rows, _) = try XCTUnwrap(fixture.clipboard.result).kind else {
            return XCTFail("多卡弹层")
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(fixture.clipboard.blocked, "行内 42901 启动共享禁用期")
    }

    func testStaleResultCallbackDoesNotActOnNewResult() throws {
        let fixture = make()
        fixture.clipboard.sceneActive()
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: "邀请码 K7M2QX")
        let old = try XCTUnwrap(fixture.clipboard.result)
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: "普通文字，没有链接")
        let current = try XCTUnwrap(fixture.clipboard.result)
        fixture.clipboard.confirmInvite(old.id)
        fixture.clipboard.dismissResult(old.id)
        XCTAssertEqual(fixture.clipboard.result?.id, current.id, "旧回调不执行、不清新结果（共性第 18、26 条）")
        XCTAssertTrue(fixture.routing.router.path.isEmpty)
    }

    // MARK: - 撤回同意清记录

    func testWithdrawalCleanerDeletesRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        let store = ClipboardFileStore(file: ClientFile(name: "records.json", baseDirectory: directory))
        let ledger = ClipboardWriteLedger(store: store)
        XCTAssertTrue(ledger.record("written"))
        XCTAssertTrue(ledger.contains("written"))
        let cleaner = ClipboardRecordsCleaner(store: store)
        try cleaner.cleanForEnvironmentSwitch()
        XCTAssertFalse(ledger.contains("written"), "撤回后 hash 记录清空")
        let registry = EnvironmentSwitchCleanerRegistry(cleaners: [])
        ClipboardRecordsCleaner.register(cleaner, withdrawal: registry)
        ClipboardRecordsCleaner.register(cleaner, withdrawal: registry)
        XCTAssertEqual(registry.registeredNames, [ClipboardRecordsCleaner.name])
        let file = directory.appendingPathComponent("com.couli.app/records.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "记录文件已删除（只存 hash，从不存原文）")
    }
}

/// 假系统剪贴板：changeCount、detectPatterns 命中与否、读写计数（不读正文）。
@MainActor
final class FakeSystemClipboard: SystemClipboard {
    var changeCount = 0
    var detectHit = false
    private(set) var detectCalls = 0
    private(set) var writes = 0

    func detectLink(_ completion: @escaping @MainActor (Bool) -> Void) {
        detectCalls += 1
        completion(detectHit)
    }

    func write(_: String) {
        writes += 1
        changeCount += 1
    }
}

/// 假 parse 服务：记录请求体，可挂起再放行；回答由 `reply` 决定。
final class FakeParseApi: ParseApi, @unchecked Sendable {
    enum Reply {
        case success(card: Bool)
        case multi(errorCode: Int)
        case inline(code: Int)
        case failure(code: Int)
        case rateLimited(millis: Int64)
    }

    private let lock = NSLock()
    private var recorded: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var hold = false
    var reply: Reply = .success(card: true)

    var bodies: [String] {
        lock.withLock { recorded }
    }

    func release() {
        let pending = lock.withLock {
            hold = false
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    func send(_ call: ApiCall, isValid: @escaping @Sendable () -> Bool) async -> ApiResult {
        let held = lock.withLock {
            recorded.append(call.body ?? "")
            return hold
        }
        if held {
            await withCheckedContinuation { continuation in
                lock.withLock { waiters.append(continuation) }
            }
        }
        guard isValid() else { return .localReject(reason: LocalRejectReason.callCancelled) }
        return result()
    }

    private func result() -> ApiResult {
        let trace = "trace-00001a2b3c"
        let card = #"{"product_key":"tb:milk","platform":"taobao","item_ref":"ref-1","#
            + #""link_id":"link-parse-1","title":"t"}"#
        let hit = #"{"platform":"taobao","kind":"url","raw":"https://e.tb.cn/h.Demo01"}"#
        switch reply {
        case .success:
            return .success(data: Data(#"{"results":[{"hit":\#(hit),"card":\#(card)}]}"#.utf8), traceId: trace,
                            idempotencyKey: nil)
        case let .multi(code):
            let rows = #"[{"hit":\#(hit),"card":\#(card)},{"hit":\#(hit),"error_code":\#(code)}]"#
            return .success(data: Data(#"{"results":\#(rows)}"#.utf8), traceId: trace, idempotencyKey: nil)
        case let .inline(code):
            return .success(data: Data(#"{"results":[{"hit":\#(hit),"error_code":\#(code)}]}"#.utf8), traceId: trace,
                            idempotencyKey: nil)
        case let .failure(code):
            return .failure(code: code, msg: "", data: nil, traceId: trace,
                            effect: ErrorEffect(code: code, kind: .toast), idempotencyKey: nil)
        case let .rateLimited(millis):
            var effect = ErrorEffect(code: 42901, kind: .disableButton)
            effect.disableMillis = millis
            return .failure(code: 42901, msg: "", data: nil, traceId: trace, effect: effect, idempotencyKey: nil)
        }
    }
}
