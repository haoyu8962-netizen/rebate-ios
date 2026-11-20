import ClientCore
import CouliNetwork
import Foundation
@testable import MeCore
import WalletCore
import XCTest

/// APP-13a-2-ios 写测 r4（首轮评审 S2-3、S2-4）：在 MeCore 层直接驱动换号执行器（替身端口），把两条在 App 组合里会被「同步出口先作废子页」
/// 掩盖的分支单独钉住：
/// - S2-4：确认 / 放弃得到**强更** 10405（Effect = forceUpdate）时，结局分支本身「只消费网络层 Effect、记录保留、不当作已放弃」——这里没有
///   强更分流去作废子页，子页仍存活，断言测到的是结局分支而不是 `leave()`（共性第 12 条）；
/// - S2-3 / M8：身份已不是当前（`isCurrent` 为 false）但会话同步出口还没执行（`observeSession` 没触发）时，渲染时取出的旧回调全部 0 次调用。
/// 钱包侧依赖复用 App13a1 的替身（App13a1FakeApi / App13a1ControllerEnv，不改它们）。
@MainActor
final class App13a2PhoneChangeBranchTests: XCTestCase {
    private var fixture: App13a2BranchFixture?

    override func tearDown() async throws {
        fixture?.controller.leave()
        fixture = nil
        try await super.tearDown()
    }

    private func make(pending: Bool) -> App13a2BranchFixture {
        let made = App13a2BranchFixture(pending: pending)
        fixture = made
        return made
    }

    private func waitFor(_ message: String, timeout: TimeInterval = 5, file: StaticString = #filePath,
                         line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail(message, file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func forced10405() -> ApiResult {
        .failure(
            code: 10405, msg: "", data: Data("{\"min_supported_version\":\"99.0.0\"}".utf8), traceId: "trace-forced01",
            effect: ErrorEffect(code: 10405, kind: .forceUpdate), idempotencyKey: nil
        )
    }

    private func enterPending(_ fixture: App13a2BranchFixture) async {
        fixture.controller.start()
        await waitFor("没有按本机记录进待确认") { fixture.controller.state.step == .pending }
    }

    /// S2-4：放弃得到强更 10405 → 子页仍存活、仍是这张待确认卡（原键）、不回第 1 步、不进 Done、不回第 2 步；只发过 1 次放弃。
    func testAbandonForced10405BranchKeepsPendingWhileAlive() async throws {
        let fixture = make(pending: true)
        await enterPending(fixture)
        let controller = fixture.controller
        fixture.port.abandonResult = Self.forced10405()
        controller.askAbandon(version: controller.state.version)
        let dialog = try XCTUnwrap(controller.state.dialog, "没有二次确认")
        controller.confirmAbandon(dialog, version: controller.state.version)
        XCTAssertEqual(fixture.port.calls, ["abandon"], "前提：放弃发出 1 次")
        XCTAssertTrue(controller.alive, "前提：没有强更分流，子页仍存活（测到的是结局分支本身）")
        XCTAssertEqual(controller.state.step, .pending, "强更不当作已放弃（共性第 12 条）")
        XCTAssertEqual(controller.state.pending?.key, App13a2BranchFixture.key, "仍是原键的待确认卡")
        XCTAssertFalse(controller.state.pendingBusy, "在途标记收回")
        XCTAssertNil(controller.state.dialog)
        XCTAssertNil(controller.state.doneMaskedPhone, "不进 Done")
        XCTAssertEqual(fixture.walletApi.calls.count, 0, "不另发请求")
    }

    /// S2-4 同口径：确认得到强更 10405 → 子页存活、待确认卡保留、不弹面板、不回第 2 步。
    func testConfirmForced10405BranchKeepsPendingWhileAlive() async {
        let fixture = make(pending: true)
        await enterPending(fixture)
        let controller = fixture.controller
        fixture.port.confirmResult = Self.forced10405()
        controller.confirmPending(version: controller.state.version)
        XCTAssertEqual(fixture.port.calls, ["confirm"], "前提：确认发出 1 次")
        XCTAssertTrue(controller.alive)
        XCTAssertEqual(controller.state.step, .pending)
        XCTAssertEqual(controller.state.pending?.key, App13a2BranchFixture.key)
        XCTAssertFalse(controller.state.pendingBusy)
        XCTAssertNil(controller.stepUp?.state, "不弹面板")
    }

    /// S2-3 / M8：身份已变（替身端口 isCurrent = false）、会话同步出口没执行 → 第 1 步与待确认的旧回调都 0 次调用、0 次请求。
    func testStaleCallbacksBeforeSyncExitCallNothing() async throws {
        let fixture = make(pending: true)
        await enterPending(fixture)
        let controller = fixture.controller
        controller.askAbandon(version: controller.state.version)
        let dialog = try XCTUnwrap(controller.state.dialog)
        let version = controller.state.version
        fixture.port.current = false
        XCTAssertEqual(controller.state.step, .pending, "前提：同步出口没执行，页面还在")
        XCTAssertFalse(controller.alive, "固定身份已不是当前")
        controller.confirmPending(version: version)
        controller.confirmAbandon(dialog, version: version)
        controller.askAbandon(version: version)
        controller.requestOldCode(version: version)
        controller.oldCode("123456", version: version)
        controller.next(version: version)
        controller.newPhone("13900001234", version: version)
        controller.newCode("654321", version: version)
        controller.requestNewCode(version: version)
        controller.submit(version: version)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fixture.port.calls, [], "旧回调 0 次端口调用（M8）")
        XCTAssertEqual(fixture.walletApi.calls.count, 0, "0 次请求")
    }
}

// MARK: - 替身

/// 绑手机端口替身：固定身份 user-a / full；`current = false` 模拟身份已变但同步出口未执行；写请求同步回调配置好的结果。
@MainActor
final class App13a2BranchBindPort: PhoneBindPort {
    let owner = PhoneBindOwner(request: RequestOwnership(account: "user-a", generation: 1, epoch: 0), scope: "full")
    let writeGate = RetryAfterGate()
    var current = true
    var lookup: PendingLookup = .none
    var confirmResult: ApiResult = .success(data: Data("{}".utf8), traceId: nil, idempotencyKey: nil)
    var abandonResult: ApiResult = .abandoned(idempotencyKey: App13a2BranchFixture.key)
    private(set) var calls: [String] = []

