import CouliNetwork
import Foundation
@testable import WalletCore
import XCTest

/// FU-IOS-DELETION-REAPPLY-STALE-KEY 写测第 2 次（独立写测方）：申请注销幂等键的真实保证，钉在执行层——真实 `SensitiveFlow.accountDeletion`
/// + 真实 `ApiClient`（未决键 PendingKeyStore、内存后端）+ 本地假服务（夹具同 App13a1DeletionPipelineTests，不连任何地址）。
///
/// 依据：编排 D10-3452（网络层不加入口；结果未知时注销页显示待确认卡、没有【撤回注销】，用户只能先【确认】或【放弃】，两条出口都结束旧键）、
/// D10-2914（申请得 code 0 或任何 3xxxx：服务端存应答、同键回放，下次必须换键；1xxxx / 5xxxx / 结果未知才持键）。
/// - 结果未知 →【确认】得 0 /【放弃】得 abandoned /【放弃】得 completed(0)（already_done）→ 本机记录已删、待确认结束 → 再申请：
///   请求带新键，且照常发出（不被本地 pending_key_unresolved 拒绝）；
/// - 30412、表外 3xxxx → 记录删除、再申请新键（30416 与 5xxxx 同键已在 App13a1DeletionPipelineTests，不重复）；
/// - 跨设备撤回：本机结果未知的记录还在、他端已撤回 → 回到页面按本机记录重建出待确认卡 →【确认】（服务端回放旧冷静期应答）→ 记录删除 →
///   再申请新键。
@MainActor
final class FuIosDeletionReapplyPipelineTests: XCTestCase {
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

    private static let deletion = "POST \(App13a1PipelineFixture.deletionPath)"
    private static let abandonPath = "/v1/idempotency-keys/abandon"

    private var posts: [App13a1Stub.Recorded] {
        App13a1Stub.requests("POST", App13a1PipelineFixture.deletionPath)
    }

    private var postedKeys: [String?] {
        posts.map { $0.header(HeaderNames.idempotencyKey) }
    }

    private var records: [PendingKeyRecord] {
        fixture.backend.list(account: App13a1PipelineFixture.account)
    }

    // MARK: - 结果未知 → 确认 / 放弃 → 再申请新键

    /// 申请超时（结果未知）→【确认上一次提交】得 0 → 记录删除、待确认结束 → 再申请：新键、照常发出。
    func testUnknownThenConfirmDoneNextApplyUsesNewKey() async throws {
        fixture.script.on(
            Self.deletion, .timeout, .envelope(0, App13a1PipelineFixture.cooling),
            .envelope(0, App13a1PipelineFixture.cooling)
        )
        let key = try await enterUnknown(fixture.flow)

        fixture.flow.confirm(key: key, owner: fixture.owner)
        await panelWait("确认没有结算") { [self] in posts.count == 2 && fixture.flow.state.pending == nil }
        await fixture.idle()
        XCTAssertEqual(postedKeys, ["deletion-key-1", "deletion-key-1"], "确认用原键")
        XCTAssertEqual(fixture.host.succeeded, 1, "确认得 0：成功交给发起页")

        try await assertEndedThenNewKey(fixture.flow, sentBefore: 2, "确认得 0")
    }

    /// 申请超时 →【放弃上一次提交】（二次确认后）得 abandoned → 记录删除、待确认结束 → 再申请：新键、照常发出。
    func testUnknownThenAbandonAbandonedNextApplyUsesNewKey() async throws {
        fixture.script.on(Self.deletion, .timeout, .envelope(0, App13a1PipelineFixture.cooling))
        fixture.script.ok("POST \(Self.abandonPath)", "{\"outcome\":\"abandoned\",\"original\":null}")
        let key = try await enterUnknown(fixture.flow)

        try await abandon(fixture.flow, key: key)
        XCTAssertEqual(fixture.host.succeeded, 0, "abandoned 不是业务成功")

        try await assertEndedThenNewKey(fixture.flow, sentBefore: 1, "放弃得 abandoned")
    }

