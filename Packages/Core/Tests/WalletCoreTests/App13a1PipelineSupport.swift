import CouliNetwork
import Foundation
import OrderCore
import Session
@testable import WalletCore
import XCTest

/// APP-13a-1-ios 写测：App13a1DeletionPipelineTests 的环境、发起页记录、键序列与组合夹具（r3 由测试文件拆出）。
/// 可控身份的钱包环境：`current = false` 模拟会话已换代（旧固定身份不再是当前会话）。
@MainActor
final class App13a1PipelineEnv: WalletEnv {
    let owner: WalletOwner
    var current = true
    var now: Int64 = 1_790_904_600_000

    init(owner: WalletOwner) {
        self.owner = owner
    }

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
        true
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

/// 记下发起页收到的结局。
@MainActor
final class App13a1RecordingHost: FlowHost {
    var succeeded = 0
    var settled = 0
    var guides: [String] = []
    var outcomes: [String] = []

    func onSucceeded(_: Any?, alreadyDone _: Bool) {
        succeeded += 1
    }

    func onSettled() {
        settled += 1
    }

    func onGuide(_ route: String) {
        guides.append(route)
    }

    func onBusinessError(_: Int) {}

    func onOutcome(_ outcome: Outcome, result _: ApiResult, phase _: String) {
        outcomes.append(outcome.actionRaw)
    }
}

/// 生成的键按次序编号（deletion-key-1、-2…），并记下生成了几次。
final class App13a1Keys: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var issued: Int {
        lock.withLock { count }
    }

    func next() -> String {
        lock.withLock {
            count += 1
            return "deletion-key-\(count)"
        }
    }
}

final class App13a1Life: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true

    var alive: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// 一个注销流程的组合：真实 ApiClient（内存会话 user-a、内存未决后端、本地假服务）+ 真实 WalletDeps + 真实 SensitiveFlow.accountDeletion。
@MainActor
final class App13a1PipelineFixture {
    nonisolated static let account = "user-a"
    nonisolated static let deletionPath = "/v1/me/deletion"
    nonisolated static let installSecret = "test-only.install.device-a"
    nonisolated static let stepUpToken = "pipeline-step-up-token"
    nonisolated static let cooling = """
    {"status":"cooling","apply_at":"2026-10-02T09:30:00+08:00","cooling_until":"2026-10-09T09:30:00+08:00",\
    "can_cancel":true,"cancelled_at":null,"cancel_reason":null,"processed_at":null}
    """

    private struct Device: DeviceCredentials {
        var deviceId: String? = "device-fixture"
        var installSecret: String? = App13a1PipelineFixture.installSecret
    }

    let script: App13a1Script
    let backend: MemoryPendingKeyBackend
    let sessionTokens: MemorySessionTokens
    let client: ApiClient
    let owner: WalletOwner
    let env: App13a1PipelineEnv
    let deps: WalletDeps
    let keys: App13a1Keys
    let life: App13a1Life
    let host: App13a1RecordingHost
    let flow: SensitiveFlow

    init() {
        let script = App13a1Script()
        let backend = MemoryPendingKeyBackend()
        let sessionTokens = MemorySessionTokens(
            access: "at", refresh: "rt", scope: "full", account: App13a1PipelineFixture.account
        )
        let keys = App13a1Keys()
        let life = App13a1Life()
        let host = App13a1RecordingHost()
        self.script = script
        self.backend = backend
        self.sessionTokens = sessionTokens
        self.keys = keys
        self.life = life
        self.host = host
        let store = PendingKeyStore(backend: backend, clock: { 1_790_904_600_000 })
        let client = ApiClient(
            identity: ClientIdentity(platform: "ios", appVersion: "1.2.0", build: "120", channel: "app_store"),
            context: {
                NetworkContext(
                    privacy: PrivacyRaw.full, environmentSettled: true, credentialsReadable: true,
                    update: UpdateRaw.supported, apiBaseURL: URL(string: "https://api.test.couli.invalid")
                )
            },
            device: Device(), tokens: sessionTokens, pendingKeys: store,
            configuration: App13a1Stub.configuration(), sleeper: { _ in }
        )
        self.client = client
        let ownership = client.currentOwnership(credentialsReadable: true)
        let owner = WalletOwner(
            account: Self.account, key: "\(Self.account)#\(ownership.generation)#\(ownership.epoch)", request: ownership
        )
        self.owner = owner
        let env = App13a1PipelineEnv(owner: owner)
        self.env = env
        let deps = WalletDeps(
            api: client, env: env, gates: WalletGates(), cache: nil, mask: AmountMaskStore(), realname: nil, labor: nil
        )
        deps.newKey = { keys.next() }
        self.deps = deps
        let flow = SensitiveFlow.accountDeletion(deps: deps, owner: owner, alive: { life.alive })
        flow.attach(host)
        self.flow = flow
        App13a1Stub.install { script.reply($0) }
    }

    /// 等流程与面板的在途请求、回包结算全部完成。
    func idle() async {
        for _ in 0..<6 {
            await flow.stepUp.whenIdle()
            await flow.whenIdle()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// 等面板就绪 → 填码 → 验证（面板回调取渲染时的实例）。
    func passStepUp(file: StaticString = #filePath, line: UInt = #line) async throws {
        await panelWait("二次验证面板没有就绪", file: file, line: line) { [flow] in flow.stepUp.state?.phase == .ready }
        let state = try XCTUnwrap(flow.stepUp.state, file: file, line: line)
        XCTAssertEqual(state.action, "account_deletion", "面板 action = account_deletion", file: file, line: line)
        flow.stepUp.onCodeChange("123456", instance: state.instance)
        flow.stepUp.verify(instance: state.instance)
    }

    func closePanel() {
        if let state = flow.stepUp.state {
            flow.stepUp.close(instance: state.instance)
        }
    }
}