    func identity() -> PhoneBindOwner {
        owner
    }

    func isCurrent(_ owner: PhoneBindOwner) -> Bool {
        current && owner == self.owner
    }

    func writeGated(_: PhoneBindOwner) -> Bool {
        false
    }

    func tokenEpoch() -> UInt64 {
        0
    }

    func scopeStill(_: PhoneBindOwner) -> @Sendable () -> Bool {
        { true }
    }

    func observeSession(_: @escaping @MainActor () -> Void) -> () -> Void {
        {}
    }

    func subscribe(_: @escaping @MainActor (PhoneBindSettled) -> Void) -> () -> Void {
        {}
    }

    func pendingStatus(_: PhoneBindOwner) async -> PendingLookup {
        lookup
    }

    func smsRemainingSec(_: PhoneBindOwner, phone _: String) -> Int {
        0
    }

    func smsSending(_: PhoneBindOwner, phone _: String) -> Bool {
        false
    }

    func sendCode(_: PhoneBindOwner, phone _: String, completion _: @escaping @MainActor (PhoneBindSms) -> Void) {
        calls.append("sendCode")
    }

    func submitChange(
        _: PhoneBindOwner, _: PhoneChangeSubmission, stepUpToken _: String?,
        completion _: @escaping @MainActor (PhoneBindArrival) -> Void
    ) {
        calls.append("submit")
    }

    func confirmChange(
        _: PhoneBindOwner, key _: String, stepUpToken _: String?,
        completion: @escaping @MainActor (PhoneBindArrival) -> Void
    ) {
        calls.append("confirm")
        completion(PhoneBindArrival(result: confirmResult, kind: .other, gated: false, notified: false))
    }

    func abandonChange(
        _: PhoneBindOwner, key _: String, completion: @escaping @MainActor (PhoneBindArrival) -> Void
    ) {
        calls.append("abandon")
        completion(PhoneBindArrival(result: abandonResult, kind: .other, gated: false, notified: false))
    }
}

@MainActor
final class App13a2BranchPorts: PhoneChangePorts {
    let deps: WalletDeps
    let env: App13a1ControllerEnv
    let port: App13a2BranchBindPort

    init(deps: WalletDeps, env: App13a1ControllerEnv, port: App13a2BranchBindPort) {
        self.deps = deps
        self.env = env
        self.port = port
    }

    func stepUpDeps() -> WalletDeps {
        deps
    }

    func walletOwner() -> WalletOwner {
        env.owner
    }

    var bind: PhoneBindPort {
        port
    }
}

/// MeApi 替身：换号执行器不经它发请求（发码 / 验证走 WalletDeps.api，写请求走端口）；被调到就记一笔。
final class App13a2BranchMeApi: MeApi, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int {
        lock.withLock { count }
    }

    func send(
        _: ApiCall, isValid _: @escaping @Sendable () -> Bool, sendAllowed _: @escaping @Sendable () -> Bool,
        expected _: RequestOwnership?
    ) async -> ApiResult {
        lock.withLock { count += 1 }
        return .localReject(reason: "test")
    }
}

@MainActor
final class App13a2BranchFixture {
    static let key = "pc-branch-key-0001"

    let walletApi = App13a1FakeApi()
    let walletEnv = App13a1ControllerEnv()
    let meEnv: App13a2BranchMeEnv
    let port = App13a2BranchBindPort()
    let ports: App13a2BranchPorts
    let meDeps: MeDeps
    let controller: PhoneChangeController

    init(pending: Bool) {
        walletEnv.bound = true
        let identity = MeIdentity(
            level: MeLevel.member, account: "user-a",
            request: RequestOwnership(account: "user-a", generation: 1, epoch: 0), key: "member|user-a|1|0|0"
        )
        meEnv = App13a2BranchMeEnv(identity: identity)
        let deps = WalletDeps(
            api: walletApi, env: walletEnv, gates: WalletGates(), cache: nil, mask: AmountMaskStore(), realname: nil,
            labor: nil
        )
        ports = App13a2BranchPorts(deps: deps, env: walletEnv, port: port)
        meDeps = MeDeps(
            api: App13a2BranchMeApi(), env: meEnv, gates: MeGates(), local: nil, mask: nil, nickname: nil, notify: nil
        )
        if pending {
            port.lookup = .record(PendingKeyRecord(
                key: Self.key, operationId: "bindPhone", body: "{\"code\":\"654321\",\"phone\":\"13900001234\"}",
                account: "user-a", summary: "{\"phone\":\"139****1234\"}", stateRaw: PendingKeyStore.unknown,
                everUnknown: true, createdAtMillis: 1_763_600_000_000
            ))
        }
        controller = PhoneChangeController(deps: meDeps, identity: identity, ports: ports, host: nil, page: nil)
    }
}
