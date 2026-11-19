import ClientCore
import CouliNetwork
import Foundation
import Generated
@testable import MeCore
import WalletCore
import XCTest

/// APP-13a-1-ios 写测（独立写测方）：注销页执行器用例的公共底座（夹具在本文件后半）。
/// 子类：App13a1DeleteAccountControllerTests（进页、申请、身份、离页）、App13a1DeleteAccountCancelTests（撤回注销）。
@MainActor
class App13a1ControllerTestCase: XCTestCase {
    var fixtures: [App13a1ControllerFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures {
            fixture.closePanel()
            fixture.controller.leave()
        }
        fixtures = []
        try await super.tearDown()
    }

    func make(scope: String = DeletionScope.full, source: DeletionSource = .settings,
              phoneBound: Bool? = true) -> App13a1ControllerFixture {
        let fixture = App13a1ControllerFixture(scope: scope, source: source, phoneBound: phoneBound)
        fixtures.append(fixture)
        return fixture
    }

    /// 进页并等进度与资金都读到。
    func open(_ fixture: App13a1ControllerFixture) async {
        fixture.controller.start()
        await waitFor("进度与资金没有读到") {
            let state = fixture.controller.state
            return (state.read != nil || state.readFailed) && (state.funds != nil || state.fundsFailed)
        }
        await fixture.idle()
    }

    func check(_ fixture: App13a1ControllerFixture) {
        let controller = fixture.controller
        controller.toggleWaiver(version: controller.state.version, owner: controller.identity.owner)
    }

    func apply(_ fixture: App13a1ControllerFixture) {
        let controller = fixture.controller
        controller.apply(version: controller.state.version, owner: controller.identity.owner)
    }

    func cancel(_ fixture: App13a1ControllerFixture) {
        let controller = fixture.controller
        controller.cancelDeletion(version: controller.state.version, owner: controller.identity.owner)
    }

    // MARK: - 工具

