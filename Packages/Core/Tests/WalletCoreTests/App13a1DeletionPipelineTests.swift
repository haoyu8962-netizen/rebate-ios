import CouliNetwork
import Foundation
import OrderCore
import Session
@testable import WalletCore
import XCTest

/// APP-13a-1-ios 写测（独立写测方）：申请注销的执行层——真实 `SensitiveFlow.accountDeletion` + 真实 `StepUpController` + 真实 `ApiClient`
/// （签名、step-up、幂等、未决键 PendingKeyStore）+ 本地 URLProtocol 假服务（`App13a1Stub`，不连任何地址）。存储记录与请求头一起断言。
///
/// 依据：契约 requestDeletion（POST /v1/me/deletion，x-signed，x-idempotent，x-step-up account_deletion，**无请求体**）；
/// 三端任务书 §0 第 1 条（每点一次生成新键、首次发送前写未决记录；10003 后原键重放 1 次；结果未知不换键、不自动重发；5xxxx / 10007 不结束键）、
/// §0「身份固定」（旧回调只比较、零请求）、「出栈清理」（写请求离页不取消、响应不改已出栈页面）；
/// 共性第 1 条（空体签名按零字节、不抛错）、第 7 条（非终结响应禁止重新生成键；「保留原记录」的存储断言按 D10-2090 ② 移到
/// FU-IOS-PENDINGKEY-NONFINAL-KEEP，这里只断言请求头与请求体）；
/// 本单任务书 §1「二次验证」（step_up_token 只用于 account_deletion、只在内存、不落盘不进日志）。
@MainActor
final class App13a1DeletionPipelineTests: XCTestCase {
    private var fixture: App13a1PipelineFixture!

    override func setUp() async throws {
        try await super.setUp()
        App13a1Stub.reset()
        fixture = App13a1PipelineFixture()
    }

    override func tearDown() async throws {
        fixture?.closePanel()
        fixture = nil
        App13a1Stub.reset()
        try await super.tearDown()
    }

    private var posts: [App13a1Stub.Recorded] {
        App13a1Stub.requests("POST", App13a1PipelineFixture.deletionPath)
    }

    private var records: [PendingKeyRecord] {
        fixture.backend.list(account: App13a1PipelineFixture.account)
    }

    // MARK: - 空体签名

    /// 申请注销没有请求体：发出的请求体为零字节，签名按零字节的 sha256 计算；照常发出、不被当成已取消吞掉（共性第 1 条）。
    func testApplySendsEmptyBodySignedOverZeroBytes() async throws {
        fixture.script.ok("POST \(App13a1PipelineFixture.deletionPath)", App13a1PipelineFixture.cooling)

        fixture.flow.submitDeletion(owner: fixture.owner)
        await fixture.idle()

        XCTAssertEqual(posts.count, 1, "申请发出 1 次")
        let post = try XCTUnwrap(posts.first)
        XCTAssertEqual(post.body, "", "没有请求体")
        let timestamp = try XCTUnwrap(post.header(HeaderNames.timestamp), "签名请求带 X-Timestamp")
        let nonce = try XCTUnwrap(post.header(HeaderNames.nonce), "签名请求带 X-Nonce")
        let expected = RequestSigner.sign(
            installSecret: App13a1PipelineFixture.installSecret,
            signingString: RequestSigner.signingString(
                method: "POST", pathWithQuery: App13a1PipelineFixture.deletionPath, timestamp: timestamp, nonce: nonce,
                body: Data()
            )
        )
        XCTAssertEqual(post.header(HeaderNames.sign), expected, "X-Sign 按零字节请求体计算")
        XCTAssertEqual(post.header(HeaderNames.idempotencyKey), "deletion-key-1", "带本次点击生成的幂等键")
        XCTAssertEqual(fixture.host.succeeded, 1, "成功交给发起页")
        XCTAssertTrue(records.isEmpty, "业务成功：键结束、记录删除")
        XCTAssertNil(fixture.flow.state.pending)
    }

    // MARK: - 10003 原键重放

