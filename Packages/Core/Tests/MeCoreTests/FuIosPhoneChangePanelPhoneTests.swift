import ClientCore
import CouliNetwork
import Foundation
@testable import MeCore
import WalletCore
import XCTest

/// FU-IOS-PHONECHANGE-STEPUP-TITLE 写测（MeCore 层；任务书 brief.md §1-2、§2、§4 第 5 项；D10-2281）：换号 10003 面板说明行要的脱敏新号
/// `PhoneChangeState.panelMaskedPhone`（brief §2 约定的接口名）在 `openPanel` 时按 intent 固定——`.submit(submission)` 取
/// `submission.maskedPhone`，`.confirm(key)` 取打开那一刻 `state.pending?.maskedPhone`；之后改输入框、待确认卡刷新都不变（共性第 17 条）；
/// 面板收起（用户关闭 / 拿到 token 后落定 / 离页）后为 nil。
/// 写法照 `App13a2PhoneChangeBranchTests`：在 MeCore 层直接驱动换号执行器（替身端口），钱包侧依赖复用 App13a1 的替身（App13a1FakeApi /
/// App13a1ControllerEnv）、「我的」环境复用 App13a2BranchMeEnv，都不改它们。
/// 读 `panelMaskedPhone` 走反射（`Mirror`），属性还不存在时运行期判红而不是整个测试目标编译不过；实现后可换成直接访问。
@MainActor
final class FuIosPhoneChangePanelPhoneTests: XCTestCase {
    private var fixture: FuPanelPhoneFixture?

