import ClientCore
import Combine
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import HomeCore
import Privacy
import Router
import Session
import SwiftUI
import Update
import XCTest

/// 埋点记录（App 的 track 出口）。
@MainActor
final class TrackRecorder {
    var events: [TrackEvent] = []
}

/// 待定 operation（getPage、listSectionItems）的替身：入口同步计数，可挂住。
final class TestHomePort: HomeContractPort, @unchecked Sendable {
    struct Call: Sendable {
        let anonymous: Bool
        let owner: RequestOwnership?
    }

    private let lock = NSLock()
    private var page: [String: Any]
    private var pageResult: ApiResult?
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var log: [Call] = []
    private var itemLog: [String] = []
    /// 按请求归属给不同的页面（换账号用例：A、B 各自的人群卡）；nil = 用 `page`。
    private var byOwner: (@Sendable (Call) -> [String: Any])?
    private var itemsReply: (@Sendable (String, String?) -> ApiResult)?

    init(page: [String: Any] = TestHomePort.page(version: 2, ids: ["net"])) {
        self.page = page
    }

    static func page(version: Int, ids: [String], extra: [[String: Any]] = []) -> [String: Any] {
        [
            "page_key": "home", "version": version,
            "sections": ids.map { id in
                [
                    "id": id, "type": "activity_entry", "version": 1, "props": [:] as [String: Any],
                    "data_source": ["kind": "static", "items": [["title": "测试\(id)", "action": ["route": "Help"]]]],
                ] as [String: Any]
            } + extra,
        ]
    }

    func set(_ page: [String: Any]) {
        lock.withLock {
            self.page = page
            pageResult = nil
        }
    }

    func set(byOwner: @escaping @Sendable (Call) -> [String: Any]) {
        lock.withLock { self.byOwner = byOwner }
    }

    func set(result: ApiResult) {
        lock.withLock { pageResult = result }
    }

    /// 之后的 getPage 在入口计数后挂住，直到 `release()`。
    func hold() {
        lock.withLock { holding = true }
    }

    func release() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            holding = false
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    var calls: [Call] {
        lock.withLock { log }
    }

    var itemCalls: [String] {
        lock.withLock { itemLog }
    }

