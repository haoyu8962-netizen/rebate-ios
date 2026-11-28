import CryptoKit
import Foundation
@testable import Trade
import XCTest

/// 毫秒墙钟（测试手动拨）。
private final class InboxManualClock {
    var now: Int64 = 1_000_000
}

/// 一次 `claim` 的观察点：任务结束时记下结果。
@MainActor
private final class InboxClaimProbe {
    var result: WebCodeCallback?
    var done = false
    var task: Task<Void, Never>?
}

/// FU-IOS-TB-WEBCODE-A：回跳的一次性收件箱 `WebCodeInbox` 与 `webCodeStateSha256`（同安卓甲 i01–i10 语义）。
/// - 回跳先到 / 等待先到两种顺序都交付；只交给 sha256(state) 相同的等待；单槽，新回跳覆盖旧的，state 不符的等待不吞它；
/// - 交付后同一 state 在 10 分钟内再来就丢；槽位超过 10 分钟作废；等待所在任务被取消 → `claim` 返回 nil 并注销；
/// - `clear()` 清槽位与已交付记录。
/// 底座 `claim` 立即返回 nil，所以正向用例按断言红、不会挂住；「拿不到」类反向用例在底座上就绿。
@MainActor
final class WebCodeInboxTests: XCTestCase {
    private let clock = InboxManualClock()
    private lazy var inbox: WebCodeInbox = {
        let clock = clock
        return WebCodeInbox(clock: { clock.now })
    }()

    /// sha256（UTF-8 字节、小写十六进制）：测试自己算，不复用被测代码。
    private func referenceSha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 起一个等待并让它挂上。
    private func startClaim(_ state: String) async -> InboxClaimProbe {
        let probe = InboxClaimProbe()
        let inbox = inbox
        let hash = referenceSha256(state)
        probe.task = Task { @MainActor in
            probe.result = await inbox.claim(stateSha256: hash)
            probe.done = true
        }
        await settle()
        return probe
    }

    /// 等这个等待结束（最多约 2 秒）并取回结果；没结束就取消并返回 nil（随后的断言会红）。
    private func received(_ probe: InboxClaimProbe) async -> WebCodeCallback? {
        for _ in 0..<200 where !probe.done {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if !probe.done {
            probe.task?.cancel()
            await probe.task?.value
            return nil
        }
        return probe.result
    }

    /// 这个等待没拿到任何回跳：给它几轮调度，然后取消，取消后应以 nil 结束。
    private func assertNothingDelivered(
        _ probe: InboxClaimProbe, _ why: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        await settle()
        probe.task?.cancel()
        await probe.task?.value
        XCTAssertNil(probe.result, why, file: file, line: line)
    }

    // MARK: - 哈希

    func testStateHashIsLowercaseHexSha256OfUtf8Bytes() {
        XCTAssertEqual(
            webCodeStateSha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "已知向量 abc"
        )
        for state in ["st_01", "S1", "状态_非ASCII", String(repeating: "s", count: 128)] {
            let hash = webCodeStateSha256(state)
            XCTAssertEqual(hash, referenceSha256(state), "UTF-8 字节的 SHA-256：\(state.prefix(16))")
            XCTAssertNotNil(hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression), "64 位小写十六进制")
        }
        XCTAssertNotEqual(webCodeStateSha256("S1"), webCodeStateSha256("s1"), "区分大小写")
    }

    func testTtlIsTenMinutes() {
        XCTAssertEqual(WebCodeInbox.slotTtlMillis, 600_000)
    }

    // MARK: - 正向（底座按断言红）

    func testWaiterFirstThenCallbackIsDelivered() async {
        let probe = await startClaim("S1")
        XCTAssertFalse(probe.done, "回跳到之前一直等（底座：立即以 nil 结束）")
        inbox.deliver(.code(code: "C1", state: "S1"))
        let got = await received(probe)
        XCTAssertEqual(got, .code(code: "C1", state: "S1"), "等待先到、回跳后到：交付")
    }

    func testCallbackFirstThenWaiterIsDelivered() async {
        inbox.deliver(.code(code: "C1", state: "S1"))
        let got = await received(startClaim("S1"))
        XCTAssertEqual(got, .code(code: "C1", state: "S1"), "回跳先到、等待后到：交付")
    }

    func testIncompleteIsDeliveredToo() async {
        let probe = await startClaim("S1")
        inbox.deliver(.incomplete(state: "S1"))
        let got = await received(probe)
        XCTAssertEqual(got, .incomplete(state: "S1"), "error=1 的回跳也交给等待")
    }

