import Foundation
@testable import Network
import Session
import XCTest

/// LOCK-ios 段 2（编排 D10-1709，修订 D10-1700，三端同）：x-auth=optional 的接口把「拿不到账号」分成两种——
/// **确认游客**（本机没有会话）匿名照发；**身份未知**（存着会话但这一刻读不出，`tokens.failReads = .readFailed`）缺省本地拒，
/// 原因 session_unreadable、零发送；只有调用点显式声明 `ApiCall.sendsWhenIdentityUnknown`（只给 sendSmsCode purpose=login / bind、
/// getConfig、ingestEvents；D10-1710 补 createOauthAttempt 仅 purpose=login）的才匿名发（不带 Authorization）。
/// 有令牌照常带。声明不放宽固定账号核对（D10-1703 / D10-1704）。
/// 桩写法同 LockIosOptionalAuthTests / LockIosPinnedAccountTests：makeHarness（account-A / access-1 的 full 会话）+ URLProtocol
/// 本地假服务。
final class LockIosIdentityUnknownTests: XCTestCase {
    static let smsPath = "/v1/auth/sms-codes"
    static let loginCode = "{\"phone\":\"13800138000\",\"purpose\":\"login\"}"
    static let bindCode = "{\"phone\":\"13800138000\",\"purpose\":\"bind\"}"

    /// 一条被测请求：调用与它应打到的路径。
    struct Probe: Sendable {
        let call: ApiCall
        let path: String
        var label: String {
            call.operationId
        }
    }

    /// 未声明、调用点要改带固定归属的两条（D10-1709 ①④）。
    static let pinnedCallers = [
        Probe(
            call: ApiCall(operationId: "parseInput", body: "{\"scene\":\"clipboard\",\"text\":\"x\"}"),
            path: "/v1/inputs/parse"
        ),
        Probe(
            call: ApiCall(operationId: "openLink", pathParams: ["link_id": "abc"], body: "{\"no_rebate\":false}"),
            path: "/v1/links/abc/open"
        ),
    ]

    /// 未声明的其余 optional 读接口（含 agent 接口，D10-1709 ③）。
    static let undeclaredReads = [
        Probe(call: ApiCall(operationId: "getLink", pathParams: ["link_id": "abc"]), path: "/v1/links/abc"),
        Probe(call: ApiCall(operationId: "searchProducts", query: "q=a"), path: "/v1/products/search"),
        Probe(
            call: ApiCall(operationId: "getProduct", pathParams: ["product_key": "tb-1"]), path: "/v1/products/tb-1"
        ),
        Probe(call: ApiCall(operationId: "getCurrentAgentSession"), path: "/v1/agent/sessions/current"),
    ]

    /// 声明「身份未知也可发」的四条（D10-1709 ③ 名单）。
    static let declared = [
        Probe(
            call: ApiCall(operationId: "sendSmsCode", body: loginCode, sendsWhenIdentityUnknown: true), path: smsPath
        ),
        Probe(
            call: ApiCall(operationId: "sendSmsCode", body: bindCode, sendsWhenIdentityUnknown: true), path: smsPath
        ),
        Probe(call: ApiCall(operationId: "getConfig", sendsWhenIdentityUnknown: true), path: "/v1/config"),
        Probe(
            call: ApiCall(operationId: "ingestEvents", body: "{\"events\":[]}", sendsWhenIdentityUnknown: true),
            path: "/v1/events"
        ),
    ]

    private func send(_ harness: Harness, _ call: ApiCall, _ expected: RequestOwnership?) async -> ApiResult {
        guard let expected else {
            return await harness.client.send(call)
        }
        return await harness.client.send(call, isValid: { true }, sendAllowed: { true }, expected: expected)
    }

