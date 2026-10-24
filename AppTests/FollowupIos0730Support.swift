import Clipboard
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Privacy
import Router
import XCTest

/// FU-IOS-0730（F-IOS-42 前两条）测试共用：真实 AppClipboard（生产入口 pasted / beginPaste / retryParse，界面读 `result`）+ 按次排队的
/// 假 parse 服务（ApiCall 级，回答是任意 ApiResult：传输失败、成功但结果为空、业务错误码、本地拒绝）。
@MainActor
class FollowupIos0730TestCase: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    let link = "【淘宝】降噪耳机 https://e.tb.cn/h.Demo01?tk=Sample 「降噪蓝牙耳机」 复制这段话打开"
    let plain = "普通文字，没有链接"
    let invite = "邀请码 K7M2QX"
    let trace = "trace-00001a2b3c"

    override func setUpWithError() throws {
        suiteName = "FollowupIos0730.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    struct Fixture {
        let clipboard: AppClipboard
        let routing: AppRouting
        let api: FollowupIos0730ParseApi
        let state: ClipboardWiringTests.FakeState
    }

    func make() -> Fixture {
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = "consented"
        privacyStore.consentedVersion = "1"
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: .init(cleaners: []))
        let privacy = PrivacyController(store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1")
        let routing = AppRouting(environment: environment, privacy: privacy, update: UpdateFixtures.makeUpdate())
        routing.shellAppeared()
        let api = FollowupIos0730ParseApi()
        let state = ClipboardWiringTests.FakeState()
        let clipboard = AppClipboard(
            system: FakeSystemClipboard(), store: MemoryClipboardHashStore(), api: api, router: routing.router,
            deps: AppClipboard.Deps(
                privacy: { state.privacy }, privacyPrompting: { false }, forceUpdate: { false },
                configJson: { state.config }, guest: { state.guest },
                sessionGeneration: { state.session }, networkEpoch: { state.epoch },
                serverForced: { state.forced += 1 },
                networkForced: { state.networkForced.append($0) }
            )
        )
        clipboard.overlaySource = { state.overlay }
        clipboard.sceneActive()
        return Fixture(clipboard: clipboard, routing: routing, api: api, state: state)
    }

    func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    /// 进 SearchTyping（Search 路由的一个页面实例），返回它的目的地。
    func openSearchTyping(_ fixture: Fixture) -> RouteDestination {
        let search = RouteDestination(route: AppClipboard.searchRoute)
        fixture.routing.router.path = [search]
        return search
    }

    // MARK: - 回答

    static func timeout() -> ApiResult {
        .transportFailure(kind: "timeout", httpStatus: nil, idempotencyKey: nil, pendingKeyUnknown: false)
    }

    /// 断连与无网：HttpTransport 把 URLError 里除 timedOut / cancelled 以外的（含 notConnectedToInternet）都记为 disconnect。
    static func disconnect() -> ApiResult {
        .transportFailure(kind: "disconnect", httpStatus: nil, idempotencyKey: nil, pendingKeyUnknown: false)
    }

    static func success(_ json: String?, trace: String?) -> ApiResult {
        .success(data: json.map { Data($0.utf8) }, traceId: trace, idempotencyKey: nil)
    }

    func businessFailure(_ code: Int, kind: ErrorEffectKind = .toast, disableMillis: Int64? = nil) -> ApiResult {
        var effect = ErrorEffect(code: code, kind: kind)
        effect.disableMillis = disableMillis
        return .failure(code: code, msg: "", data: nil, traceId: trace, effect: effect, idempotencyKey: nil)
    }

    static func dropped() -> ApiResult {
        .localReject(reason: LocalRejectReason.callCancelled)
    }

    static func card() -> ApiResult {
        let card = #"{"product_key":"tb:milk","platform":"taobao","item_ref":"ref-1","link_id":"l-1","title":"t"}"#
        return success(#"{"results":[{"card":\#(card)}]}"#, trace: "trace-card")
    }

    // MARK: - 结果读数（首页 / SearchTyping 结果卡的视图模型就是 AppClipboard.result）

    /// 结果种类的短名：unrecognized = ①，networkFailed = ⑤（带【重试】）。
    static func name(_ result: ClipboardResult?) -> String {
        guard let result else { return "nil" }
        switch result.kind {
        case .notice: return "notice"
        case .unrecognized: return "unrecognized"
        case .cardList: return "cardList"
        case .networkFailed: return "networkFailed"
        case .inviteConfirm: return "inviteConfirm"
        }
    }

    static func text(_ result: ClipboardResult?) -> String? {
        switch result?.kind {
        case let .notice(text)?, let .unrecognized(text, _)?, let .networkFailed(text, _)?: text
        default: nil
        }
    }

    /// 先在当前页出一张 ⑤ 卡（传输失败）。
    func showNetworkFailed(_ fixture: Fixture, entry: String) async throws -> ClipboardResult {
        fixture.api.enqueue(Self.timeout())
        fixture.clipboard.pasted(entry: entry, text: link)
        await settle()
        let result = try XCTUnwrap(fixture.clipboard.result, "前置：传输失败出 ⑤ 卡")
        XCTAssertEqual(Self.name(result), "networkFailed", "前置：传输失败出 ⑤ 卡")
        return result
    }

    /// 先在当前页出一张 ① 卡（本地识别不了，G10）。
    func showUnrecognized(_ fixture: Fixture, entry: String) throws -> ClipboardResult {
        fixture.clipboard.pasted(entry: entry, text: plain)
        let result = try XCTUnwrap(fixture.clipboard.result, "前置：本地识别不了出 ① 卡")
        XCTAssertEqual(Self.name(result), "unrecognized", "前置：本地识别不了出 ① 卡")
        return result
    }
}

/// 按次排队的假 parse 服务：每次 send 取队首回答（队列空时给 `fallback`）；`hold` 时挂起到 `release`。
final class FollowupIos0730ParseApi: ParseApi, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ApiResult] = []
    private var bodies: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var holding = false
    var fallback: ApiResult = .localReject(reason: LocalRejectReason.callCancelled)

    var sent: Int {
        lock.withLock { bodies.count }
    }

    func enqueue(_ results: ApiResult...) {
        lock.withLock { queue.append(contentsOf: results) }
    }

    func hold() {
        lock.withLock { holding = true }
    }

    func release() {
        let pending = lock.withLock {
            holding = false
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    func send(_ call: ApiCall, isValid: @escaping @Sendable () -> Bool) async -> ApiResult {
        let (held, answer) = lock.withLock {
            bodies.append(call.body ?? "")
            let next = queue.isEmpty ? fallback : queue.removeFirst()
            return (holding, next)
        }
        if held {
            await withCheckedContinuation { continuation in
                lock.withLock { waiters.append(continuation) }
            }
        }
        guard isValid() else { return .localReject(reason: LocalRejectReason.callCancelled) }
        return answer
    }
}
