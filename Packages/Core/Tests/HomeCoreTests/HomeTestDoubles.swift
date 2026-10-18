import Combine
import CouliNetwork
import Foundation
import Generated
@testable import HomeCore
import Router
import XCTest

// 首页执行器测试的替身与基类（端口换替身、计时手动推进；控制器、存储、策略都是生产实现）。

/// 一次可挂住的应答：测试决定何时放行（放行前端口入口已同步计数）。
final class Hold: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ApiResult, Never>?
    private var preset: ApiResult?
    private(set) var entered = false

    func wait() async -> ApiResult {
        await withCheckedContinuation { continuation in
            lock.withLock {
                entered = true
                if let preset {
                    continuation.resume(returning: preset)
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    func release(_ result: ApiResult) {
        lock.withLock {
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: result)
            } else {
                preset = result
            }
        }
    }
}

/// 待定 operation（G02、G03）的替身。应答可以是即时结果，也可以是挂住的 `Hold`。
final class FakePort: HomeContractPort, @unchecked Sendable {
    enum Reply {
        case now(ApiResult)
        case held(Hold)
    }

    struct PageCall {
        let anonymous: Bool
        let owner: RequestOwnership?
    }

    private let lock = NSLock()
    private var pageReplies: [Reply] = []
    private var pageDefault: ApiResult
    private var pageLog: [PageCall] = []
    private var itemLog: [String] = []
    private var itemCallLog: [HomeCall] = []
    private var barrierArmed = false
    private var barrierWaiter: CheckedContinuation<Void, Never>?
    private var barrierOpenedEarly = false
    var items: @Sendable (String, String?) -> Reply = { section, cursor in
        switch (section, cursor) {
        case ("feed", nil): .now(HomeKit.items(0..<4, next: "p2"))
        case ("feed", _): .now(HomeKit.items(4..<6, next: nil))
        default: .now(HomeKit.items(0..<4, next: nil))
        }
    }

    init(page: ApiResult = HomeKit.ok(HomeKit.page(version: 2, [HomeKit.activity("net", titles: ["测试网络版"])]))) {
        pageDefault = page
    }

    /// 之后每次 getPage 的应答（用完回到缺省）。
    func queuePage(_ replies: Reply...) {
        lock.withLock { pageReplies += replies }
    }

    func setPage(_ result: ApiResult) {
        lock.withLock { pageDefault = result }
    }

    var pageCalls: [PageCall] {
        lock.withLock { pageLog }
    }

    /// `sectionId|cursor`（cursor 为空写空串）。
    var itemCalls: [String] {
        lock.withLock { itemLog }
    }

    var itemCallObjects: [HomeCall] {
        lock.withLock { itemCallLog }
    }

    /// 下一次 getPage 在「实际发出前」（核对发送前闸门之前）停在屏障，直到 `openBarrier()`。
    func armBarrier() {
        lock.withLock { barrierArmed = true }
    }

    /// 有请求停在屏障上（等待者已登记）。
    var atBarrier: Bool {
        lock.withLock { barrierWaiter != nil }
    }

    func openBarrier() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            barrierArmed = false
            guard let waiter = barrierWaiter else {
                barrierOpenedEarly = true
                return nil
            }
            barrierWaiter = nil
            return waiter
        }
        waiter?.resume()
    }

    private func passBarrier() async {
        await withCheckedContinuation { continuation in
            let pass: Bool = lock.withLock {
                guard barrierArmed, !barrierOpenedEarly else {
                    barrierOpenedEarly = false
                    return true
                }
                barrierWaiter = continuation
                return false
            }
            if pass {
                continuation.resume()
            }
        }
    }

    func getPage(pageKey: String, call: HomeCall) async -> ApiResult {
        XCTAssertEqual(pageKey, "home")
        await passBarrier()
        // 发送前闸门在入口核对（限流禁用期 / 已作废的控制器不得发出）
        guard call.sendAllowed() else { return .localReject(reason: LocalRejectReason.sendBlocked) }
        let reply: Reply = lock.withLock {
            pageLog.append(PageCall(anonymous: call.anonymous, owner: call.owner))
            return pageReplies.isEmpty ? .now(pageDefault) : pageReplies.removeFirst()
        }
        switch reply {
        case let .now(result): return result
        case let .held(hold): return await hold.wait()
        }
    }

    func listSectionItems(pageKey _: String, sectionId: String, cursor: String?, call: HomeCall) async -> ApiResult {
        guard call.sendAllowed() else { return .localReject(reason: LocalRejectReason.sendBlocked) }
        let reply = lock.withLock {
            itemLog.append("\(sectionId)|\(cursor ?? "")")
            itemCallLog.append(call)
            return items(sectionId, cursor)
        }
        switch reply {
        case let .now(result): return result
        case let .held(hold): return await hold.wait()
        }
    }
}

