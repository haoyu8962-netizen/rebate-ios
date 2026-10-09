import CouliNetwork
import Foundation
@testable import Trade
import TradeJump
import XCTest

// MARK: - 内存假网络（执行器单测）

/// 内存里的 TradeApi：记录每次调用；每个调用挂起，直到测试 `reply`。调用方取消（Task 取消）时以 call_cancelled 结束。
final class FakeTradeApi: TradeApi, @unchecked Sendable {
    struct Sent {
        let call: ApiCall
        let isValid: @Sendable () -> Bool
    }

    private let lock = NSLock()
    private var sent: [Sent] = []
    private var waiting: [Int: CheckedContinuation<ApiResult, Never>] = [:]
    private var queued: [Int: ApiResult] = [:]
    /// 自动回答（按 operationId）；nil 时挂起等 `reply`。
    var auto: ((ApiCall) -> ApiResult?)?

    func send(_ call: ApiCall, isValid: @escaping @Sendable () -> Bool) async -> ApiResult {
        let index: Int = lock.withLock {
            sent.append(Sent(call: call, isValid: isValid))
            return sent.count - 1
        }
        if let result = auto?(call) {
            return result
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready: ApiResult? = lock.withLock {
                    if let result = queued.removeValue(forKey: index) {
                        return result
                    }
                    waiting[index] = continuation
                    return nil
                }
                if let ready {
                    continuation.resume(returning: ready)
                }
            }
        } onCancel: {
            let continuation = lock.withLock { waiting.removeValue(forKey: index) }
            continuation?.resume(returning: .localReject(reason: LocalRejectReason.callCancelled))
        }
    }

    var calls: [ApiCall] {
        lock.withLock { sent.map(\.call) }
    }

    func calls(_ operation: String) -> [ApiCall] {
        calls.filter { $0.operationId == operation }
    }

    func isValid(_ index: Int) -> Bool {
        lock.withLock { sent[index].isValid() }
    }

    func index(of operation: String, nth: Int = 0) -> Int? {
        let matched = calls.enumerated().filter { $0.element.operationId == operation }
        return nth < matched.count ? matched[nth].offset : nil
    }

    /// 给第 `index` 个调用回答（还没挂起时先存着）。
    func reply(_ index: Int, _ result: ApiResult) {
        let continuation: CheckedContinuation<ApiResult, Never>? = lock.withLock {
            if let waiting = waiting.removeValue(forKey: index) {
                return waiting
            }
            queued[index] = result
            return nil
        }
        continuation?.resume(returning: result)
    }

    func pendingCount() -> Int {
        lock.withLock { waiting.count }
    }
}

enum TradeFixtures {
    static let trace = "0199a3b4-5c6d-7e8f-9a0b-1c2d3e123456"

    static func ok(_ data: TradeObject) -> ApiResult {
        .success(data: try? JSONSerialization.data(withJSONObject: data), traceId: trace, idempotencyKey: nil)
    }

    static func fail(_ code: Int, _ data: TradeObject = [:], disableMillis: Int64? = nil) -> ApiResult {
        var effect = ErrorEffect(code: code, kind: code == 42901 ? .disableButton : .toast)
        effect.disableMillis = disableMillis
        return .failure(
            code: code, msg: "", data: try? JSONSerialization.data(withJSONObject: data), traceId: trace,
            effect: effect, idempotencyKey: nil
        )
    }

    /// 详情卡（Product 画板的牛奶：券后 ¥46.78、预估返 ¥1.23–¥2.34）。
    static func card(
        link: String = "L1", key: String = "tb:milk", platform: String = "taobao", final: Int = 4678,
        coupon: Int = 1000, rebate: (Int, Int) = (123, 234), basis: String = "normal"
    ) -> TradeObject {
        [
            "product_key": key, "item_ref": "ref-" + key, "platform": platform, "title": "milk title",
            "price_fen": final + coupon, "coupon_fen": coupon, "final_price_fen": final,
            "est_net_price_fen": final - rebate.0, "rebate_min_fen": rebate.0, "rebate_max_fen": rebate.1,
            "rebate_basis": basis, "benefit_tags": coupon > 0 ? ["有券"] : [String](), "link_id": link,
            "cta": ["text_key": coupon > 0 ? "btn.buy.coupon" : "btn.buy"], "availability": "ok",
            "disclaimer_keys": ["price_basis", "rebate_estimate"],
        ]
    }