    func testForgedCallbackDoesNotInterruptTheRealWaiter() async {
        let probe = await startClaim("S1")
        inbox.deliver(.code(code: "FORGED", state: "OTHER"))
        await settle()
        XCTAssertFalse(probe.done, "state 不符的回跳不交给这次等待（底座：立即以 nil 结束）")
        inbox.deliver(.code(code: "C1", state: "S1"))
        let got = await received(probe)
        XCTAssertEqual(got, .code(code: "C1", state: "S1"), "不符的回跳不打断等待，之后匹配的照常交付")
    }

    func testWaiterForAnotherStateDoesNotSwallowTheSlot() async {
        inbox.deliver(.code(code: "C1", state: "S1"))
        await assertNothingDelivered(startClaim("S2"), "别的 state 的等待拿不到")
        let got = await received(startClaim("S1"))
        XCTAssertEqual(got, .code(code: "C1", state: "S1"), "别的等待不吞掉这条回跳")
    }

    func testNewerCallbackReplacesTheSlot() async {
        inbox.deliver(.code(code: "C1", state: "S1"))
        inbox.deliver(.code(code: "C2", state: "S2"))
        await assertNothingDelivered(startClaim("S1"), "单槽：旧回跳被新的覆盖")
        let got = await received(startClaim("S2"))
        XCTAssertEqual(got, .code(code: "C2", state: "S2"), "槽里是新的那条")
    }

    func testSlotWithinTtlIsStillDelivered() async {
        inbox.deliver(.code(code: "C1", state: "S1"))
        clock.now += WebCodeInbox.slotTtlMillis - 1
        let got = await received(startClaim("S1"))
        XCTAssertEqual(got, .code(code: "C1", state: "S1"), "10 分钟内仍可认领")
    }

    func testCancelledWaiterReturnsNilAndUnregisters() async {
        let probe = await startClaim("S1")
        probe.task?.cancel()
        await probe.task?.value
        XCTAssertTrue(probe.done)
        XCTAssertNil(probe.result, "等待所在任务被取消：claim 返回 nil")
        inbox.deliver(.code(code: "C1", state: "S1"))
        let got = await received(startClaim("S1"))
        XCTAssertEqual(got, .code(code: "C1", state: "S1"), "取消的等待已注销，不吞掉后来的回跳；回跳进槽位给下一个等待")
    }

    func testDeliveredOnlyOnce() async {
        inbox.deliver(.code(code: "C1", state: "S1"))
        let first = await received(startClaim("S1"))
        XCTAssertEqual(first, .code(code: "C1", state: "S1"), "前提：第一次认领拿到")
        await assertNothingDelivered(startClaim("S1"), "交付一次后槽位清空：第二次等待拿不到同一条")
    }

    func testRepeatedCallbackForAConsumedStateIsDropped() async {
        inbox.deliver(.code(code: "C1", state: "S1"))
        let first = await received(startClaim("S1"))
        XCTAssertEqual(first, .code(code: "C1", state: "S1"), "前提：第一次认领拿到")
        clock.now += 1000
        inbox.deliver(.code(code: "C1", state: "S1"))
        inbox.deliver(.code(code: "C9", state: "S1"))
        await assertNothingDelivered(startClaim("S1"), "同一 state 已交付过，10 分钟内再来的回跳丢弃")
    }

    func testClearAlsoForgetsDeliveredStates() async {
        inbox.deliver(.code(code: "C1", state: "S1"))
        let first = await received(startClaim("S1"))
        XCTAssertEqual(first, .code(code: "C1", state: "S1"), "前提：第一次认领拿到")
        inbox.clear()
        inbox.deliver(.code(code: "C2", state: "S1"))
        let again = await received(startClaim("S1"))
        XCTAssertEqual(again, .code(code: "C2", state: "S1"), "clear 清掉已交付记录：同一 state 可再交付")
    }

    // MARK: - 反向（底座上就绿）

    func testSlotExpiresAfterTtl() async {
        inbox.deliver(.code(code: "C1", state: "S1"))
        clock.now += WebCodeInbox.slotTtlMillis + 1
        await assertNothingDelivered(startClaim("S1"), "超过 10 分钟的槽位作废")
    }

    func testClearEmptiesTheSlot() async {
        inbox.deliver(.code(code: "C1", state: "S1"))
        inbox.clear()
        await assertNothingDelivered(startClaim("S1"), "clear 后槽位为空")
    }

    func testClaimWithAnUnrelatedHashGetsNothing() async {
        inbox.deliver(.code(code: "C1", state: "S1"))
        await assertNothingDelivered(startClaim("s1"), "哈希区分大小写的 state")
        let probe = InboxClaimProbe()
        let inbox = inbox
        probe.task = Task { @MainActor in
            probe.result = await inbox.claim(stateSha256: "S1")
            probe.done = true
        }
        await assertNothingDelivered(probe, "按哈希认领：传 state 原文认不到")
    }
}