    /// 10003 → 二次验证面板（action = account_deletion 发码、验证）→ 拿到 token 后沿用原键重放 1 次 → 成功；只有 1 个键。
    func test10003ReplaysOnceWithSameKey() async throws {
        fixture.script.on(
            "POST \(App13a1PipelineFixture.deletionPath)", .envelope(10003, "null"),
            .envelope(0, App13a1PipelineFixture.cooling)
        )

        fixture.flow.submitDeletion(owner: fixture.owner)
        try await fixture.passStepUp()
        await panelWait("重放没有发出") { [self] in posts.count == 2 }
        await fixture.idle()

        XCTAssertEqual(posts.map { $0.header(HeaderNames.idempotencyKey) }, ["deletion-key-1", "deletion-key-1"],
                       "10003 后沿用原键")
        XCTAssertNil(posts.first?.header(HeaderNames.stepUpToken), "首次没有 token")
        XCTAssertEqual(posts.last?.header(HeaderNames.stepUpToken), App13a1PipelineFixture.stepUpToken,
                       "重放带 account_deletion 的 token")
        XCTAssertEqual(posts.last?.body, "", "重放仍是空体")
        XCTAssertEqual(fixture.keys.issued, 1, "整个过程只生成 1 个键")

        let sms = try XCTUnwrap(App13a1Stub.requests("POST", "/v1/auth/sms-codes").first, "面板发码")
        XCTAssertEqual(sms.json["purpose"] as? String, "step_up")
        XCTAssertEqual(sms.json["action"] as? String, "account_deletion", "发码 action = account_deletion")
        let verify = try XCTUnwrap(App13a1Stub.requests("POST", "/v1/auth/step-up").first, "面板验证")
        XCTAssertEqual(verify.json["action"] as? String, "account_deletion", "验证 action = account_deletion")

        XCTAssertEqual(fixture.host.succeeded, 1)
        XCTAssertTrue(records.isEmpty, "成功：记录删除")
        XCTAssertNil(
            fixture.deps.tokens.take(
                action: "account_deletion", account: App13a1PipelineFixture.account, nowMs: fixture.env.now
            ),
            "服务端核销后 token 丢弃"
        )
    }

    // MARK: - 结果未知

    /// 超时（没有统一外壳）：进待确认，原记录为 unknown；不自动重发、不生成新键，新的提交入口置灰；【确认上一次提交】原键原体（空体）重发。
    func testTimeoutEntersPendingWithoutNewKey() async throws {
        fixture.script.on(
            "POST \(App13a1PipelineFixture.deletionPath)",
            .timeout,
            .envelope(0, App13a1PipelineFixture.cooling)
        )

        fixture.flow.submitDeletion(owner: fixture.owner)
        await panelWait("没有进入待确认") { [self] in fixture.flow.state.pending != nil }
        await fixture.idle()

        XCTAssertEqual(posts.count, 1, "结果未知不自动重发")
        let record = try XCTUnwrap(records.first, "保留未决记录")
        XCTAssertEqual(record.key, "deletion-key-1")
        XCTAssertEqual(record.stateRaw, PendingKeyStore.unknown)
        XCTAssertTrue(record.everUnknown)
        XCTAssertEqual(record.body, "", "原体为空")
        XCTAssertFalse(fixture.flow.state.canSubmit, "待确认：新的提交入口置灰")

        // 用户再点【申请注销】：不发、不生成新键
        fixture.flow.submitDeletion(owner: fixture.owner)
        await fixture.idle()
        XCTAssertEqual(posts.count, 1, "待确认期间再点不发")
        XCTAssertEqual(fixture.keys.issued, 1, "待确认期间不生成新键")

        let pending = try XCTUnwrap(fixture.flow.state.pending)
        fixture.flow.confirm(key: pending.key, owner: fixture.owner)
        await panelWait("确认没有发出") { [self] in posts.count == 2 }
        await fixture.idle()
        XCTAssertEqual(posts.last?.header(HeaderNames.idempotencyKey), "deletion-key-1", "确认用原键")
        XCTAssertEqual(posts.last?.body, "", "确认用原体（空体）")
        XCTAssertTrue(records.isEmpty, "确认成功：记录删除")
        XCTAssertEqual(fixture.keys.issued, 1)
    }

    // MARK: - 非终结响应沿用原键（D10-2090 ② 现状口径）

    // 现状口径（编排 D10-2090 ②）：PendingKeyStore 本单不改，从未结果未知的键遇非终结码时网络层仍删除记录（共性第 7 条「保留原记录」
    // 另登 FU-IOS-PENDINGKEY-NONFINAL-KEEP，在那张 FU 里补存储断言）。这里只钉页面层：再点时 Idempotency-Key 与原键相同、请求体逐字节相同、
    // 不生成新键。

