import CouliNetwork
import Foundation
import OrderCore
@testable import WalletCore
import XCTest

/// LOCK-ios 段 3 面板测试的替身：只给 `StepUpController` 用到的环境（身份恒为当前、可控时钟、可控的槽位键与 phone_bound），
/// 其余 WalletEnv 入口是空实现。只在主线程使用。
@MainActor
final class StepUpPanelEnv: WalletEnv {
    var now: Int64 = 1_760_000_000_000
    /// `stepUpPhone(account:)` 的返回（发码槽位键；Release 为 nil）。
    var phone: String?
    /// `stepUpPhoneBound(_:)` 的返回（Me.phone_bound；nil = 未知）。
    var bound: Bool?
    /// 面板读绑定状态时传入的身份（应是打开面板时固定的那一份）。
    private(set) var boundQueries: [WalletOwner] = []

    let owner = WalletOwner(
        account: "user-a", key: "user-a#1#0#0",
        request: RequestOwnership(account: "user-a", generation: 1, epoch: 0), loginEpoch: "login-a"
    )

    func currentOwner() -> WalletOwner {
        owner
    }

    func isCurrent(_ owner: WalletOwner) -> Bool {
        owner == self.owner
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
        "1.0.0"
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
        phone
    }

    func stepUpPhoneBound(_ owner: WalletOwner) -> Bool? {
        boundQueries.append(owner)
        return bound
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

/// 记下交来的 ApiCall，按 operationId 给脚本回答（用完后重复最后一个；没登记的发码 / 验证给成功）。不发任何请求。
final class StepUpPanelApi: WalletApi, @unchecked Sendable {
    static let token = "panel-step-up-token"
    static let smsOk = ok("{\"resend_after_sec\":60,\"expires_in_sec\":300}")
    static let stepOk = ok("{\"step_up_token\":\"\(token)\",\"expire_at\":\"2099-01-01T00:05:00+08:00\"}")

    private let lock = NSLock()
    private var recorded: [ApiCall] = []
    private var replies: [String: [ApiResult]] = [:]

    static func ok(_ json: String) -> ApiResult {
        .success(data: Data(json.utf8), traceId: nil, idempotencyKey: nil)
    }

    var calls: [ApiCall] {
        lock.withLock { recorded }
    }

    func calls(_ operationId: String) -> [ApiCall] {
        calls.filter { $0.operationId == operationId }
    }

    func on(_ operationId: String, _ results: ApiResult...) {
        lock.withLock { replies[operationId] = results }
    }

    func send(
        _ call: ApiCall, isValid _: @escaping @Sendable () -> Bool, sendAllowed _: @escaping @Sendable () -> Bool,
        expected _: RequestOwnership?
    ) async -> ApiResult {
        lock.withLock {
            recorded.append(call)
            guard var queue = replies[call.operationId], !queue.isEmpty else {
                return call.operationId == "stepUp" ? Self.stepOk : Self.smsOk
            }
            let first = queue.removeFirst()
            replies[call.operationId] = queue.isEmpty ? [first] : queue
            return first
        }
    }

    func confirmPending(operationId _: String, stepUpToken _: String?, target _: PendingTarget) async -> ApiResult {
        .localReject(reason: LocalRejectReason.invalidCall)
    }

    func abandonPending(operationId _: String, target _: PendingTarget) async -> ApiResult {
        .localReject(reason: LocalRejectReason.invalidCall)
    }

    func pendingStatus(operationId _: String) async -> PendingLookup {
        .none
    }

    func restorePending() async {}
}

/// 一个独立的面板组合：替身环境 + 替身 API + 真实 WalletDeps（令牌缓存、发码截止时间、禁用期）+ 真实 StepUpController。
@MainActor
final class StepUpPanelFixture {
    let env = StepUpPanelEnv()
    let api = StepUpPanelApi()
    let deps: WalletDeps
    let panel: StepUpController
    private(set) var delivered: [String] = []

    init() {
        deps = WalletDeps(
            api: api, env: env, gates: WalletGates(clock: { 1_760_000_000_000 }), cache: nil,
            mask: AmountMaskStore(), realname: nil, labor: nil
        )
        panel = StepUpController(deps: deps, alive: { true })
    }

    func open(_ action: String, summary: [String: String]? = nil) {
        panel.open(action: action, owner: env.owner, summary: summary, onToken: { [weak self] token in
            self?.delivered.append(token)
        }, onClosed: {})
    }

    /// 面板发出的请求全部结束（发码任务、验证请求）。
    func idle() async {
        for _ in 0..<3 {
            await panel.whenIdle()
            await Task.yield()
        }
    }

    /// 面板落定：noPhone，或 ready 且倒计时已起 / 有错误。
    func landed(file: StaticString = #filePath, line: UInt = #line) async {
        await idle()
        await panelWait("面板没有落定", file: file, line: line) { [panel] in
            guard let state = panel.state else { return false }
            return state.phase == .noPhone || (state.phase == .ready && (state.resendLeftSec > 0 || state.error != nil))
        }
    }

    /// 填码并点【验证并提交】（面板回调取渲染时的实例），等验证结束。
    func verify(_ code: String = "123456", file: StaticString = #filePath, line: UInt = #line) async throws {
        let state = try XCTUnwrap(panel.state, "面板没有打开", file: file, line: line)
        panel.onCodeChange(code, instance: state.instance)
        panel.verify(instance: state.instance)
        await idle()
    }

    /// 关闭当前面板（停掉倒计时任务）。
    func close() {
        if let state = panel.state {
            panel.close(instance: state.instance)
        }
    }

    func body(_ call: ApiCall?, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let text = try XCTUnwrap(call?.body, "没有请求体", file: file, line: line)
        let data = try XCTUnwrap(text.data(using: .utf8), file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
    }

    var smsCalls: [ApiCall] {
        api.calls(StepUpController.sendOperation)
    }

    var verifyCalls: [ApiCall] {
        api.calls(StepUpController.verifyOperation)
    }
}

/// 等到条件成立（主线程轮询；超时判失败）。
@MainActor
func panelWait(
    _ message: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail(message, file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