    /// 本机存着 account-A 的会话；`pin` 时先在可读时取固定归属（账号 A），再置读不出。
    private func identityUnknown(pin: Bool) -> (Harness, RequestOwnership?) {
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok() }
        let pinned = pin ? harness.client.currentOwnership(credentialsReadable: true) : nil
        if pin {
            XCTAssertEqual(pinned?.account, "account-A")
        }
        harness.tokens.failReads = .readFailed
        return (harness, pinned)
    }

    // MARK: - 0. 声明接口

    /// 0. D10-1709 约定：`ApiCall.sendsWhenIdentityUnknown` 缺省 false，init 参数与 requiresSession 并列；只有显式传 true 才是 true。
    func testSendsWhenIdentityUnknownDefaultsToFalse() {
        XCTAssertFalse(ApiCall(operationId: "parseInput").sendsWhenIdentityUnknown)
        XCTAssertFalse(ApiCall(operationId: "sendSmsCode", requiresSession: true).sendsWhenIdentityUnknown)
        let declared = ApiCall(operationId: "getConfig", requiresSession: false, sendsWhenIdentityUnknown: true)
        XCTAssertTrue(declared.sendsWhenIdentityUnknown)
        XCTAssertNotEqual(declared, ApiCall(operationId: "getConfig"), "参与 Equatable")
    }

    // MARK: - 1. 身份未知 × parseInput / openLink（未声明）

    /// 1. D10-1709 ③：身份未知 × parseInput、openLink（未声明）→ session_unreadable、零发送；不固定与固定账号 A 两种都一样
    /// （固定了账号时 prepare 先按 session_unreadable 拒，不被改报 account_mismatch）。
    func testIdentityUnknownRejectsParseInputAndOpenLink() async {
        for probe in Self.pinnedCallers {
            for pin in [false, true] {
                let (harness, pinned) = identityUnknown(pin: pin)
                let label = "\(probe.label) \(pin ? "固定 A" : "不固定")"
                let result = await send(harness, probe.call, pinned)
                XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionUnreadable, "\(label)：\(result)")
                XCTAssertTrue(StubURLProtocol.requests.isEmpty, "\(label)：零发送（不退成匿名发出）")
                XCTAssertEqual(harness.client.refreshCalls, 0, "\(label)：不为此起刷新")
            }
        }
    }

    // MARK: - 2. 身份未知 × 声明的四条

    /// 2. D10-1709 ③：身份未知 × sendSmsCode login / bind、getConfig、ingestEvents（声明 sendsWhenIdentityUnknown）→ 照发、
    /// 不带 Authorization（拿不到可信令牌），签名接口照常带 X-Device-Id，请求体原样。
    func testIdentityUnknownSendsDeclaredCallsAnonymously() async {
        for probe in Self.declared {
            let (harness, _) = identityUnknown(pin: false)
            let label = "\(probe.label) \(probe.call.body ?? "")"
            let result = await send(harness, probe.call, nil)
            XCTAssertTrue(result.isSuccess, "\(label)：\(result)")
            XCTAssertEqual(StubURLProtocol.requests.map(\.path), [probe.path], label)
            let sent = StubURLProtocol.requests.first
            XCTAssertNil(sent?.header("Authorization"), "\(label)：读不出的会话不得当成有令牌")
            XCTAssertEqual(sent?.header("X-Device-Id"), "device-fixture", label)
            if let body = probe.call.body {
                XCTAssertEqual(sent?.body, body, label)
            }
        }
    }

    /// 2'. D10-1709 ③：同样的四条不声明（同一 operationId、同一请求体，`sendsWhenIdentityUnknown` 缺省 false）→ session_unreadable、
    /// 零发送——放行只来自调用点的声明，不按 operationId / purpose 自动放行。
    func testIdentityUnknownRejectsSameOperationsWithoutDeclaration() async {
        for probe in Self.declared {
            var call = probe.call
            call.sendsWhenIdentityUnknown = false
            let (harness, _) = identityUnknown(pin: false)
            let result = await send(harness, call, nil)
            XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionUnreadable, "\(probe.label)：\(result)")
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, probe.label)
        }
    }

    // MARK: - 2''. 身份未知 × createOauthAttempt（按 purpose 区分）

    static let oauthPath = "/v1/auth/oauth-attempts"

    /// 2''a. D10-1710（补 D10-1709 ③ 名单）：身份未知 × createOauthAttempt 请求体 purpose=login（调用点声明
    /// sendsWhenIdentityUnknown: true，同 OAuthLoginService.createAttempt）→ 照发、不带 Authorization、请求体原样。
    /// 请求体按快照 CreateOauthAttemptRequest（provider + purpose，login 分支不带 action）。
    func testIdentityUnknownSendsOauthLoginAttemptAnonymously() async {
        let body = "{\"provider\":\"wechat\",\"purpose\":\"login\"}"
        let call = ApiCall(operationId: "createOauthAttempt", body: body, sendsWhenIdentityUnknown: true)
        let (harness, _) = identityUnknown(pin: false)
        let result = await send(harness, call, nil)
        XCTAssertTrue(result.isSuccess, "\(result)")
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Self.oauthPath])
        let sent = StubURLProtocol.requests.first
        XCTAssertNil(sent?.header("Authorization"), "读不出的会话不得当成有令牌")
        XCTAssertEqual(sent?.body, body)
        XCTAssertEqual(harness.client.refreshCalls, 0, "不为此起刷新")
    }

    /// 2''b. D10-1710：名单只含 createOauthAttempt purpose=login；身份未知 × createOauthAttempt purpose=step_up（未声明）→
    /// session_unreadable、零发送。请求体按快照 step_up 分支（provider + purpose + action）。
    func testIdentityUnknownRejectsOauthStepUpAttempt() async {
        let body = "{\"provider\":\"wechat\",\"purpose\":\"step_up\",\"action\":\"withdraw\"}"
        let call = ApiCall(operationId: "createOauthAttempt", body: body)
        let (harness, _) = identityUnknown(pin: false)
        let result = await send(harness, call, nil)
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionUnreadable, "\(result)")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "零发送（不退成匿名发出）")
        XCTAssertEqual(harness.client.refreshCalls, 0, "不为此起刷新")
    }

    // MARK: - 3. 身份未知 × getLink / searchProducts / getProduct / agent（未声明）

    /// 3. D10-1709 ③：身份未知 × getLink、searchProducts、getProduct、agent 接口（未声明）→ session_unreadable、零发送。
    func testIdentityUnknownRejectsUndeclaredReads() async {
        for probe in Self.undeclaredReads {
            let (harness, _) = identityUnknown(pin: false)
            let result = await send(harness, probe.call, nil)
            XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionUnreadable, "\(probe.label)：\(result)")
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, "\(probe.label)：零发送")
        }
    }

    // MARK: - 4. 确认游客 × parseInput / openLink

    /// 4. D10-1709 ②：确认游客（本机没有会话）× parseInput、openLink（未声明）→ 匿名照发、不带 Authorization；不固定与
    /// 固定归属取自游客态（account == nil）两种都发。
    func testConfirmedGuestSendsParseInputAndOpenLinkAnonymously() async {
        for probe in Self.pinnedCallers {
            for pin in [false, true] {
                let harness = makeHarness(tokens: MemorySessionTokens())
                StubURLProtocol.install { _ in ok() }
                let expected = pin ? harness.client.currentOwnership(credentialsReadable: true) : nil
                XCTAssertNil(expected?.account)
                let label = "\(probe.label) \(pin ? "游客态固定" : "不固定")"
                let result = await send(harness, probe.call, expected)
                XCTAssertTrue(result.isSuccess, "\(label)：\(result)")
                XCTAssertEqual(StubURLProtocol.requests.map(\.path), [probe.path], label)
                XCTAssertNil(StubURLProtocol.requests.first?.header("Authorization"), label)
            }
        }
    }

    // MARK: - 5. 会话恢复

    /// 5. D10-1709 ①：身份未知时被拒（或声明的匿名发出）之后撤掉 failReads（会话恢复可读、世代不变），同一请求带
    /// Authorization: Bearer access-1 发出。未声明的 parseInput / openLink / getLink 与声明的 sendSmsCode login 各跑一次。
    func testRecoveredSessionSendsSameRequestWithBearer() async {
        let probes = Self.pinnedCallers + [Self.undeclaredReads[0], Self.declared[0]]
        for probe in probes {
            let (harness, _) = identityUnknown(pin: false)
            let generation = harness.client.currentOwnership(credentialsReadable: true).generation
            let first = await send(harness, probe.call, nil)
            if probe.call.sendsWhenIdentityUnknown {
                XCTAssertTrue(first.isSuccess, "\(probe.label)：\(first)")
                XCTAssertNil(StubURLProtocol.requests.first?.header("Authorization"), probe.label)
            } else {
                XCTAssertEqual(first.rejectReason, LocalRejectReason.sessionUnreadable, "\(probe.label)：\(first)")
                XCTAssertTrue(StubURLProtocol.requests.isEmpty, probe.label)
            }
            let before = StubURLProtocol.requests.count
            harness.tokens.failReads = nil
            XCTAssertEqual(
                harness.client.currentOwnership(credentialsReadable: true).generation, generation, "恢复可读不换代"
            )
            let second = await send(harness, probe.call, nil)
            XCTAssertTrue(second.isSuccess, "\(probe.label)：\(second)")
            XCTAssertEqual(StubURLProtocol.requests.count, before + 1, probe.label)
            XCTAssertEqual(StubURLProtocol.requests.last?.path, probe.path, probe.label)
            XCTAssertEqual(StubURLProtocol.requests.last?.header("Authorization"), "Bearer access-1", probe.label)
        }
    }

    /// 5'. D10-1709 ①：恢复后固定账号 A 的 parseInput / openLink（D10-1709 ④ 调用点带固定归属）带 A 的令牌照常发出。
    func testRecoveredSessionSendsPinnedCallersWithBearer() async {
        for probe in Self.pinnedCallers {
            let (harness, pinned) = identityUnknown(pin: true)
            let denied = await send(harness, probe.call, pinned)
            XCTAssertEqual(denied.rejectReason, LocalRejectReason.sessionUnreadable, "\(probe.label)：\(denied)")
            harness.tokens.failReads = nil
            let result = await send(harness, probe.call, pinned)
            XCTAssertTrue(result.isSuccess, "\(probe.label)：\(result)")
            XCTAssertEqual(StubURLProtocol.requests.map(\.path), [probe.path], probe.label)
            XCTAssertEqual(StubURLProtocol.requests.first?.header("Authorization"), "Bearer access-1", probe.label)
        }
    }

    // MARK: - 6. 声明不放宽固定账号

    /// 6a. D10-1709 / D10-1703 / D10-1704：声明了 sendsWhenIdentityUnknown，但调用方固定了账号 A，会话读不出 → 仍按固定账号核对
    /// account_mismatch、零发送（声明只放行「没固定账号」的身份未知）。四条声明调用逐个跑。
    func testDeclaredCallWithPinnedAccountAndUnknownIdentityIsAccountMismatch() async {
        for probe in Self.declared {
            let (harness, pinned) = identityUnknown(pin: true)
            let result = await send(harness, probe.call, pinned)
            XCTAssertEqual(result.rejectReason, LocalRejectReason.accountMismatch, "\(probe.label)：\(result)")
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, "\(probe.label)：零发送")
        }
    }

    /// 6b. D10-1709 / D10-1704：声明调用 × 固定 A × 同一会话世代里存储换成账号 B（可读）→ account_mismatch、零发送。
    func testDeclaredCallWithPinnedAccountAndOtherAccountIsAccountMismatch() async throws {
        for probe in Self.declared {
            let harness = makeHarness()
            StubURLProtocol.install { _ in ok() }
            let pinned = harness.client.currentOwnership(credentialsReadable: true)
            try harness.tokens.save(access: "access-b", refresh: "refresh-b", scope: "full", account: "account-B")
            XCTAssertEqual(harness.client.currentOwnership(credentialsReadable: true).generation, pinned.generation)
            let result = await send(harness, probe.call, pinned)
            XCTAssertEqual(result.rejectReason, LocalRejectReason.accountMismatch, "\(probe.label)：\(result)")
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, probe.label)
        }
    }

    /// 6c. D10-1709：声明调用 × 固定 A × 会话可读、账号 A → 照常带 Bearer access-1 发出（声明不影响有令牌时的行为）。
    func testDeclaredCallWithPinnedMatchingAccountSendsWithBearer() async {
        for probe in Self.declared {
            let harness = makeHarness()
            StubURLProtocol.install { _ in ok() }
            let pinned = harness.client.currentOwnership(credentialsReadable: true)
            let result = await send(harness, probe.call, pinned)
            XCTAssertTrue(result.isSuccess, "\(probe.label)：\(result)")
            XCTAssertEqual(StubURLProtocol.requests.map(\.path), [probe.path], probe.label)
            XCTAssertEqual(StubURLProtocol.requests.first?.header("Authorization"), "Bearer access-1", probe.label)
        }
    }

    // MARK: - 7. recordConsent（按请求体 type / accepted 区分）

    static let consentPath = "/v1/consents"
    /// 请求体按快照 RecordConsentRequest（type / version / accepted / channel / client_at）。
    static let privacyWithdraw = consent(type: "privacy", accepted: false, channel: "privacy_center")
    static let aiWithdraw = consent(type: "ai_third_party", accepted: false, channel: "privacy_center")
    static let aiAccept = consent(type: "ai_third_party", accepted: true, channel: "agent_sheet")

    static func consent(type: String, accepted: Bool, channel: String) -> String {
        "{\"accepted\":\(accepted),\"channel\":\"\(channel)\",\"client_at\":\"2026-11-15T09:30:00+08:00\","
            + "\"type\":\"\(type)\",\"version\":3}"
    }

    /// 7a. D10-1711：身份未知 × recordConsent {type: privacy, accepted: false}（隐私中心撤回隐私同意，调用点声明
    /// sendsWhenIdentityUnknown: true，同 AppMe.withdrawConsent）→ 照发、不带 Authorization、请求体原样；设备级照常带
    /// X-Device-Id（快照 recordConsent x-signed=false，不带 X-Sign / X-Timestamp / X-Nonce）；不为此起刷新。
    func testIdentityUnknownSendsDeclaredPrivacyWithdrawConsent() async {
        let call = ApiCall(operationId: "recordConsent", body: Self.privacyWithdraw, sendsWhenIdentityUnknown: true)
        let (harness, _) = identityUnknown(pin: false)
        let result = await send(harness, call, nil)
        XCTAssertTrue(result.isSuccess, "\(result)")
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Self.consentPath])
        let sent = StubURLProtocol.requests.first
        XCTAssertNil(sent?.header("Authorization"), "读不出的会话不得当成有令牌")
        XCTAssertEqual(sent?.header("X-Device-Id"), "device-fixture", "设备级")
        XCTAssertNil(sent?.header("X-Sign"), "快照 x-signed=false")
        XCTAssertEqual(sent?.body, Self.privacyWithdraw)
        XCTAssertEqual(harness.client.refreshCalls, 0, "不为此起刷新")
    }

    /// 7b. D10-1711：身份未知 × recordConsent {type: ai_third_party（快照 RecordConsentRequest.type 枚举的 AI 第三方项）,
    /// accepted: false}（未声明）→ session_unreadable、零发送——撤回 AI 同意不在名单里，也不因 accepted=false 自动放行。
    func testIdentityUnknownRejectsUndeclaredAiConsentWithdraw() async {
        let call = ApiCall(operationId: "recordConsent", body: Self.aiWithdraw)
        let (harness, _) = identityUnknown(pin: false)
        let result = await send(harness, call, nil)
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionUnreadable, "\(result)")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "零发送（不退成匿名发出）")
        XCTAssertEqual(harness.client.refreshCalls, 0, "不为此起刷新")
    }

    /// 7b'. D10-1711：同一隐私撤回请求体不声明 → session_unreadable、零发送（放行只来自调用点声明，不按请求体自动放行）。
    func testIdentityUnknownRejectsPrivacyWithdrawWithoutDeclaration() async {
        let call = ApiCall(operationId: "recordConsent", body: Self.privacyWithdraw)
        let (harness, _) = identityUnknown(pin: false)
        let result = await send(harness, call, nil)
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionUnreadable, "\(result)")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "零发送")
    }

    /// 7c. D10-1711 / D10-1709 ②：确认游客（本机没有会话）× recordConsent {type: ai_third_party, accepted: true}（未声明）→
    /// 匿名照发（设备级）、不带 Authorization、带 X-Device-Id、请求体原样。
    func testConfirmedGuestSendsUndeclaredAiConsentAnonymously() async {
        let call = ApiCall(operationId: "recordConsent", body: Self.aiAccept)
        let harness = makeHarness(tokens: MemorySessionTokens())
        StubURLProtocol.install { _ in ok() }
        let result = await send(harness, call, nil)
        XCTAssertTrue(result.isSuccess, "\(result)")
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Self.consentPath])
        let sent = StubURLProtocol.requests.first
        XCTAssertNil(sent?.header("Authorization"))
        XCTAssertEqual(sent?.header("X-Device-Id"), "device-fixture", "设备级")
        XCTAssertEqual(sent?.body, Self.aiAccept)
    }
}