/// listArticles 的替身（真实 ApiClient 的请求形状在 AppTests 里断言）。
final class FakeArticles: HomeArticlesApi, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [ApiCall] = []
    private var replies: [FakePort.Reply] = []
    var fallback: ApiResult = HomeKit.notices()

    var calls: [ApiCall] {
        lock.withLock { log }
    }

    func queue(_ replies: FakePort.Reply...) {
        lock.withLock { self.replies += replies }
    }

    func send(
        _ call: ApiCall, isValid _: @escaping @Sendable () -> Bool, sendAllowed: @escaping @Sendable () -> Bool,
        expected _: RequestOwnership?
    ) async -> ApiResult {
        guard sendAllowed() else { return .localReject(reason: LocalRejectReason.sendBlocked) }
        let reply: FakePort.Reply = lock.withLock {
            log.append(call)
            return replies.isEmpty ? .now(fallback) : replies.removeFirst()
        }
        switch reply {
        case let .now(result): return result
        case let .held(hold): return await hold.wait()
        }
    }
}

/// 线程安全的当前时刻（发送前闸门在任意线程读时钟）。
final class TimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int64

    init(_ start: Int64) {
        current = start
    }

    var value: Int64 {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// 手动推进的计时（测试不睡）。`advance` 先推进时钟，再按到期先后执行到期的计时。
@MainActor
final class ManualClock: HomeTimers {
    private struct Pending {
        let id: Int
        let at: Int64
        let block: @MainActor () -> Void
    }

    let time: TimeBox
    private var pending: [Pending] = []
    private var cancelled: Set<Int> = []
    private var serial = 0

    init(_ start: Int64 = HomeKit.noon) {
        time = TimeBox(start)
    }

    var now: Int64 {
        time.value
    }

    var clock: @Sendable () -> Int64 {
        { [time] in time.value }
    }

    func after(_ delayMs: Int64, _ block: @escaping @MainActor () -> Void) -> HomeTimerHandle {
        serial += 1
        let id = serial
        pending.append(Pending(id: id, at: now + max(0, delayMs), block: block))
        return HomeTimerHandle { [weak self] in
            MainActor.assumeIsolated { _ = self?.cancelled.insert(id) }
        }
    }

    /// 还没到期、没取消的计时个数。
    var scheduled: Int {
        pending.count(where: { !cancelled.contains($0.id) })
    }

    func advance(_ ms: Int64) {
        let target = now + ms
        while let next = pending.filter({ !cancelled.contains($0.id) && $0.at <= target }).min(by: { $0.at < $1.at }) {
            pending.removeAll { $0.id == next.id }
            time.value = next.at
            next.block()
        }
        time.value = target
    }

    /// 只推进时钟、不执行计时（模拟「计时还没触发」的窗口）。
    func jump(_ ms: Int64) {
        time.value += ms
    }
}

/// 首页可见性、读屏与阻挡项（App 侧接真实来源；这里由测试改）。
@MainActor
final class FakeSignals: HomeSignals {
    private let subject = PassthroughSubject<Void, Never>()
    var visible = true {
        didSet { subject.send() }
    }

    var screenReader = false {
        didSet { subject.send() }
    }

    var blocking: Set<String> = [] {
        didSet { subject.send() }
    }

    func blockers() -> Set<String> {
        blocking
    }

    var changed: AnyPublisher<Void, Never> {
        subject.eraseToAnyPublisher()
    }
}

/// 图片加载替身：按地址给结果；可挂住。登记等待者与发布「已在等待」在同一把锁里；放行先于等待到达时保存结果（不丢放行）。
final class FakeImages: HomeImageLoader, @unchecked Sendable {
    private let lock = NSLock()
    private var failing: Set<String> = []
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
    private var early: [String: Bool] = [:]
    private var log: [String] = []

    var loads: [String] {
        lock.withLock { log }
    }

    /// 该地址的加载已挂在替身里等待放行。
    func waiting(_ url: String) -> Bool {
        lock.withLock { !(waiters[url] ?? []).isEmpty }
    }

    func fail(_ url: String) {
        lock.withLock { _ = failing.insert(url) }
    }

    func hold(_ url: String) {
        lock.withLock { _ = held.insert(url) }
    }

    func release(_ url: String, _ ok: Bool) {
        let continuations: [CheckedContinuation<Bool, Never>] = lock.withLock {
            held.remove(url)
            let waiting = waiters.removeValue(forKey: url) ?? []
            if waiting.isEmpty {
                early[url] = ok
            }
            return waiting
        }
        continuations.forEach { $0.resume(returning: ok) }
    }

    func load(_ url: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let immediate: Bool? = lock.withLock {
                log.append(url)
                if let result = early.removeValue(forKey: url) {
                    return result
                }
                guard held.contains(url) else {
                    return !failing.contains(url) && url.hasPrefix("https://")
                }
                waiters[url, default: []].append(continuation)
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }
}