    func getPage(pageKey _: String, call: HomeCall) async -> ApiResult {
        guard call.sendAllowed() else { return .localReject(reason: LocalRejectReason.sendBlocked) }
        let entry = Call(anonymous: call.anonymous, owner: call.owner)
        let wait: Bool = lock.withLock {
            log.append(entry)
            return holding
        }
        if wait {
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = lock.withLock {
                    guard holding else { return true }
                    held.append(continuation)
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        }
        return lock.withLock {
            if let pageResult {
                return pageResult
            }
            let object = byOwner?(entry) ?? page
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return .success(data: data, traceId: "trace-home-000001", idempotencyKey: nil)
        }
    }

    /// 商品池 / 信息流的应答（缺省空页）。
    func set(items: @escaping @Sendable (String, String?) -> ApiResult) {
        lock.withLock { itemsReply = items }
    }

    func listSectionItems(pageKey _: String, sectionId: String, cursor: String?, call: HomeCall) async -> ApiResult {
        guard call.sendAllowed() else { return .localReject(reason: LocalRejectReason.sendBlocked) }
        let reply = lock.withLock {
            itemLog.append("\(sectionId)|\(cursor ?? "")")
            return itemsReply
        }
        if let reply {
            return reply(sectionId, cursor)
        }
        return .success(data: Data(#"{"items":[],"next_cursor":null}"#.utf8), traceId: nil, idempotencyKey: nil)
    }
}

/// 图片加载替身：缺省 https 一律成功；可挂住某个地址。登记等待者与「已在等待」在同一把锁里，提前放行的结果会保存。
final class TestHomeImages: HomeImageLoader, @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<String> = []
    private var failing: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
    private var early: [String: Bool] = [:]
    private var log: [String] = []

    var loads: [String] {
        lock.withLock { log }
    }

    func waiting(_ url: String) -> Bool {
        lock.withLock { !(waiters[url] ?? []).isEmpty }
    }

    func hold(_ url: String) {
        lock.withLock { _ = held.insert(url) }
    }

    func fail(_ url: String) {
        lock.withLock { _ = failing.insert(url) }
    }

    func release(_ url: String, _ ok: Bool = true) {
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

/// 手动推进的首页计时与时钟（2026-10-10 12:00 上海）。
@MainActor
final class TestHomeClock: HomeTimers {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var now: Int64 = 1_791_604_800_000
    }

    private struct Pending {
        let id: Int
        let at: Int64
        let block: @MainActor () -> Void
    }

    private let box = Box()
    private var pending: [Pending] = []
    private var cancelled: Set<Int> = []
    private var serial = 0

    var now: Int64 {
        box.lock.withLock { box.now }
    }

    nonisolated var clock: @Sendable () -> Int64 {
        { [box] in box.lock.withLock { box.now } }
    }

    func after(_ delayMs: Int64, _ block: @escaping @MainActor () -> Void) -> HomeTimerHandle {
        serial += 1
        let id = serial
        pending.append(Pending(id: id, at: now + max(0, delayMs), block: block))
        return HomeTimerHandle { [weak self] in
            MainActor.assumeIsolated { _ = self?.cancelled.insert(id) }
        }
    }

    func advance(_ ms: Int64) {
        let target = now + ms
        while let next = pending.filter({ !cancelled.contains($0.id) && $0.at <= target }).min(by: { $0.at < $1.at }) {
            pending.removeAll { $0.id == next.id }
            box.lock.withLock { box.now = next.at }
            next.block()
        }
        box.lock.withLock { box.now = target }
    }
}

extension HomeAppSamples {
    /// 契约 ProductCard 形状的测试商品页（数字照 Main 稿）。
    static func products(_ keys: [String]) -> ApiResult {
        let items: [[String: Any]] = keys.enumerated().map { index, key in
            [
                "product_key": key, "item_ref": "v1.\(key).sig", "platform": "taobao", "title": "林间果 每日坚果 30袋",
                "image": "https://img.example.com/p/\(index).png", "shop_name": "示例旗舰店", "price_fen": 2290,
                "coupon_fen": 300, "final_price_fen": 1990, "est_net_price_fen": 1880, "rebate_min_fen": 110,
                "rebate_max_fen": 110, "rebate_basis": "normal", "benefit_tags": ["有券"], "is_presale": false,
                "link_id": "link.\(index)", "cta": ["text_key": "btn.buy"], "quoted_at": "2026-10-10T10:00:00+08:00",
                "stale": false, "age_sec": 30, "source": "taobao_union",
                "disclaimer_keys": ["price_basis", "rebate_estimate"], "availability": "ok",
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["items": items, "next_cursor": NSNull()])) ?? Data()
        return .success(data: data, traceId: "trace-home-items1", idempotencyKey: nil)
    }

    static func failure(_ code: Int) -> ApiResult {
        let effect = ErrorEffect(code: code, kind: code == 10405 ? .forceUpdate : .genericError)
        return .failure(
            code: code,
            msg: "test",
            data: nil,
            traceId: "trace-home-ABC123",
            effect: effect,
            idempotencyKey: nil
        )
    }

    static var pool: [String: Any] {
        [
            "id": "scroll", "type": "product_scroll", "version": 1, "props": ["title": "今日精选"],
            "data_source": ["kind": "product_pool", "pool_id": "test_pool", "limit": 20],
        ]
    }

    static var noticeApi: [String: Any] {
        [
            "id": "nb_api", "type": "notice_bar", "version": 1, "props": [:] as [String: Any],
            "data_source": ["kind": "api"],
        ]
    }
}