    /// 5xxxx（有统一外壳，不是结果未知）：统一错误 + trace6，不进待确认卡；用户再点用同一个键、同一份请求体（D10-2090 ②，FU-IOS-PENDINGKEY-NONFINAL-KEEP）。
    func test5xxxxKeepsRecordAndNextClickReusesKey() async throws {
        fixture.script.on(
            "POST \(App13a1PipelineFixture.deletionPath)", .envelope(50401, "null"),
            .envelope(0, App13a1PipelineFixture.cooling)
        )

        fixture.flow.submitDeletion(owner: fixture.owner)
        await fixture.idle()

        XCTAssertNil(fixture.flow.state.pending, "5xxxx 不是结果未知：不显示待确认卡")
        XCTAssertEqual(fixture.flow.state.error?.showTrace6, true, "5xxxx 附 trace6")

        fixture.flow.submitDeletion(owner: fixture.owner)
        await fixture.idle()
        XCTAssertEqual(posts.count, 2, "再点照常发出")
        let first = try XCTUnwrap(posts.first)
        let second = try XCTUnwrap(posts.last)
        XCTAssertEqual(first.header(HeaderNames.idempotencyKey), "deletion-key-1")
        XCTAssertEqual(second.header(HeaderNames.idempotencyKey), first.header(HeaderNames.idempotencyKey),
                       "5xxxx 后再点用同一个键")
        XCTAssertEqual(Data(second.body.utf8), Data(first.body.utf8), "5xxxx 后再点请求体逐字节相同")
        XCTAssertEqual(fixture.keys.issued, 1, "5xxxx 后不生成新键")
        XCTAssertTrue(records.isEmpty, "第二次成功后记录删除")
    }

    /// 10007（cooling）：停在本页；再点用同一个键、同一份请求体（D10-2090 ②，FU-IOS-PENDINGKEY-NONFINAL-KEEP）。
    func test10007KeepsRecordAndNextClickReusesKey() async throws {
        fixture.script.on(
            "POST \(App13a1PipelineFixture.deletionPath)", .envelope(10007, "{\"stage\":\"cooling\"}"),
            .envelope(0, App13a1PipelineFixture.cooling)
        )

        fixture.flow.submitDeletion(owner: fixture.owner)
        await fixture.idle()

        XCTAssertNil(fixture.flow.state.pending, "10007 不是结果未知：不显示待确认卡")
        XCTAssertEqual(fixture.flow.state.error?.key, "error.10007")

        fixture.flow.submitDeletion(owner: fixture.owner)
        await fixture.idle()
        XCTAssertEqual(posts.count, 2)
        let first = try XCTUnwrap(posts.first)
        let second = try XCTUnwrap(posts.last)
        XCTAssertEqual(first.header(HeaderNames.idempotencyKey), "deletion-key-1")
        XCTAssertEqual(second.header(HeaderNames.idempotencyKey), first.header(HeaderNames.idempotencyKey),
                       "10007 后再点用同一个键")
        XCTAssertEqual(Data(second.body.utf8), Data(first.body.utf8), "10007 后再点请求体逐字节相同")
        XCTAssertEqual(fixture.keys.issued, 1)
    }

    /// 对照：30416（写入幂等记录的 3xxxx）键结束，记录删除，再点生成新键。
    func test30416EndsKeyAndNextClickUsesNewKey() async {
        fixture.script.on(
            "POST \(App13a1PipelineFixture.deletionPath)", .envelope(30416, "{\"amount_fen\":567}"),
            .envelope(0, App13a1PipelineFixture.cooling)
        )
        fixture.flow.submitDeletion(owner: fixture.owner)
        await fixture.idle()
        XCTAssertTrue(records.isEmpty, "30416：键结束")

        fixture.flow.submitDeletion(owner: fixture.owner)
        await fixture.idle()
        XCTAssertEqual(posts.map { $0.header(HeaderNames.idempotencyKey) }, ["deletion-key-1", "deletion-key-2"],
                       "30416 后再点用新键")
    }

    // MARK: - step_up_token