    func waitFor(_ message: String, timeout: TimeInterval = 5, file: StaticString = #filePath,
                 line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail(message, file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// 观察窗：「不该发生」的断言等满再判。
    func quiet(_ seconds: TimeInterval = 0.5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - 夹具

/// 回答样例（契约 Deletion / 钱包摘要形状；金额是测试值）。
enum App13a1Replies {
    static func cooling(_ canCancel: Bool) -> String {
        "{\"status\":\"cooling\",\"apply_at\":\"2026-10-02T09:30:00+08:00\","
            + "\"cooling_until\":\"2026-10-09T09:30:00+08:00\","
            + "\"can_cancel\":\(canCancel),\"cancelled_at\":null,\"cancel_reason\":null,\"processed_at\":null}"
    }

    static let cancelled = "{\"status\":\"cancelled\",\"apply_at\":\"2026-10-02T09:30:00+08:00\","
        + "\"cooling_until\":\"2026-10-09T09:30:00+08:00\",\"can_cancel\":false,"
        + "\"cancelled_at\":\"2026-10-03T10:00:00+08:00\",\"cancel_reason\":\"user\",\"processed_at\":null}"

    static func summary(negative: Int64) -> String {
        "{\"available_fen\":1000,\"withdrawable_fen\":1000,\"negative_fen\":\(negative),\"frozen_fen\":0,"
            + "\"estimated_total_fen\":1019,\"estimated_fen\":269,\"pending_credit_fen\":750,"
            + "\"pending_credit_paused_fen\":0,\"next_credit_period\":\"2026-11\",\"credit_overdue\":false,"
            + "\"withdrawn_fen\":0,\"risk_paused_reason\":null,\"withdraw_enabled\":true}"
    }

    static let stepUpToken = "controller-step-up-token"

    static func ok(_ json: String) -> ApiResult {
        .success(data: Data(json.utf8), traceId: "trace-0123456789ab", idempotencyKey: nil)
    }

    static func fail(_ code: Int, data: String? = nil, disable: Int64? = nil) -> ApiResult {
        let kind: ErrorEffectKind = code == 10003 ? .stepUp : .genericError
        return .failure(
            code: code, msg: "", data: data.map { Data($0.utf8) }, traceId: "trace-0123456789ab",
            effect: ErrorEffect(code: code, kind: kind, disableMillis: disable), idempotencyKey: nil
        )
    }

    static let transport = ApiResult.transportFailure(
        kind: "timeout", httpStatus: nil, idempotencyKey: nil, pendingKeyUnknown: false
    )
}

/// 假 WalletApi：按 operationId 排队回答（用完重复最后一个），可挂起某个 operation 直到 `release`。记下每个调用。
final class App13a1FakeApi: WalletApi, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ApiCall] = []
    private var replies: [String: [ApiResult]] = [:]
    private var holding: Set<String> = []
    private var waiting: [String: [CheckedContinuation<ApiResult, Never>]] = [:]

    var calls: [ApiCall] {
        lock.withLock { recorded }
    }

    func calls(_ operationId: String) -> [ApiCall] {
        calls.filter { $0.operationId == operationId }
    }

    func on(_ operationId: String, _ results: ApiResult...) {
        lock.withLock { replies[operationId] = results }
    }

    func hold(_ operationId: String) {
        lock.withLock { _ = holding.insert(operationId) }
    }

    func heldCount(_ operationId: String) -> Int {
        lock.withLock { waiting[operationId]?.count ?? 0 }
    }

    func release(_ operationId: String, _ result: ApiResult) {
        let continuations: [CheckedContinuation<ApiResult, Never>] = lock.withLock {
            holding.remove(operationId)
            return waiting.removeValue(forKey: operationId) ?? []
        }
        continuations.forEach { $0.resume(returning: result) }
    }

    private func reply(_ operationId: String) -> ApiResult {
        if var queue = replies[operationId], !queue.isEmpty {
            let first = queue.removeFirst()
            replies[operationId] = queue.isEmpty ? [first] : queue
            return first
        }
        switch operationId {
        case "getDeletion": return App13a1Replies.ok("null")
        case "getWalletSummary": return App13a1Replies.ok(App13a1Replies.summary(negative: 0))
        case "getMe": return App13a1Replies.ok("{\"user_id\":\"user-a\",\"phone_bound\":true}")
        case "sendSmsCode": return App13a1Replies.ok("{\"resend_after_sec\":60,\"expires_in_sec\":300}")
        case "stepUp":
            return App13a1Replies.ok(
                "{\"step_up_token\":\"\(App13a1Replies.stepUpToken)\",\"expire_at\":\"2099-01-01T00:05:00+08:00\"}"
            )
        case "requestDeletion": return App13a1Replies.ok(App13a1Replies.cooling(true))
        case "cancelDeletion": return App13a1Replies.ok(App13a1Replies.cancelled)
        default: return App13a1Replies.ok("{}")
        }
    }

    func send(
        _ call: ApiCall, isValid _: @escaping @Sendable () -> Bool, sendAllowed _: @escaping @Sendable () -> Bool,
        expected _: RequestOwnership?
    ) async -> ApiResult {
        let (held, result): (Bool, ApiResult?) = lock.withLock {
            recorded.append(call)
            if holding.contains(call.operationId) {
                return (true, nil)
            }
            return (false, reply(call.operationId))
        }
        if held {
            return await withCheckedContinuation { continuation in
                lock.withLock { waiting[call.operationId, default: []].append(continuation) }
            }
        }
        return result ?? App13a1Replies.ok("{}")
    }

    func confirmPending(operationId: String, stepUpToken: String?, target: PendingTarget) async -> ApiResult {
        lock.withLock {
            recorded.append(ApiCall(operationId: operationId, idempotencyKey: target.key, stepUpToken: stepUpToken))
            return reply(operationId)
        }
    }

    func abandonPending(operationId _: String, target _: PendingTarget) async -> ApiResult {
        lock.withLock {
            recorded.append(ApiCall(operationId: "abandonIdempotencyKey"))
            return .abandoned(idempotencyKey: "abandoned")
        }
    }

    func pendingStatus(operationId _: String) async -> PendingLookup {
        .none
    }

    func restorePending() async {}
}

/// 可控身份的钱包环境：`current = false` 模拟会话已换代。
@MainActor
final class App13a1ControllerEnv: WalletEnv {
    let owner = WalletOwner(
        account: "user-a", key: "user-a#1#0#0", request: RequestOwnership(account: "user-a", generation: 1, epoch: 0),
        loginEpoch: "login-a"
    )
    var current = true
    var bound: Bool?
    var now: Int64 = 1_790_904_600_000

    func currentOwner() -> WalletOwner {
        owner
    }

    func isCurrent(_ owner: WalletOwner) -> Bool {
        current && owner == self.owner
    }

    func configText(_: String) -> String? {
        nil
    }

    func helpLinks() -> [String: Any]? {
        nil
    }

    func earningsFlag() -> Bool? {
        nil
    }

    var appVersion: String {
        "1.2.0"
    }

    var earningsSince: String? {
        nil
    }

    func open(_: String, params _: [String: String], from _: UUID?) {}

    func replace(page _: UUID, route _: String, params _: [String: String]) -> Bool {
        false
    }

    func close(page _: UUID) -> Bool {
        false
    }

    func payoutSaved(page _: UUID) -> Bool {
        false
    }

    func copy(_: String) -> Bool {
        false
    }

    func contactService(from _: String) {}

    func stepUpPhone(account _: String) -> String? {
        "13800005678"
    }

    func stepUpPhoneBound(_: WalletOwner) -> Bool? {
        bound
    }

    func markWalletDirty(_: WalletOwner) {}

    func realnameChanged() {}

    func sensitiveOverlay(_: Bool) {}

    func nowMillis() -> Int64 {
        now
    }

    func displayNowMillis() -> Int64 {
        now
    }
}

/// App 出口替身：记下导航、客服、去向与强更标签通知；`scope` 是此刻的会话作用域。
@MainActor
final class App13a1FakePorts: DeleteAccountPorts {
    var scope: String
    var opened: [String] = []
    var contacted = 0
    var meReadGate: RetryAfterGate?
    var toForceUpdate = 0
    var toSettings = 0
    var settingsResult = true
    var changed = 0

    init(scope: String) {
        self.scope = scope
    }

    func sessionScope() -> String {
        scope
    }

    func open(_ route: String, from _: UUID) {
        opened.append(route)
    }

    func contactService() {
        contacted += 1
    }

    func returnToForceUpdate(page _: UUID) {
        toForceUpdate += 1
    }

    func returnToSettings(page _: UUID) -> Bool {
        toSettings += 1
        return settingsResult
    }

    func deletionChanged(_: WalletOwner) {
        changed += 1
    }
}

@MainActor
final class App13a1ControllerFixture {
    let api = App13a1FakeApi()
    let env = App13a1ControllerEnv()
    let ports: App13a1FakePorts
    let deps: WalletDeps
    let controller: DeleteAccountController

    init(scope: String, source: DeletionSource, phoneBound: Bool?) {
        env.bound = phoneBound
        ports = App13a1FakePorts(scope: scope)
        deps = WalletDeps(
            api: api, env: env, gates: WalletGates(), cache: nil, mask: AmountMaskStore(), realname: nil, labor: nil
        )
        controller = DeleteAccountController(
            deps: deps, identity: DeletionIdentity(owner: env.owner, scope: scope, source: source), page: UUID(),
            ports: ports
        )
        controller.setVisible(true)
    }

    func json(_ call: ApiCall) -> [String: Any] {
        guard let body = call.body, let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else {
            return [:]
        }
        return object as? [String: Any] ?? [:]
    }

    func idle() async {
        for _ in 0..<8 {
            await controller.flow.stepUp.whenIdle()
            await controller.flow.whenIdle()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func passStepUp(file: StaticString = #filePath, line: UInt = #line) async throws {
        let stepUp = controller.flow.stepUp
        let deadline = Date().addingTimeInterval(5)
        while stepUp.state?.phase != .ready {
            if Date() > deadline {
                XCTFail("二次验证面板没有就绪", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let state = try XCTUnwrap(stepUp.state, file: file, line: line)
        XCTAssertEqual(state.action, "account_deletion", "面板 action = account_deletion", file: file, line: line)
        stepUp.onCodeChange("123456", instance: state.instance)
        stepUp.verify(instance: state.instance)
    }

    func closePanel() {
        if let state = controller.flow.stepUp.state {
            controller.flow.stepUp.close(instance: state.instance)
        }
    }
}
