import Combine
import CouliNetwork
import Foundation
import HomeCore
import XCTest

/// FU-IOS-A11Y v4：首页读屏用例的夹具。包测试（HomeTests）进程里 SwiftUI 无障碍树取不到节点（实现者 r3 诊断），
/// 所以把 HomeTests 的 `HomeVisualFixture`（APP-11v，三端同一份 goldenPages、同一套替身端口）原样搬到 App 测试里，只改类型名。
@MainActor
final class A11yHomeFixture {
    let controller: HomeController
    let port: A11yHomePort
    private let suite = "a11y-home-\(UUID().uuidString)"
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("a11y-home-\(UUID().uuidString)")

    init(page: String = "main_v3", mode: String = "network", level: HomeLevel = .guest,
         portOverride: (any HomeContractPort)? = nil) throws {
        let fixture = try A11yHomeFixture.page(page)
        port = try A11yHomePort(fixture: fixture, mode: mode)
        let identity = HomeIdentity(env: "test", level: level, userId: nil, loginEpoch: nil)
        let lkg = HomeLkgStore(root: root)
        if mode == "lkg" {
            let scope = try XCTUnwrap(identity.lkgScope)
            XCTAssertTrue(lkg.write(scope, port.page, ticket: lkg.ticket()))
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let clock: @Sendable () -> Int64 = { 1_791_604_800_000 }
        let deps = HomeDeps(
            port: ["bundled", "invalid"].contains(mode) ? nil : (portOverride ?? port),
            articles: A11yHomeArticles(), lkg: lkg, prefs: HomePrefsStore(defaults: defaults),
            signals: A11yHomeSignals(), timers: A11yHomeTimers(), clock: clock,
            images: A11yHomeImages(), bundled: { mode == "invalid" ? nil : HomeBundled.data() },
            appVersion: "1.10.0", gate: RetryAfterGate(clock: clock), dedupe: CardErrorDedupeBox(),
            track: { _ in }, open: { _ in }, forceUpdate: {},
            text: { key, _ in A11yHomeFixture.texts[key] ?? HomeTextDrafts.values[key] ?? key }
        )
        controller = HomeController(identity: identity, deps: deps)
    }

    func start() async {
        controller.start()
        if port.mode != "loading" {
            await controller.whenIdle()
        }
    }

    func close() async {
        port.release()
        await controller.whenIdle()
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

final class A11yHomePort: HomeContractPort, @unchecked Sendable {
    let page: Data
    let mode: String
    private let responses: [String: Data]
    private let lock = NSLock()
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(fixture: [String: Any], mode: String) throws {
        self.mode = mode
        var wire = fixture
        wire.removeValue(forKey: "sectionItems")
        page = try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys])
        let sections = fixture["sectionItems"] as? [String: Any] ?? [:]
        responses = try sections.mapValues { try JSONSerialization.data(withJSONObject: $0) }
    }

    func release() {
        let continuation = lock.withLock {
            released = true
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }

    func getPage(pageKey _: String, call _: HomeCall) async -> ApiResult {
        if mode == "loading" {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock {
                    if released {
                        return true
                    }
                    waiting = continuation
                    return false
                }
                if resume {
                    continuation.resume()
                }
            }
        }
        if mode == "lkg" {
            return Self.failure
        }
        return .success(data: page, traceId: nil, idempotencyKey: nil)
    }

    func listSectionItems(pageKey _: String, sectionId: String, cursor: String?, call _: HomeCall) async -> ApiResult {
        if mode == "feed_failure", sectionId == "feed", cursor != nil {
            return Self.failure
        }
        if mode == "empty" {
            return .success(data: Self.empty, traceId: nil, idempotencyKey: nil)
        }
        var data = responses[sectionId] ?? Self.empty
        if mode == "feed_failure", sectionId == "feed", cursor == nil,
           var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            object["next_cursor"] = "visual-next"
            data = (try? JSONSerialization.data(withJSONObject: object)) ?? data
        }
        return .success(data: data, traceId: nil, idempotencyKey: nil)
    }

    private static let empty = Data(#"{"items":[],"next_cursor":null}"#.utf8)
    private static var failure: ApiResult {
        .transportFailure(kind: "offline", httpStatus: nil, idempotencyKey: nil, pendingKeyUnknown: false)
    }
}

private struct A11yHomeArticles: HomeArticlesApi {
    func send(_: ApiCall, isValid _: @escaping @Sendable () -> Bool,
              sendAllowed _: @escaping @Sendable () -> Bool, expected _: RequestOwnership?) async -> ApiResult {
        .success(data: Data(#"{"items":[],"next_cursor":null}"#.utf8), traceId: nil, idempotencyKey: nil)
    }
}

@MainActor private final class A11yHomeSignals: HomeSignals {
    let visible = true
    let screenReader = true
    var changed: AnyPublisher<Void, Never> {
        Empty().eraseToAnyPublisher()
    }

    func blockers() -> Set<String> {
        []
    }
}

@MainActor private struct A11yHomeTimers: HomeTimers {
    func after(_: Int64, _: @escaping @MainActor () -> Void) -> HomeTimerHandle {
        HomeTimerHandle {}
    }
}

private struct A11yHomeImages: HomeImageLoader {
    func load(_ url: String) async -> Bool {
        url.hasPrefix("https://")
    }
}

extension A11yHomeFixture {
    /// 三端同一份首页 goldenPages（specs/home-sdui-vectors.json，同 HomeTests 的 SnapshotKit.goldenPages）。
    static func goldenPages() throws -> [String: Any] {
        let data = try Data(contentsOf: A11yAudit.repositoryRoot()
            .appendingPathComponent("specs/home-sdui-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["goldenPages"] as? [String: Any])
    }

    /// 口径句（同 HomeTests 的 SnapshotTexts）。
    static let texts: [String: String] = [
        "price_basis": "券后价按单件计算，不含运费及会员价等优惠，以下单页为准",
        "price_basis.general": "价格按单件计算，不含运费及会员价等优惠，以下单页为准",
        "rebate_estimate": "预估返利以平台结算为准，未结算或订单失效时不返",
    ]
}

extension A11yHomeFixture {
    /// 本单专用页名 `main_v3_two_more`（v6）：`main_v3` 只有「今日精选」配了「更多」跳转，这里在内存里复制一份，给「超市百货」（grid）
    /// 也补上「更多」（跳搜索「超市百货」），供「同屏多个『更多』要能区分」用例用；共用 goldenPages 文件不动，别的页名原样返回。
    static func page(_ name: String) throws -> [String: Any] {
        let pages = try goldenPages()
        guard name == "main_v3_two_more" else {
            return try XCTUnwrap(pages[name] as? [String: Any])
        }
        var page = try XCTUnwrap(pages["main_v3"] as? [String: Any])
        var sections = try XCTUnwrap(page["sections"] as? [[String: Any]])
        let index = try XCTUnwrap(sections.firstIndex { $0["id"] as? String == "grid" })
        var props = sections[index]["props"] as? [String: Any] ?? [:]
        props["more_action"] = ["route": "Search", "params": ["q": "超市百货"]]
        sections[index]["props"] = props
        page["sections"] = sections
        return page
    }
}