    /// 申请超时 →【放弃上一次提交】得 completed 且原结果 code 0（already_done：作废时已经处理完）→ 记录删除 → 再申请：新键、照常发出。
    func testUnknownThenAbandonCompletedAlreadyDoneNextApplyUsesNewKey() async throws {
        fixture.script.on(Self.deletion, .timeout, .envelope(0, App13a1PipelineFixture.cooling))
        fixture.script.ok(
            "POST \(Self.abandonPath)",
            "{\"outcome\":\"completed\",\"original\":{\"code\":0,\"msg\":\"\","
                + "\"data\":\(App13a1PipelineFixture.cooling)}}"
        )
        let key = try await enterUnknown(fixture.flow)

        try await abandon(fixture.flow, key: key)
        XCTAssertEqual(fixture.host.succeeded, 1, "already_done：按成功交给发起页")

        try await assertEndedThenNewKey(fixture.flow, sentBefore: 1, "放弃得 completed(0)")
    }

    // MARK: - 3xxxx → 再申请新键

    /// 30412（有进行中的提现）：服务端存了拒绝应答，键结束、记录删除，再申请用新键。
    func test30412EndsRecordAndNextApplyUsesNewKey() async {
        await assert3xxxxEndsKey(30412)
    }

    /// 表外 3xxxx（共用映射之外的业务码，同样被服务端存下回放）：键结束、记录删除，再申请用新键。
    func testOffTable3xxxxEndsRecordAndNextApplyUsesNewKey() async {
        await assert3xxxxEndsKey(30499)
    }

    // MARK: - 跨设备撤回

    /// 本机申请结果未知（记录 unknown）→ 离开页面；他端已撤回注销 → 回到页面（新的流程按本机记录重建）：待确认卡、新的申请不发 →
    /// 【确认】（服务端回放这个键存下的旧冷静期应答，code 0）→ 记录删除 → 再申请：新键、照常发出。
    func testCrossDeviceCancelWhileUnknownThenConfirmNextApplyUsesNewKey() async throws {
        fixture.script.on(
            Self.deletion, .timeout, .envelope(0, App13a1PipelineFixture.cooling),
            .envelope(0, App13a1PipelineFixture.cooling)
        )
        _ = try await enterUnknown(fixture.flow)
        fixture.life.alive = false
        fixture.flow.detach()

        // 回到页面：新的注销流程（同一会话、同一份依赖），按本机未决记录重建
        let page = SensitiveFlow.accountDeletion(deps: fixture.deps, owner: fixture.owner, alive: { true })
        page.attach(fixture.host)
        defer { page.detach() }
        page.syncPending()
        await panelWait("回到页面后没有按本机记录重建待确认") { page.state.pending != nil }
        await idle(page)
        let pending = try XCTUnwrap(page.state.pending)
        XCTAssertEqual(pending.key, "deletion-key-1", "待确认卡是原键")
        XCTAssertFalse(page.state.canSubmit, "待确认：新的申请入口置灰")
        page.submitDeletion(owner: fixture.owner)
        await idle(page)
        XCTAssertEqual(posts.count, 1, "待确认期间再点申请不发")

        page.confirm(key: pending.key, owner: fixture.owner)
        await panelWait("确认没有结算") { [self] in posts.count == 2 && page.state.pending == nil }
        await idle(page)
        XCTAssertEqual(postedKeys, ["deletion-key-1", "deletion-key-1"], "确认用原键")

        try await assertEndedThenNewKey(page, sentBefore: 2, "跨设备撤回后确认")
    }

    // MARK: - 驱动