/// 8 / 9：段 2 评审 S2-1（读得出会话却没有可用 access 也是身份未知）、段 2 第 3 次评审 S2-2
/// （置了 requiresSession 的 optional 必须带本人令牌）；D10-1709 本线口径，都不固定账号。
extension LockIosIdentityUnknownTests {
    private func refreshOnly() throws -> Harness { // 只有 refresh 的会话（内存实现把缺的 access 存成空串）
        let tokens = MemorySessionTokens(access: nil, refresh: "refresh-1", scope: "full", account: "account-A")
        let harness = makeHarness(tokens: tokens)
        XCTAssertTrue(try XCTUnwrap(harness.tokens.readSession()).access.isEmpty, "前提：access 为空或 nil")
        return harness
    }

    /// 8. S2-1：只有 refresh 的会话 × 未声明的 getLink、getPage → session_unreadable、零发送、不起刷新；
    /// × 声明了的 getConfig、sendSmsCode{purpose:login} → 匿名发、不带 Authorization。
    func testSessionWithoutAccessRejectsUndeclaredAndSendsDeclaredAnonymously() async throws {
        let page = Probe(call: ApiCall(operationId: "getPage", pathParams: ["page_key": "p"]), path: "/v1/pages/p")
        for probe in [Self.undeclaredReads[0], page, Self.declared[2], Self.declared[0]] {
            let (harness, label, declared) = try (refreshOnly(), probe.label, probe.call.sendsWhenIdentityUnknown)
            StubURLProtocol.install { _ in ok() }
            let (result, sent) = await (send(harness, probe.call, nil), StubURLProtocol.requests)
            XCTAssertEqual(result.isSuccess, declared, "\(label)：\(result)")
            XCTAssertEqual(result.rejectReason, declared ? nil : LocalRejectReason.sessionUnreadable, label)
            XCTAssertEqual(sent.map(\.path), declared ? [probe.path] : [], "\(label)：未声明的零发送")
            XCTAssertNil(sent.first?.header("Authorization"), "\(label)：没有可用 access")
            XCTAssertEqual(harness.client.refreshCalls, 0, "\(label)：不为此起刷新")
        }
    }

