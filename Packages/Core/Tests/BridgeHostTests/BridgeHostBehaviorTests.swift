@testable import BridgeHost
import Foundation
import XCTest

/// BridgeHost 分派与 APP-04 三端共性的宿主侧行为（向量之外）。
@MainActor
final class BridgeHostBehaviorTests: XCTestCase {
    private let origin = "https://h5.example.test"
    private var state = BridgeCallerState(
        privacy: BridgePrivacy.consented,
        accountKey: "u1#1",
        update: BridgeUpdateState.supported
    )
    private var services = RecordingServices()
    private let ui = RecordingUI()

    private func makeHost(awaitUpdate: @escaping @MainActor () async -> String = { BridgeUpdateState.supported })
        -> BridgeHost {
        BridgeHost(
            protocol: { [origin] in BridgeProtocol(trustedOrigins: [origin], linkPatterns: [:], shareDomains: []) },
            caller: { [unowned self] in state },
            services: services,
            ui: ui,
            awaitUpdate: awaitUpdate
        )
    }

    private func call(
        _ host: BridgeHost,
        id: String,
        method: String,
        params: [String: Any] = [:],
        gesture: Bool = false,
        mainFrame: Bool = true
    ) -> Reply {
        let reply = Reply()
        let data = (try? JSONSerialization.data(
            withJSONObject: ["v": 1, "id": id, "method": method, "params": params]
        )) ?? Data()
        let raw = String(bytes: data, encoding: .utf8) ?? ""
        host.handle(raw: raw, origin: origin, isMainFrame: mainFrame, userGesture: gesture) { reply.values.append($0) }
        return reply
    }

    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    func testDeclaredMethodsFollowContractSinceIOS() {
        let host = makeHost()
        XCTAssertTrue(host.declaredMethods.contains("trade.openProduct"))
        XCTAssertTrue(host.declaredMethods.contains("clipboard.read"))
        XCTAssertFalse(host.declaredMethods.contains("media.scan"), "since.ios 为 null 的 P1 方法不声明")
    }

    func testUnimplementedMethodsRunProtocolChecksBefore90001() {
        let host = makeHost()
        // 协议层先判：缺参数 90002、缺手势 90404、trade_only 90403；都通过后才 90001（编排者三端裁定）。
        XCTAssertEqual(call(host, id: "a", method: "trade.authorize", params: ["platform": "taobao"]).code, 90404)
        XCTAssertEqual(call(host, id: "b", method: "trade.openProduct", params: [:]).code, 90002)
        XCTAssertEqual(
            call(host, id: "c", method: "ext.openApp", params: ["target": "jd", "url": "https://jd.example.test/"])
                .code,
            90403
        )
        XCTAssertEqual(
            call(host, id: "d", method: "trade.authorize", params: ["platform": "taobao"], gesture: true).code, 90001
        )
        XCTAssertEqual(call(host, id: "e", method: "media.scan").code, 90001)
    }

    func testSubframeIsRefusedWithoutRunningAnything() {
        let host = makeHost()
        XCTAssertEqual(call(host, id: "a", method: "app.getEnv", mainFrame: false).code, 90403)
        XCTAssertEqual(services.calls, [])
    }

    /// 三端共性第 19 条：重复的在途 id 直接回 90002，不执行、不覆盖原来那条。
    func testDuplicateInFlightIdIsRefusedAndDoesNotReplaceOriginal() async {
        let gate = Gate()
        services.loginGate = gate
        let host = makeHost()
        let first = call(host, id: "same", method: "auth.login")
        await settle()
        let second = call(host, id: "same", method: "auth.login")
        XCTAssertEqual(second.code, 90002)
        XCTAssertEqual(services.calls, ["login"])
        gate.open()
        await settle()
        XCTAssertEqual(first.code, 0, "原来那条照常结算")
        XCTAssertEqual(first.values.count, 1)
    }

    /// 三端共性第 19 条：在途 id 的重复检查排在协议判定之前——后到的同 id 调用即使来自子框架、缺手势，也回 90002，
    /// 原来那条照常结算一次。
    func testDuplicateIdIsCheckedBeforeProtocolDecision() async {
        let gate = Gate()
        services.loginGate = gate
        let host = makeHost()
        let first = call(host, id: "dup", method: "auth.login")
        await settle()
        XCTAssertEqual(call(host, id: "dup", method: "app.getEnv", mainFrame: false).code, 90002)
        XCTAssertEqual(call(host, id: "dup", method: "clipboard.write", params: ["text": "x"]).code, 90002)
        XCTAssertEqual(services.rejected.count, 0, "重复 id 不进协议判定，也不记被拒埋点")
        gate.open()
        await settle()
        XCTAssertEqual(first.values.count, 1)
        XCTAssertEqual(first.code, 0)
    }

    /// 三端共性第 4 条：等待期间页面换文档（invalidate）→ 在途调用回 90500，结果不交回、不补执行。
    func testInvalidateCancelsInFlightCalls() async {
        let gate = Gate()
        services.loginGate = gate
        let host = makeHost()
        let pending = call(host, id: "x", method: "auth.login")
        await settle()
        host.invalidate()
        XCTAssertEqual(pending.code, 90500)
        gate.open()
        await settle()
        XCTAssertEqual(pending.values.count, 1, "只结算一次")
    }