    static func future(_ seconds: TimeInterval = 900) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds))
    }

    /// open 成功响应 data。
    static func open(
        attempt: String = "A1", steps: [TradeObject] = [["type": "scheme", "value": "app://x"]],
        expireAt: String? = nil, extra: TradeObject = [:]
    ) -> TradeObject {
        var data: TradeObject = [
            "attempt_id": attempt,
            "jump": ["primary": steps[0], "fallbacks": Array(steps.dropFirst()), "expire_at": expireAt ?? future()],
            "price_changed": false, "old_final_price_fen": 4678, "new_final_price_fen": 4678, "new_link_id": NSNull(),
            "requote_failed": false, "new_rebate_min_fen": 123, "new_rebate_max_fen": 234, "availability": "ok",
            "quoted_at": "2026-10-09T10:00:00+08:00",
        ]
        data.merge(extra) { $1 }
        return data
    }

    static func body(_ call: ApiCall) -> TradeObject {
        call.body.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? TradeObject } ?? [:]
    }
}

// MARK: - 假环境

@MainActor
final class FakePorts: JumpPorts {
    var installedValue = TradeConstants.installedUnknown
    var launchResults: [Bool] = []
    var browserResult = true
    var launched: [(String, String)] = []
    var browsed: [String] = []
    var copied: [String] = []
    /// 拉起前的钩子（模拟拉起时 App 进后台等）。
    var onLaunch: (() -> Void)?

    func installed(_: String) -> String {
        installedValue
    }

    func launchApp(type: String, value: String) async -> Bool {
        launched.append((type, value))
        onLaunch?()
        return launchResults.isEmpty ? false : launchResults.removeFirst()
    }

    func openBrowser(_ url: String) async -> Bool {
        browsed.append(url)
        onLaunch?()
        return browserResult
    }

    func copy(_ text: String) -> Bool {
        copied.append(text)
        return true
    }
}

@MainActor
final class FakeSink: LinkJumpSink {
    var events: [TradeObject] = []

    func report(_ fields: TradeObject) {
        events.append(fields)
    }
}

@MainActor
final class FakeEnv: PurchaseEnv {
    var isLoggedIn = true
    var isBasic = false
    var statuses: [String: String] = [:]
    var marked: [(String, String)] = []
    var consentRequests = 0
    var opened: [(String, [String: String])] = []
    var card: TradeObject
    var refetches: [(TradeObject, (TradeObject, TradeObject) -> TradeObject)] = []
    var help: (route: String, params: [String: String])? = ("Help", ["article_id": "a1"])

    init(card: TradeObject) {
        self.card = card
    }

    func loggedIn() -> Bool {
        isLoggedIn
    }

    func basicMode() -> Bool {
        isBasic
    }

    func requestConsent() {
        consentRequests += 1
    }

    func platformStatus(_ platform: String) -> String? {
        statuses[platform]
    }

    func markPlatformStatus(_ platform: String, status: String) {
        marked.append((platform, status))
        statuses[platform] = status
    }

    func updateCard(_ target: TradeObject, transform: @escaping (TradeObject) -> TradeObject) {
        if CardPatch.sameCard(target, card) {
            card = transform(card)
        }
    }

    func open(route: String, params: [String: String]) {
        opened.append((route, params))
    }

    func refetchCard(_ target: TradeObject, merge: @escaping (TradeObject, TradeObject) -> TradeObject) {
        refetches.append((target, merge))
    }

    func helpLink(_: String) -> (route: String, params: [String: String])? {
        help
    }
}

@MainActor
final class FakeWebCode: WebCodeAuthorizer {
    var available = true
    var result: AuthStepResult = .credential(.webCode("code-1"))
    var calls = 0

