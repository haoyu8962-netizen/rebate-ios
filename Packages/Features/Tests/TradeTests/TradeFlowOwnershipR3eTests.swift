import CouliNetwork
import Foundation
import Session
@testable import Trade
import TradeJump
import XCTest

/// APP-08 iOS 第五次修复 RC-06 残余（S0）：open 首发与超时重试、授权查询 / 绑定 / 30104 恢复都带尝试固定的请求归属交真实 ApiClient。
/// 执行器这一层的来源比较刻意保持不变（来源是固定字符串），只验证网络层这一道：检查通过之后、网络首次绑定之前换成 B，零发送。
/// 换号发生在 ApiClient 读状态的那一刻（`swapOnNextRead`），即「执行器的 alive / 来源检查已通过、请求已排队、尚未绑定」。
@MainActor
final class TradeFlowOwnershipR3eTests: XCTestCase {
    private struct Device: DeviceCredentials {
        var deviceId: String? = "dev-1"
        var installSecret: String? = "placeholder"
    }

    private nonisolated static func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }

    private nonisolated static var authData: [String: Any] {
        ["auth_url": "https://oauth.test/a?state=st1", "state": "st1", "auth_methods": ["web_code"]]
    }

    /// 跨线程可变的换号开关：ApiClient 下一次读状态时把会话从 A 换成 B（signOut + 保存 B），只换一次。
    private final class Swap: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var swaps = 0
        weak var client: ApiClient?
        let tokens: MemorySessionTokens

        init(tokens: MemorySessionTokens) {
            self.tokens = tokens
        }

        func arm() {
            lock.withLock { armed = true }
        }

        var count: Int {
            lock.withLock { swaps }
        }

        func fireIfArmed() {
            let fire = lock.withLock { () -> Bool in
                guard armed else { return false }
                armed = false
                swaps += 1
                return true
            }
            guard fire else { return }
            client?.signOut()
            try? tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
        }
    }

    private struct Rig {
        let client: ApiClient
        let tokens: MemorySessionTokens
        let swap: Swap
        let controller: OpenPurchaseController
        let card: TradeObject
    }

    private func makeRig(timeoutMillis: Int64 = 8000) -> Rig {
        let tokens = MemorySessionTokens(access: "at-a", refresh: "rt-a", scope: "full", account: "user-a")
        let swap = Swap(tokens: tokens)
        let client = ApiClient(
            identity: ClientIdentity(platform: "ios", appVersion: "9.9.9", build: "1", channel: "appstore"),
            context: {
                swap.fireIfArmed()
                return NetworkContext(
                    privacy: PrivacyRaw.full, environmentSettled: true, credentialsReadable: true,
                    update: UpdateRaw.supported, apiBaseURL: URL(string: "https://api.test.invalid")
                )
            },
            device: Device(),
            tokens: tokens,
            pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
            configuration: TradeStubProtocol.configuration()
        )
        swap.client = client
        let ports = FakePorts()
        let env = FakeEnv(card: TradeFixtures.card())
        let executor = TradeJumpExecutor(ports: ports, baichuan: UnavailableBaichuan(), sink: FakeSink())
        let controller = OpenPurchaseController(
            api: client, executor: executor, ports: ports, env: env, pending: MemoryPurchasePending(),
            counter: AuthSheetCounter(), tips: JumpTipService(api: client) { "user-a" }, webCode: FakeWebCode(),
            baichuan: UnavailableBaichuan(), timeoutMillis: timeoutMillis, browserNoticeMillis: 50
        )
        controller.jumpOrigin = { "origin" }
        controller.jumpSource = {
            JumpSource(origin: "origin", request: client.currentOwnership(credentialsReadable: true))
        }
        return Rig(client: client, tokens: tokens, swap: swap, controller: controller, card: env.card)
    }

    // MARK: - open 超时重试

    /// 超时【重试】的来源检查通过之后、网络首次绑定之前换成 B：重发带首发时固定的 A 的归属，网络层比较拦下，零发送。
    /// 对照：不换号时同键带 A 的凭据重发。
    func testTimeoutRetrySwapAfterCheckBeforeBindSendsNothing() async throws {
        for swap in [false, true] {
            let first = Locked(true)
            TradeStubProtocol.install { request in
                guard request.path.hasSuffix("/open") else { return .init() }
                let delay: TimeInterval = first.get() ? 3 : 0
                first.set(false)
                return .init(data: Self.json(TradeFixtures.open()), delay: delay)
            }
            let rig = makeRig(timeoutMillis: 150)
            rig.controller.buy(rig.card, spm: nil)
            await eventually { rig.controller.state.phase == .timeout }
            XCTAssertEqual(TradeStubProtocol.requests("/open").count, 1, "前提：首发已发出")
            if swap {
                rig.swap.arm()
            }
            rig.controller.retryAfterTimeout()
            try await Task.sleep(nanoseconds: 400_000_000)
            let opens = TradeStubProtocol.requests("/open")
            if swap {
                XCTAssertEqual(rig.swap.count, 1, "换号确实发生在网络层读状态时")
                XCTAssertEqual(opens.count, 1, "超时重试：检查之后换号，零发送")
            } else {
                XCTAssertEqual(opens.count, 2)
                XCTAssertEqual(opens[1].headers["Authorization"], "Bearer at-a")
                XCTAssertEqual(opens[0].headers["Idempotency-Key"], opens[1].headers["Idempotency-Key"])
            }
        }
    }

    // MARK: - 授权

    /// 30101 → AuthSheet【去授权】→ web_code 拿到凭证 → alive 检查通过 → 绑定排队后换成 B：bindings 零发送。对照：照常带 A 发出。
    func testTaobaoBindQueuedThenSwapSendsNoBind() async throws {
        for swap in [false, true] {
            TradeStubProtocol.install { request in
                if request.path.hasSuffix("/taobao/bindings") {
                    return .init(data: Self.json(["platform": "taobao", "status": "invalid"]))
                }
                guard request.path.hasSuffix("/open") else { return .init() }
                return .init(code: 30101, data: Self.json(Self.authData))
            }
            let rig = makeRig()
            rig.controller.buy(rig.card, spm: nil)
            await eventually { rig.controller.state.dialog == .authSheet(platform: "taobao", busy: false) }
            if swap {
                rig.swap.arm()
            }
            rig.controller.authorize()
            try await Task.sleep(nanoseconds: 400_000_000)
            let binds = TradeStubProtocol.requests("/taobao/bindings")
            if swap {
                XCTAssertEqual(rig.swap.count, 1)
                XCTAssertTrue(binds.isEmpty, "绑定排队后换号：零发送")
                XCTAssertEqual(TradeStubProtocol.requests("/open").count, 1, "也不自动 open")
            } else {
                XCTAssertEqual(binds.count, 1)
                XCTAssertEqual(binds.first?.headers["Authorization"], "Bearer at-a")
            }
        }
    }

    /// 授权查询：绑定请求失败（5xxxx）给「查不到」→【重试】重新查询，排队后换成 B：listUnionBindings 零发送。对照：照常带 A 发出。
    func testAuthQueryAfterSwapSendsNothing() async throws {
        for swap in [false, true] {
            TradeStubProtocol.install { request in
                if request.path.hasSuffix("/taobao/bindings") {
                    return .init(code: 50001)
                }
                if request.path.hasSuffix("/unions/bindings") {
                    return .init(data: Self.json(["items": [[String: String]]()]))
                }
                guard request.path.hasSuffix("/open") else { return .init() }
                return .init(code: 30101, data: Self.json(Self.authData))
            }
            let rig = makeRig()
            rig.controller.buy(rig.card, spm: nil)
            await eventually { rig.controller.state.dialog == .authSheet(platform: "taobao", busy: false) }
            rig.controller.authorize()
            await eventually {
                if case .authCheckFailed = rig.controller.state.dialog {
                    return true
                }
                return false
            }
            if swap {
                rig.swap.arm()
            }
            rig.controller.recheckAuth()
            try await Task.sleep(nanoseconds: 400_000_000)
            let queries = TradeStubProtocol.requests("/unions/bindings")
            if swap {
                XCTAssertEqual(rig.swap.count, 1)
                XCTAssertTrue(queries.isEmpty, "授权查询排队后换号：零发送")
            } else {
                XCTAssertEqual(queries.count, 1)
                XCTAssertEqual(queries.first?.headers["Authorization"], "Bearer at-a")
            }
        }
    }

    /// 30104 恢复：绑定返回 30104 之后换成 B，重新取授权地址（auth-url）零发送。对照：照常带 A 发出。
    func testAuthRecoveryAfterSwapSendsNoAuthUrl() async throws {
        for swap in [false, true] {
            let rigBox = Locked<Swap?>(nil)
            let armOnBind = swap
            TradeStubProtocol.install { request in
                if request.path.hasSuffix("/taobao/bindings") {
                    // 绑定已发出并拿到 30104：此后（恢复的 auth-url 读状态时）换号
                    if armOnBind {
                        rigBox.get()?.arm()
                    }
                    return .init(code: 30104, data: Self.json(["reason": "credential_invalid"]))
                }
                if request.path.hasSuffix("/auth-url") {
                    return .init(data: Self.json(Self.authData))
                }
                guard request.path.hasSuffix("/open") else { return .init() }
                return .init(code: 30101, data: Self.json([
                    "auth_url": "https://oauth.test/a?state=st1", "state": "st1", "auth_methods": ["web_code"],
                ]))
            }
            let rig = makeRig()
            rigBox.set(rig.swap)
            rig.controller.buy(rig.card, spm: nil)
            await eventually { rig.controller.state.dialog == .authSheet(platform: "taobao", busy: false) }
            rig.controller.authorize()
            try await Task.sleep(nanoseconds: 500_000_000)
            let urls = TradeStubProtocol.requests("/auth-url")
            XCTAssertEqual(TradeStubProtocol.requests("/taobao/bindings").count, 1, "前提：首次绑定已发出（凭证失效后没有可换的方式）")
            if swap {
                XCTAssertEqual(rig.swap.count, 1)
                XCTAssertTrue(urls.isEmpty, "恢复后换号：零 auth-url 发送")
            } else {
                XCTAssertFalse(urls.isEmpty)
                XCTAssertEqual(urls.first?.headers["Authorization"], "Bearer at-a")
            }
        }
    }
}