    /// 三端共性第 22 条：经 ApiClient 发请求的能力拿到调用有效性；页面换文档（invalidate）或调用结算后它变为无效，
    /// 之后 ApiClient 不再发出这次调用的请求。
    func testCallValidityIsRevokedOnInvalidateAndSettle() async {
        let gate = Gate()
        services.userGate = gate
        let host = makeHost()
        _ = call(host, id: "u1", method: "auth.getUser")
        await settle()
        let pending = services.validities.first
        XCTAssertEqual(pending?.isValid, true)
        host.invalidate()
        XCTAssertEqual(pending?.isValid, false, "页面换文档后在途请求不得再发出")
        gate.open()
        await settle()

        let done = call(host, id: "u2", method: "auth.getUser")
        await settle()
        XCTAssertEqual(done.code, 0)
        XCTAssertEqual(services.validities.last?.isValid, false, "结算后同样失效")
    }

    /// 三端共性第 15 条：会话换代（同一账号重新登录也算）→ 结果不交回。
    func testSessionGenerationChangeDropsResult() async {
        let gate = Gate()
        services.loginGate = gate
        let host = makeHost()
        let pending = call(host, id: "x", method: "auth.login")
        await settle()
        state = BridgeCallerState(
            privacy: BridgePrivacy.consented,
            accountKey: "u1#2",
            update: BridgeUpdateState.supported
        )
        gate.open()
        await settle()
        XCTAssertEqual(pending.code, 90500)
    }

    /// 强更检查中：等结果；之后核对归属再执行。未知时非只读方法 90500，auth.getH5Token 只申请只读（三端共性第 6 条）。
    func testUpdateGuardAndH5TokenScope() async {
        state = BridgeCallerState(
            privacy: BridgePrivacy.consented,
            accountKey: "u1#1",
            update: BridgeUpdateState.checking
        )
        let host = makeHost(awaitUpdate: { BridgeUpdateState.unknown })
        let token = call(host, id: "t", method: "auth.getH5Token")
        let login = call(host, id: "l", method: "auth.login")
        await settle()
        XCTAssertEqual(token.code, 0)
        XCTAssertEqual(services.h5ReadOnly, [true])
        XCTAssertEqual(login.code, 90500)

        state = BridgeCallerState(
            privacy: BridgePrivacy.consented,
            accountKey: "u1#1",
            update: BridgeUpdateState.supported
        )
        let standard = call(host, id: "s", method: "auth.getH5Token")
        await settle()
        XCTAssertEqual(standard.code, 0)
        XCTAssertEqual(services.h5ReadOnly, [true, false])

        state = BridgeCallerState(privacy: BridgePrivacy.consented, accountKey: "u1#1", update: BridgeUpdateState.below)
        let below = call(host, id: "b", method: "app.getEnv")
        await settle()
        XCTAssertEqual(below.code, 90500)
    }

    /// 三端共性第 14 条：调用有效性一路传进权限申请；页面换文档后再查得到「已失效」。
    func testPermissionRequestReceivesCallValidity() async {
        let host = makeHost()
        let reply = call(host, id: "p", method: "perm.request", params: ["type": "push"])
        await settle()
        XCTAssertEqual(reply.code, 0)
        let check = try? XCTUnwrap(services.lastValidity)
        XCTAssertEqual(check?(), true)
        host.invalidate()
        XCTAssertEqual(check?(), false)
    }

    func testAsyncTimeoutEndsWith90003() async {
        let gate = Gate()
        services.pushGate = gate
        let host = makeHost()
        let deadlines = ManualDeadlines() // FU-IOS-0712（F-IOS-10）：注入计时器，不再固定睡 5.3 秒
        host.deadlineTimer = deadlines.timer
        let reply = call(host, id: "slow", method: "perm.getPushStatus")
        await waitFor("截止计时已按契约时长登记") { deadlines.armed.count == 1 }
        XCTAssertEqual(deadlines.armed, [contractTimeout("perm.getPushStatus")], "按契约 timeout_ms 计时")
        deadlines.fireAll()
        await waitFor("到期后结算") { reply.code != nil }
        XCTAssertEqual(reply.code, 90003)
        gate.open()
        await settle()
        XCTAssertEqual(reply.values.count, 1)
    }