    func authorize(authUrl _: String, state _: String) async -> AuthStepResult {
        calls += 1
        return result
    }
}

/// 可控的等待：记下每次等待的毫秒数，测试 `fire` 时放行（被取消时立即结束）。
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private struct Waiter {
        let millis: Int64
        let continuation: CheckedContinuation<Void, Never>
        let id: UUID
    }

    private var waiting: [Waiter] = []
    private(set) var requested: [Int64] = []

    func sleep(_ millis: Int64) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    requested.append(millis)
                    waiting.append(Waiter(millis: millis, continuation: continuation, id: id))
                }
            }
        } onCancel: {
            let entry = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return waiting.remove(at: index).continuation
            }
            entry?.resume()
        }
    }

    /// 放行所有等待时长为 `millis` 的等待（nil = 全部）。
    func fire(_ millis: Int64? = nil) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let matched = waiting.filter { millis == nil || $0.millis == millis }
            waiting.removeAll { millis == nil || $0.millis == millis }
            return matched.map(\.continuation)
        }
        ready.forEach { $0.resume() }
    }

    var waitingCount: Int {
        lock.withLock { waiting.count }
    }
}

/// 可拨动的时钟（毫秒）；只在主线程的测试里读写。
final class PendingClock: @unchecked Sendable {
    var now: Int64 = .init(Date().timeIntervalSince1970 * 1000)
}

/// 组装一个执行器与它的替身。
@MainActor
final class PurchaseHarness {
    let api = FakeTradeApi()
    let ports = FakePorts()
    let sink = FakeSink()
    let env: FakeEnv
    /// 待办记录的时钟（默认取当前时间；测试可拨快，BR-ID-10 的 10 分钟有效期）。
    let pendingClock = PendingClock()
    let pending: MemoryPurchasePending
    let counter = AuthSheetCounter()
    let webCode = FakeWebCode()
    let baichuan = UnavailableBaichuan()
    let sleeper = ManualSleeper()
    var keys = 0
    var now: Int64 = .init(Date().timeIntervalSince1970 * 1000)
    let controller: OpenPurchaseController
    let executor: TradeJumpExecutor

    init(card: TradeObject = TradeFixtures.card()) {
        env = FakeEnv(card: card)
        let pendingClock = pendingClock
        pending = MemoryPurchasePending { pendingClock.now }
        executor = TradeJumpExecutor(ports: ports, baichuan: baichuan, sink: sink)
        let tips = JumpTipService(api: api) { "user-1" }
        var generated = 0
        let sleeper = sleeper
        controller = OpenPurchaseController(
            api: api, executor: executor, ports: ports, env: env, pending: pending, counter: counter, tips: tips,
            webCode: webCode, baichuan: baichuan,
            keyGenerator: {
                generated += 1
                return "key-\(generated)"
            },
            sleep: { await sleeper.sleep($0) }
        )
        // getTips 默认已读（不弹 JumpTip），各测试按需改
        api.auto = { call in
            call.operationId == TradeOperations.getTips
                ? TradeFixtures.ok(["jump_tip": ["taobao": "2026-10-01T00:00:00+08:00", "jd": "x", "pdd": "x"]])
                : nil
        }
    }

    func opens() -> [ApiCall] {
        api.calls(TradeOperations.openLink)
    }

    /// 回答第 n 个 open。
    func replyOpen(_ nth: Int, _ result: ApiResult) {
        guard let index = api.index(of: TradeOperations.openLink, nth: nth) else {
            XCTFail("没有第 \(nth) 个 open")
            return
        }
        api.reply(index, result)
    }
}

/// 等到条件成立（最多约 3 秒）。
@MainActor
func eventually(
    _ message: String = "条件未在超时内成立", file: StaticString = #filePath, line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async {
    for _ in 0..<300 {
        if condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail(message, file: file, line: line)
}

/// 让主线程上的结算跑完。
@MainActor
func settle() async {
    for _ in 0..<15 {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
