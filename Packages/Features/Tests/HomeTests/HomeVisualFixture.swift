import Combine
import CouliNetwork
import Foundation
import HomeCore
import XCTest

/// APP-11v：直接读三端同一文件。sectionItems 是测试替身响应，不进入 getPage 报文。
@MainActor
final class HomeVisualFixture {
    let controller: HomeController
    let port: HomeVisualPort
    private let suite = "home-visual-\(UUID().uuidString)"
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-visual-\(UUID().uuidString)")

    init(page: String = "main_v3", mode: String = "network", level: HomeLevel = .guest,
         portOverride: (any HomeContractPort)? = nil) throws {
        let fixture = try XCTUnwrap(try SnapshotKit.goldenPages()[page] as? [String: Any])
        port = try HomeVisualPort(fixture: fixture, mode: mode)
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
            articles: VisualArticles(), lkg: lkg, prefs: HomePrefsStore(defaults: defaults),
            signals: VisualSignals(), timers: VisualTimers(), clock: clock,
            images: VisualImages(), bundled: { mode == "invalid" ? nil : HomeBundled.data() },
            appVersion: "1.10.0", gate: RetryAfterGate(clock: clock), dedupe: CardErrorDedupeBox(),
            track: { _ in }, open: { _ in }, forceUpdate: {},
            text: { key, _ in SnapshotTexts.values[key] ?? HomeTextDrafts.values[key] ?? key }
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

final class HomeVisualPort: HomeContractPort, @unchecked Sendable {
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

private struct VisualArticles: HomeArticlesApi {
    func send(_: ApiCall, isValid _: @escaping @Sendable () -> Bool,
              sendAllowed _: @escaping @Sendable () -> Bool, expected _: RequestOwnership?) async -> ApiResult {
        .success(data: Data(#"{"items":[],"next_cursor":null}"#.utf8), traceId: nil, idempotencyKey: nil)
    }
}

@MainActor private final class VisualSignals: HomeSignals {
    let visible = true
    let screenReader = true
    var changed: AnyPublisher<Void, Never> {
        Empty().eraseToAnyPublisher()
    }

    func blockers() -> Set<String> {
        []
    }
}

@MainActor private struct VisualTimers: HomeTimers {
    func after(_: Int64, _: @escaping @MainActor () -> Void) -> HomeTimerHandle {
        HomeTimerHandle {}
    }
}

private struct VisualImages: HomeImageLoader {
    func load(_ url: String) async -> Bool {
        url.hasPrefix("https://")
    }
}