    /// 第 3 轮（三端共性第 45 条）：统一截止时间从调用开始算，强更等待也在预算内；到期回 90003，同时撤销调用有效性、
    /// 取消执行它的 Task（ApiClient 据此取消在途网络请求），之后不再执行能力。
    func testDeadlineCoversUpdateWaitAndCancelsTheCall() async throws {
        let updateGate = Gate()
        services.userGate = Gate()
        let deadlines = ManualDeadlines()
        let waiting = makeHost(awaitUpdate: {
            await updateGate.wait()
            return BridgeUpdateState.supported
        })
        waiting.deadlineTimer = deadlines.timer
        state = BridgeCallerState(
            privacy: BridgePrivacy.consented, accountKey: "u1#1", update: BridgeUpdateState.checking
        )
        let stuckInUpdate = call(waiting, id: "u", method: "auth.getUser")
        state = BridgeCallerState(
            privacy: BridgePrivacy.consented, accountKey: "u1#1", update: BridgeUpdateState.supported
        )
        let running = makeHost()
        running.deadlineTimer = deadlines.timer
        let stuckInRequest = call(running, id: "r", method: "auth.getUser")
        await settle()
        let validity = try XCTUnwrap(services.validities.first)
        XCTAssertEqual(services.validities.count, 1, "强更等待中的那次还没执行")
        // FU-IOS-0712（F-IOS-10）：截止计时在调用登记时按契约时长起算（含强更等待中的那次），到期由注入的计时器触发
        let timeout = contractTimeout("auth.getUser")
        XCTAssertEqual(deadlines.armed, [timeout, timeout], "截止时间从调用开始算，强更等待也在预算内")
        XCTAssertTrue(stuckInUpdate.code == nil && stuckInRequest.code == nil)
        deadlines.fireAll()
        await waitFor("到期后两次都结算") { stuckInUpdate.code != nil && stuckInRequest.code != nil }
        XCTAssertEqual(stuckInUpdate.code, 90003, "强更等待算在截止时间内")
        XCTAssertEqual(stuckInRequest.code, 90003)
        XCTAssertFalse(validity.isValid, "到期立即撤销有效性")
        XCTAssertTrue(services.userCancelled.value, "执行它的 Task 已取消（网络请求随之取消）")
        updateGate.open()
        services.userGate?.open()
        await settle()
        XCTAssertEqual(services.validities.count, 1, "到期后不再执行能力")
        XCTAssertEqual(stuckInUpdate.values.count, 1)
    }

    func testRejectedCallsAreReported() {
        let host = makeHost()
        _ = call(host, id: "a", method: "clipboard.write", params: ["text": "x"])
        XCTAssertEqual(services.rejected.first?.0, "clipboard.write")
        XCTAssertEqual(services.rejected.first?.1, 90404)
        _ = call(host, id: "b", method: "not.a.method")
        XCTAssertEqual(services.rejected.count, 1, "契约外的方法名不进埋点")
    }
}

@MainActor
private final class Reply {
    var values: [String?] = []

    var code: Int? {
        guard let last = values.last, let text = last,
              let body = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        else { return nil }
        return body["code"] as? Int
    }
}

@MainActor
private final class RecordingUI: BridgeUI {
    func toast(text _: String, long _: Bool) {}
    func showLoading(text _: String?) {}
    func hideLoading() {}
    func setNavBar(_: BridgeNavBar) -> Bool {
        true
    }

    func close() {}
}

@MainActor
private final class RecordingServices: BridgeServices {
    var calls: [String] = []
    var h5ReadOnly: [Bool] = []
    var rejected: [(String, Int)] = []
    var loginGate: Gate?
    var pushGate: Gate?
    var userGate: Gate?
    var validities: [BridgeCallValidity] = []
    var lastValidity: (@MainActor () -> Bool)?

    func env() -> [String: Any] {
        calls.append("env")
        return [:]
    }

    func config(keys _: [String]) -> BridgeOutcome {
        .ok()
    }

    /// auth.getUser 等待期间执行它的 Task 被取消（截止时间到）时置真。
    let userCancelled = Flag()

    func user(validity: BridgeCallValidity) async -> BridgeOutcome {
        validities.append(validity)
        let cancelled = userCancelled
        await withTaskCancellationHandler {
            await userGate?.wait()
        } onCancel: {
            cancelled.set()
        }
        return .ok()
    }

    func h5Token(readOnly: Bool, validity _: BridgeCallValidity) async -> BridgeOutcome {
        h5ReadOnly.append(readOnly)
        return .ok()
    }

    func login() async -> BridgeOutcome {
        calls.append("login")
        await loginGate?.wait()
        return .ok(["logged_in": true])
    }

    func signedRequest(
        method _: String,
        path _: String,
        bodyJson _: String?,
        validity _: BridgeCallValidity
    ) async -> BridgeOutcome {
        .ok()
    }

    func navOpen(route _: String, paramsJson _: String, readOnlyPagesOnly _: Bool) async -> BridgeOutcome {
        .ok()
    }

    func clipboardWrite(text _: String) -> BridgeOutcome {
        .ok()
    }

    func clipboardRead() async -> BridgeOutcome {
        .ok()
    }

    func setClipboardAutoDetect(enabled _: Bool) -> BridgeOutcome {
        .ok()
    }

    func pushStatus() async -> BridgeOutcome {
        await pushGate?.wait()
        return .ok(["enabled": false])
    }

    func requestPermission(type _: String, isStillValid: @escaping @MainActor () -> Bool) async -> BridgeOutcome {
        lastValidity = isStillValid
        return .ok(["granted": false])
    }

    func track(name _: String) -> BridgeOutcome {
        .ok()
    }

    func reportRejected(method: String, code: Int) {
        rejected.append((method, code))
    }
}