    /// 收尾（r1 修崩）：面板打开即发码，同步用例结束时发码还在途；`leave()` 收起面板后已发出的发码照常结算共享倒计时，结算会读
    /// `WalletDeps.env`（unowned，指向夹具持有的 App13a1ControllerEnv）。先离页、排空面板在途的请求与任务，再释放夹具。
    override func tearDown() async throws {
        if let fixture {
            let stepUp = fixture.controller.stepUp // 离页前取：leave() 之后可能已不再持有面板
            fixture.controller.leave()
            await stepUp?.whenIdle()
            for _ in 0..<5 {
                await Task.yield()
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        fixture = nil
        try await super.tearDown()
    }

    private func make(pendingSummary: String? = nil) -> FuPanelPhoneFixture {
        let made = FuPanelPhoneFixture(pendingSummary: pendingSummary)
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

    /// `state.panelMaskedPhone` 的值：属性不存在 → 判失败并返回 `.none`；存在 → `.some(值)`（值可为 nil）。
    private func panelPhone(_ controller: PhoneChangeController, file: StaticString = #filePath,
                            line: UInt = #line) -> String?? {
        guard let child = Mirror(reflecting: controller.state).children.first(where: { $0.label == "panelMaskedPhone" })
        else {
            XCTFail("PhoneChangeState 没有 panelMaskedPhone（brief §2）", file: file, line: line)
            return .none
        }
        return .some(child.value as? String)
    }

    /// 进第 2 步（直接置步骤，第 1 步另有用例）、填新号与验证码、点【提交】→ 端口回 10003 → 面板打开。
    private func submitTo10003(_ fixture: FuPanelPhoneFixture, phone: String) {
        let controller = fixture.controller
        controller.state.step = .step2
        controller.state.version += 1
        controller.newPhone(phone, version: controller.state.version)
        controller.newCode("654321", version: controller.state.version)
        fixture.port.submitResults = [App13a1Replies.fail(10003), App13a1Replies.ok("{}")]
        controller.submit(version: controller.state.version)
        XCTAssertEqual(fixture.port.calls, ["submit"], "前提：【提交】发出 1 次")
        XCTAssertEqual(controller.stepUp?.state?.action, "phone_change", "前提：10003 面板打开")
    }

    /// 按本机未决记录进待确认 →【确认上一次提交】→ 端口回 10003 → 面板打开。
    private func confirmTo10003(_ fixture: FuPanelPhoneFixture) async {
        let controller = fixture.controller
        controller.start()
        await waitFor("没有按本机记录进待确认") { controller.state.step == .pending }
        fixture.port.confirmResults = [App13a1Replies.fail(10003)]
        controller.confirmPending(version: controller.state.version)
        XCTAssertEqual(fixture.port.calls, ["confirm"], "前提：确认发出 1 次")
        XCTAssertEqual(controller.stepUp?.state?.action, "phone_change", "前提：10003 面板打开")
    }

    /// 提交得 10003 → panelMaskedPhone = submission.maskedPhone（本机脱敏的提交号）；面板打开后再改新号输入框，仍是提交时那个号。
    func testSubmitIntentPinsSubmittedMaskedPhone() {
        let fixture = make()
        let controller = fixture.controller
        submitTo10003(fixture, phone: "13900001234")
        XCTAssertEqual(panelPhone(controller), .some(MePhone.masked("13900001234")), "取提交时的脱敏新号")
        controller.newPhone("13600002468", version: controller.state.version)
        XCTAssertEqual(controller.state.newPhone, "13600002468", "前提：输入框确实改了")
        XCTAssertEqual(panelPhone(controller), .some(MePhone.masked("13900001234")), "改输入框不变（共性第 17 条）")
    }

    /// 提交的号码规整不了（submission.maskedPhone 为 nil）→ 面板照开，panelMaskedPhone 为 nil（App 侧据此不显示说明行）。
    func testSubmitIntentWithoutMaskedPhoneIsNil() {
        let fixture = make()
        let controller = fixture.controller
        submitTo10003(fixture, phone: "12345")
        XCTAssertEqual(panelPhone(controller), .some(nil), "没有脱敏号 → nil，不填输入原文")
    }

    /// 待确认卡确认得 10003 → panelMaskedPhone = 打开那一刻 state.pending?.maskedPhone；之后卡片刷新（换了号码）也不变。
    func testConfirmIntentPinsPendingCardPhone() async throws {
        let fixture = make(pendingSummary: "{\"phone\":\"137****5678\"}")
        let controller = fixture.controller
        await confirmTo10003(fixture)
        XCTAssertEqual(controller.state.pending?.maskedPhone, "137****5678", "前提：卡片号码取记录摘要")
        XCTAssertEqual(panelPhone(controller), .some("137****5678"), "取待确认卡的脱敏号")
        let card = try XCTUnwrap(controller.state.pending)
        controller.state.pending = PhoneChangePendingCard(
            key: card.key, maskedPhone: "135****0000", submittedAtMillis: card.submittedAtMillis
        )
        XCTAssertEqual(panelPhone(controller), .some("137****5678"), "卡片刷新后不变（打开时固定）")
    }

    /// 待确认卡没有号码（记录摘要里没有 phone）→ 确认得 10003 → panelMaskedPhone 为 nil。
    func testConfirmIntentWithoutPhoneIsNil() async {
        let fixture = make(pendingSummary: "{}")
        let controller = fixture.controller
        await confirmTo10003(fixture)
        XCTAssertNil(controller.state.pending?.maskedPhone, "前提：卡片没有号码")
        XCTAssertEqual(panelPhone(controller), .some(nil), "没有号码 → nil")
    }

    /// 用户点【×】收起面板（onClosed）→ panelMaskedPhone 清空。
    func testUserClosePanelClearsPhone() {
        let fixture = make()
        let controller = fixture.controller
        submitTo10003(fixture, phone: "13900001234")
        XCTAssertEqual(panelPhone(controller), .some(MePhone.masked("13900001234")), "前提：打开时有号")
        let stepUp = controller.stepUp
        if let state = stepUp?.state {
            stepUp?.close(instance: state.instance)
        }
        XCTAssertNil(controller.stepUp?.state, "前提：面板已收起")
        XCTAssertEqual(panelPhone(controller), .some(nil), "面板收起后清空")
    }

    /// 面板验证拿到 token → 原键原体重放成功 → Done（面板 detach）→ panelMaskedPhone 清空。
    func testVerifiedReplayDoneClearsPhone() async throws {
        let fixture = make()
        let controller = fixture.controller
        submitTo10003(fixture, phone: "13900001234")
        let stepUp = try XCTUnwrap(controller.stepUp)
        await waitFor("面板没有就绪") { stepUp.state?.phase == .ready }
        let state = try XCTUnwrap(stepUp.state)
        stepUp.onCodeChange("112233", instance: state.instance)
        stepUp.verify(instance: state.instance)
        await waitFor("验证后没有进 Done") { controller.state.step == .done }
        XCTAssertEqual(fixture.port.calls, ["submit", "submit"], "前提：重放 1 次")
        XCTAssertNil(stepUp.state, "前提：面板已收起")
        XCTAssertEqual(panelPhone(controller), .some(nil), "面板收起、落定后清空")
    }

    /// 面板打开时离页（leave：detach + 状态重置）→ panelMaskedPhone 清空。
    func testLeaveClearsPhone() {
        let fixture = make()
        let controller = fixture.controller
        submitTo10003(fixture, phone: "13900001234")
        XCTAssertEqual(panelPhone(controller), .some(MePhone.masked("13900001234")), "前提：打开时有号")
        controller.leave()
        XCTAssertEqual(panelPhone(controller), .some(nil), "离页后清空")
    }
}

// MARK: - 替身

/// 绑手机端口替身（照 App13a2BranchBindPort，另加提交的结果队列）：固定身份 user-a / full；写请求按队列同步回调。
@MainActor
final class FuPanelPhoneBindPort: PhoneBindPort {
    let owner = PhoneBindOwner(request: RequestOwnership(account: "user-a", generation: 1, epoch: 0), scope: "full")
    let writeGate = RetryAfterGate()
    var lookup: PendingLookup = .none
    var submitResults: [ApiResult] = []
    var confirmResults: [ApiResult] = []
    private(set) var calls: [String] = []

    private static func next(_ queue: inout [ApiResult]) -> ApiResult {
        guard !queue.isEmpty else { return .success(data: Data("{}".utf8), traceId: nil, idempotencyKey: nil) }
        return queue.count == 1 ? queue[0] : queue.removeFirst()
    }

    func identity() -> PhoneBindOwner {
        owner
    }

    func isCurrent(_ owner: PhoneBindOwner) -> Bool {
        owner == self.owner
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
        completion: @escaping @MainActor (PhoneBindArrival) -> Void
    ) {
        calls.append("submit")
        let result = Self.next(&submitResults)
        completion(PhoneBindArrival(result: result, kind: .other, gated: false, notified: false))
    }

    func confirmChange(
        _: PhoneBindOwner, key _: String, stepUpToken _: String?,
        completion: @escaping @MainActor (PhoneBindArrival) -> Void
    ) {
        calls.append("confirm")
        let result = Self.next(&confirmResults)
        completion(PhoneBindArrival(result: result, kind: .other, gated: false, notified: false))
    }

    func abandonChange(
        _: PhoneBindOwner, key _: String, completion: @escaping @MainActor (PhoneBindArrival) -> Void
    ) {
        calls.append("abandon")
        completion(PhoneBindArrival(
            result: .abandoned(idempotencyKey: FuPanelPhoneFixture.key), kind: .other, gated: false, notified: false
        ))
    }
}

@MainActor
final class FuPanelPhonePorts: PhoneChangePorts {
    let deps: WalletDeps
    let env: App13a1ControllerEnv
    let port: FuPanelPhoneBindPort

    init(deps: WalletDeps, env: App13a1ControllerEnv, port: FuPanelPhoneBindPort) {
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

/// 换号执行器 + 替身端口（照 App13a2BranchFixture）。`pendingSummary` 非 nil 时预置一条结果未知的 bindPhone 记录，摘要原样写入。
@MainActor
final class FuPanelPhoneFixture {
    static let key = "pc-fu-panel-key-0001"

    let walletApi = App13a1FakeApi()
    let walletEnv = App13a1ControllerEnv()
    let meEnv: App13a2BranchMeEnv
    let port = FuPanelPhoneBindPort()
    let ports: FuPanelPhonePorts
    let meDeps: MeDeps
    let controller: PhoneChangeController

    init(pendingSummary: String?) {
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
        ports = FuPanelPhonePorts(deps: deps, env: walletEnv, port: port)
        meDeps = MeDeps(
            api: App13a2BranchMeApi(), env: meEnv, gates: MeGates(), local: nil, mask: nil, nickname: nil, notify: nil
        )
        if let pendingSummary {
            port.lookup = .record(PendingKeyRecord(
                key: Self.key, operationId: "bindPhone", body: "{\"code\":\"654321\",\"phone\":\"13700005678\"}",
                account: "user-a", summary: pendingSummary, stateRaw: PendingKeyStore.unknown,
                everUnknown: true, createdAtMillis: 1_763_600_000_000
            ))
        }
        controller = PhoneChangeController(deps: meDeps, identity: identity, ports: ports, host: nil, page: nil)
    }
}