    /// 第一次申请超时：进待确认，记录 unknown，新的提交入口置灰。返回待确认卡上的键。
    private func enterUnknown(
        _ flow: SensitiveFlow, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> String {
        flow.submitDeletion(owner: fixture.owner)
        await panelWait("没有进入待确认", file: file, line: line) { flow.state.pending != nil }
        await idle(flow)
        let record = try XCTUnwrap(records.first, "前提：保留未决记录", file: file, line: line)
        XCTAssertEqual(record.key, "deletion-key-1", file: file, line: line)
        XCTAssertEqual(record.stateRaw, PendingKeyStore.unknown, "前提：记录为结果未知", file: file, line: line)
        XCTAssertFalse(flow.state.canSubmit, "前提：待确认时不能新申请", file: file, line: line)
        return try XCTUnwrap(flow.state.pending?.key, file: file, line: line)
    }

    /// 二次确认后【确定放弃】：作废请求带原键与 action = account_deletion，结算后待确认结束。
    private func abandon(
        _ flow: SensitiveFlow, key: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        flow.askAbandon(key: key, owner: fixture.owner)
        XCTAssertEqual(flow.state.abandonConfirmKey, key, "前提：弹出放弃二次确认", file: file, line: line)
        flow.abandon(key: key, owner: fixture.owner)
        await panelWait("放弃没有结算", file: file, line: line) { flow.state.pending == nil }
        await idle(flow)
        let sent = try XCTUnwrap(
            App13a1Stub.requests("POST", Self.abandonPath).first, "作废请求发出", file: file, line: line
        )
        XCTAssertEqual(sent.json["idempotency_key"] as? String, key, "作废原键", file: file, line: line)
        XCTAssertEqual(sent.json["action"] as? String, "account_deletion", "作废 action", file: file, line: line)
    }

    /// 键结束后：本机记录已删、待确认结束、可以新申请 → 再申请照常发出（不被本地拒绝）、带新键，成功后记录删除。
    private func assertEndedThenNewKey(
        _ flow: SensitiveFlow, sentBefore: Int, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        XCTAssertTrue(records.isEmpty, "\(label)：本机未决记录已删", file: file, line: line)
        XCTAssertNil(flow.state.pending, "\(label)：待确认结束", file: file, line: line)
        XCTAssertTrue(flow.state.canSubmit, "\(label)：可以新申请", file: file, line: line)

        flow.submitDeletion(owner: fixture.owner)
        await panelWait("\(label)：再申请没有发出", file: file, line: line) { [self] in posts.count == sentBefore + 1 }
        await idle(flow)
        let last = try XCTUnwrap(posts.last, file: file, line: line)
        XCTAssertEqual(
            last.header(HeaderNames.idempotencyKey), "deletion-key-2", "\(label)：再申请必须用新键", file: file, line: line
        )
        XCTAssertEqual(fixture.keys.issued, 2, "\(label)：再申请生成了新键", file: file, line: line)
        XCTAssertNil(flow.state.error, "\(label)：再申请没有被本地拒绝或报错", file: file, line: line)
        XCTAssertNil(flow.state.pending, "\(label)：再申请成功后不进待确认", file: file, line: line)
        XCTAssertTrue(records.isEmpty, "\(label)：再申请成功后记录删除", file: file, line: line)
    }

    private func assert3xxxxEndsKey(_ code: Int, file: StaticString = #filePath, line: UInt = #line) async {
        fixture.script.on(Self.deletion, .envelope(code, "null"), .envelope(0, App13a1PipelineFixture.cooling))
        fixture.flow.submitDeletion(owner: fixture.owner)
        await fixture.idle()
        XCTAssertEqual(posts.count, 1, "\(code)：申请发出 1 次", file: file, line: line)
        XCTAssertTrue(records.isEmpty, "\(code)：键结束、记录删除", file: file, line: line)
        XCTAssertNil(fixture.flow.state.pending, "\(code)：不进待确认", file: file, line: line)

        fixture.flow.submitDeletion(owner: fixture.owner)
        await fixture.idle()
        XCTAssertEqual(
            postedKeys, ["deletion-key-1", "deletion-key-2"], "\(code) 后再申请用新键", file: file, line: line
        )
        XCTAssertTrue(records.isEmpty, "\(code)：第二次成功后记录删除", file: file, line: line)
    }

    private func idle(_ flow: SensitiveFlow) async {
        for _ in 0..<6 {
            await flow.stepUp.whenIdle()
            await flow.whenIdle()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