    /// 9. S2-2：requiresSession 的 step_up 发码（account_deletion）× a 只有 refresh、b 确认游客（没有会话）
    /// → session_unreadable、零发送（不比缺省调用更松）；× c full 会话有 access → 带 Bearer access-1 发出。
    func testRequiresSessionStepUpCodeNeedsAccessToken() async throws {
        let body = "{\"purpose\":\"step_up\",\"action\":\"account_deletion\"}"
        let call = ApiCall(operationId: "sendSmsCode", body: body, requiresSession: true)
        let guest = makeHarness(tokens: MemorySessionTokens()) // 确认游客：本机没有会话
        let cases = try [("a", refreshOnly(), nil), ("b", guest, nil), ("c", makeHarness(), "Bearer access-1")]
        for (label, harness, bearer) in cases {
            StubURLProtocol.install { _ in ok() }
            let (result, sent) = await (send(harness, call, nil), StubURLProtocol.requests)
            XCTAssertEqual(result.isSuccess, bearer != nil, "\(label)：\(result)")
            XCTAssertEqual(result.rejectReason, bearer == nil ? LocalRejectReason.sessionUnreadable : nil, label)
            XCTAssertEqual(sent.map(\.path), bearer == nil ? [] : [Self.smsPath], "\(label)：无令牌零发送")
            XCTAssertEqual(sent.first?.header("Authorization"), bearer, label)
        }
    }
}
