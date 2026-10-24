#if DEBUG
import CouliNetwork
import Foundation
import HomeCore
import UIKit

/// 首页视觉 UI 测试的本机首页端口（APP-11v；只在 Debug / Staging 编译）：按请求里的共用 fixture 回答 getPage / listSectionItems，
/// 计数全部来自实际收到的调用。只换数据，不改控制器、渲染与判定。
final class DebugHomeVisualPort: HomeContractPort, @unchecked Sendable {
    private let lock = NSLock()
    private let scene: String
    private let page: Data
    private let responses: [String: Data]
    private var pageCalls = 0
    private var sectionCalls = 0
    private var inflight = 0
    private var holdPages = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(scene: String, page: Data, responses: [String: Data]) {
        self.scene = scene
        self.page = page
        self.responses = responses
    }

    struct Counts {
        let pages: Int
        let sections: Int
        let inflight: Int
    }

    var counts: Counts {
        lock.withLock { Counts(pages: pageCalls, sections: sectionCalls, inflight: inflight) }
    }

    /// 之后的 getPage 挂住，直到 `release()`（登录后挂住会员页面）。
    func hold() {
        lock.withLock { holdPages = true }
    }

    /// 放开挂住的 getPage（以断网结束）并不再挂。
    func release() {
        let waiting = lock.withLock {
            holdPages = false
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    func getPage(pageKey _: String, call: HomeCall) async -> ApiResult {
        guard call.sendAllowed() else {
            return .localReject(reason: LocalRejectReason.sendBlocked)
        }
        let hang = lock.withLock {
            pageCalls += 1
            inflight += 1
            return holdPages || scene == "loading"
        }
        defer { lock.withLock { inflight -= 1 } }
        if hang {
            await withCheckedContinuation { continuation in
                let waits = lock.withLock {
                    guard holdPages || scene == "loading" else { return false }
                    held.append(continuation)
                    return true
                }
                if !waits {
                    continuation.resume()
                }
            }
            return Self.offline
        }
        try? await Task.sleep(for: .milliseconds(50))
        if ["lkg", "invalid"].contains(scene) {
            return Self.offline
        }
        return .success(data: page, traceId: nil, idempotencyKey: nil)
    }

    func listSectionItems(pageKey _: String, sectionId: String, cursor: String?, call: HomeCall) async -> ApiResult {
        guard call.sendAllowed() else {
            return .localReject(reason: LocalRejectReason.sendBlocked)
        }
        lock.withLock {
            sectionCalls += 1
            inflight += 1
        }
        defer { lock.withLock { inflight -= 1 } }
        try? await Task.sleep(for: .milliseconds(50))
        if scene == "feed_failure", sectionId == "feed", cursor != nil {
            return Self.offline
        }
        if scene == "empty" {
            return .success(data: Self.empty, traceId: nil, idempotencyKey: nil)
        }
        if scene == "long_feed", sectionId == "feed" {
            // 长信息流测量：按游标连续多页（DebugHomeVisualLongFeed）
            return .success(data: DebugHomeVisualLongFeed.page(template: responses[sectionId], cursor: cursor),
                            traceId: nil, idempotencyKey: nil)
        }
        var data = responses[sectionId] ?? Self.empty
        if scene == "feed_failure", sectionId == "feed", cursor == nil,
           var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            object["next_cursor"] = "visual-next"
            data = (try? JSONSerialization.data(withJSONObject: object)) ?? data
        }
        return .success(data: data, traceId: nil, idempotencyKey: nil)
    }

    private static let empty = Data(#"{"items":[],"next_cursor":null}"#.utf8)
    private static var offline: ApiResult {
        .transportFailure(kind: "offline", httpStatus: nil, idempotencyKey: nil, pendingKeyUnknown: false)
    }
}

/// 可控时钟与计时器：时间只在 `advance` 时前进（加载场景停在 1500ms 兜底之前；公告 / 弹窗计时固定在第一帧）。
@MainActor
final class DebugHomeVisualClock: HomeTimers {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var now: Int64 = 1_791_604_800_000
    }

    private let box = Box()
    private(set) var advanced: Int64 = 0
    private struct Pending {
        let due: Int64
        let id: Int
        let block: @MainActor () -> Void
    }

    private var pending: [Pending] = []
    private var serial = 0

    var clock: @Sendable () -> Int64 {
        let box = box
        return { box.lock.withLock { box.now } }
    }

    func after(_ ms: Int64, _ block: @escaping @MainActor () -> Void) -> HomeTimerHandle {
        serial += 1
        let id = serial
        let due = box.lock.withLock { box.now } + max(0, ms)
        pending.append(Pending(due: due, id: id, block: block))
        return HomeTimerHandle { [weak self] in
            MainActor.assumeIsolated { self?.pending.removeAll { $0.id == id } }
        }
    }

    func advance(_ ms: Int64) {
        advanced += ms
        let target = box.lock.withLock {
            box.now += ms
            return box.now
        }
        while let next = pending.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
            pending.removeAll { $0.id == next.id }
            next.block()
        }
    }
}

/// 首页预载图片（弹窗 / 轮播）的本机替身：只认测试图片主机，其余记为意外请求。
struct DebugHomeVisualImages: HomeImageLoader {
    func load(_ url: String) async -> Bool {
        guard let host = URL(string: url)?.host, DebugHomeVisualNetworkGuard.imageHosts.contains(host) else {
            DebugHomeVisualNetworkGuard.noteUnexpected()
            return false
        }
        return true
    }
}

/// 系统 URLSession.shared（AsyncImage）的本机替身：测试图片主机回固定色块 PNG（与 AppTests 的色块同色）；
/// 其余主机（除已有假图片主机）一律记为意外请求并以失败结束，不连外网。
final class DebugHomeVisualNetworkGuard: URLProtocol, @unchecked Sendable {
    /// 测试图片主机：共用 fixture 用 img.example.test，既有 golden 区块（轮播 / 公告 / 弹窗）用 img.example.com。
    static let imageHosts: Set<String> = ["img.example.test", "img.example.com"]
    private static let allowedHosts: Set<String> = imageHosts.union([DebugFakeSearchImages.host])
    private static let lock = NSLock()
    private nonisolated(unsafe) static var started = 0
    private nonisolated(unsafe) static var finished = 0
    private nonisolated(unsafe) static var unexpected = 0

    static func install() {
        URLProtocol.registerClass(DebugHomeVisualNetworkGuard.self)
    }

    static func noteUnexpected() {
        lock.withLock { unexpected += 1 }
    }

    struct Stats {
        let started: Int
        let finished: Int
        let unexpected: Int
    }

    static var stats: Stats {
        lock.withLock { Stats(started: started, finished: finished, unexpected: unexpected) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return imageHosts.contains(host) || !allowedHosts.contains(host)
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host, Self.imageHosts.contains(host) else {
            Self.noteUnexpected()
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        Self.lock.withLock { Self.started += 1 }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).pngData { context in
            UIColor(red: 0.10, green: 0.55, blue: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                          headerFields: ["Content-Type": "image/png"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: png)
        client?.urlProtocolDidFinishLoading(self)
        Self.lock.withLock { Self.finished += 1 }
    }

    override func stopLoading() {}
}
#endif