    /// token 只按 account_deletion 缓存（别的 action、别的账号取不到）；只在内存：未决记录、UserDefaults、会话存储里都没有它。
    func testStepUpTokenScopedToAccountDeletionAndNotPersisted() async throws {
        // 重放得到 5xxxx：token 没被核销，仍在缓存里
        fixture.script.on(
            "POST \(App13a1PipelineFixture.deletionPath)", .envelope(10003, "null"), .envelope(50401, "null")
        )
        fixture.flow.submitDeletion(owner: fixture.owner)
        try await fixture.passStepUp()
        await panelWait("重放没有发出") { [self] in posts.count == 2 }
        await fixture.idle()

        let tokens = fixture.deps.tokens
        let account = App13a1PipelineFixture.account
        let now = fixture.env.now
        XCTAssertEqual(
            tokens.take(action: "account_deletion", account: account, nowMs: now), App13a1PipelineFixture.stepUpToken,
            "缓存按 account_deletion"
        )
        for action in ["withdraw", "payout_account_change", "phone_change"] {
            XCTAssertNil(tokens.take(action: action, account: account, nowMs: now), "\(action) 不能复用注销的 token")
        }
        XCTAssertNil(tokens.take(action: "account_deletion", account: "user-b", nowMs: now), "别的账号取不到")

        let token = App13a1PipelineFixture.stepUpToken
        for record in fixture.backend.list(account: account) {
            XCTAssertFalse(record.body.contains(token), "未决记录原体不含 token")
            XCTAssertFalse(record.summary.contains(token), "未决记录摘要不含 token")
        }
        let defaults = UserDefaults.standard.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined()
        XCTAssertFalse(defaults.contains(token), "UserDefaults 没有 token")
        let session = try fixture.sessionTokens.readSession()
        XCTAssertNotEqual(session?.access, token)
        XCTAssertNotEqual(session?.refresh, token)
    }

    // MARK: - 身份固定与离页

    /// 会话换代（换账号 / 登出）后执行旧回调：零请求、零写入、不生成键。
    func testOldCallbacksAfterSessionChangeSendNothing() async {
        fixture.env.current = false
        fixture.flow.submitDeletion(owner: fixture.owner)
        await fixture.idle()
        XCTAssertTrue(App13a1Stub.requests.isEmpty, "会话已换：旧回调零请求")
        XCTAssertTrue(records.isEmpty, "零写入")
        XCTAssertEqual(fixture.keys.issued, 0, "不生成键")
    }

    /// 待确认卡上的旧回调（确认 / 放弃）在会话换代后执行：零请求。
    func testOldPendingCallbacksAfterSessionChangeSendNothing() async throws {
        fixture.script.on("POST \(App13a1PipelineFixture.deletionPath)", .timeout)
        fixture.flow.submitDeletion(owner: fixture.owner)
        await panelWait("没有进入待确认") { [self] in fixture.flow.state.pending != nil }
        await fixture.idle()
        let key = try XCTUnwrap(fixture.flow.state.pending?.key)
        let before = App13a1Stub.requests.count

        fixture.env.current = false
        fixture.flow.confirm(key: key, owner: fixture.owner)
        fixture.flow.askAbandon(key: key, owner: fixture.owner)
        fixture.flow.abandon(key: key, owner: fixture.owner)
        await fixture.idle()
        XCTAssertEqual(App13a1Stub.requests.count, before, "旧确认 / 放弃回调零请求")
        XCTAssertEqual(records.first?.stateRaw, PendingKeyStore.unknown, "未决记录按账号保留")
    }

    /// 申请在途时离页：写请求不取消；迟到的结果不改已离开的页面，但未决记录按结果落定（超时 → unknown）。
    func testLeavingPageKeepsWriteAndLateResultOnlySettlesRecord() async throws {
        fixture.script.on("POST \(App13a1PipelineFixture.deletionPath)", .hold)
        fixture.flow.submitDeletion(owner: fixture.owner)
        await panelWait("申请没有到达假服务") { App13a1Stub.heldIds.count == 1 }

        let snapshot = fixture.flow.state
        fixture.life.alive = false
        fixture.flow.detach()
        let held = try XCTUnwrap(App13a1Stub.heldIds.first)
        App13a1Stub.release(held, with: .timeout)
        await panelWait("迟到结果没有落到未决记录") { [self] in records.first?.stateRaw == PendingKeyStore.unknown }
        await fixture.idle()

        XCTAssertEqual(records.first?.key, "deletion-key-1", "未决记录是原键")
        XCTAssertEqual(fixture.flow.state, snapshot, "离页后迟到结果不改页面")
        XCTAssertEqual(posts.count, 1)
    }
}
