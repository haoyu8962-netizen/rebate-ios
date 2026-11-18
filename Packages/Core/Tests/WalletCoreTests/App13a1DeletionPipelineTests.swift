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
        fixture.script.on("POST \(App13a1PipelineFixture.deletionPath)", .timeout, .envelope(0, App13a1PipelineFixture.cooling))

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
    func test30416EndsKeyAndNextClickUsesNewKey() async throws {
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

// MARK: - 夹具

/// 本地假服务（URLProtocol）：按「方法 路径」脚本回答；可挂起后放行；可按超时结束（没有统一外壳）。记录方法、路径、请求体与请求头。
final class App13a1Stub: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case envelope(Int, String)
        case timeout
        case hold
    }

    struct Recorded: Sendable {
        let method: String
        let path: String
        let body: String
        let headers: [String: String]
        let id: Int

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((Recorded) -> Reply)?
    private nonisolated(unsafe) static var recorded: [Recorded] = []
    private nonisolated(unsafe) static var held: [Int: App13a1Stub] = [:]
    private nonisolated(unsafe) static var next = 0
    private let stoppedLock = NSLock()
    private var stopped = false

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [App13a1Stub.self]
        return config
    }

    static func reset() {
        lock.withLock {
            handler = nil
            recorded = []
            held = [:]
            next = 0
        }
    }

    static func install(_ handler: @escaping (Recorded) -> Reply) {
        lock.withLock { self.handler = handler }
    }

    static var requests: [Recorded] {
        lock.withLock { recorded }
    }

    static func requests(_ method: String, _ path: String) -> [Recorded] {
        requests.filter { $0.method == method && $0.path == path }
    }

    static var heldIds: [Int] {
        lock.withLock { held.keys.sorted() }
    }

    static func release(_ id: Int, with reply: Reply) {
        let target = lock.withLock { held.removeValue(forKey: id) }
        target?.answer(reply)
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let entry: Recorded = Self.lock.withLock {
            Self.next += 1
            return Recorded(
                method: request.httpMethod ?? "GET", path: url.path, body: Self.body(request),
                headers: request.allHTTPHeaderFields ?? [:], id: Self.next
            )
        }
        let reply: Reply = Self.lock.withLock {
            Self.recorded.append(entry)
            return Self.handler?(entry) ?? .envelope(0, "{}")
        }
        if case .hold = reply {
            Self.lock.withLock { Self.held[entry.id] = self }
            return
        }
        answer(reply)
    }

    func answer(_ reply: Reply) {
        guard !stoppedLock.withLock({ stopped }) else { return }
        let url = request.url ?? URL(fileURLWithPath: "/")
        switch reply {
        case .timeout:
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case let .envelope(code, data):
            let text = "{\"code\":\(code),\"msg\":\"\",\"data\":\(data),\"trace_id\":\"stub-trace-0123456789ab\"}"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])
            client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .hold:
            break
        }
    }

    override func stopLoading() {
        stoppedLock.withLock { stopped = true }
    }

    private static func body(_ request: URLRequest) -> String {
        if let data = request.httpBody {
            return String(bytes: data, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
        var data = Data()
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        stream.close()
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

/// 按「方法 路径」排队的回答（用完重复最后一个）；没登记的：发码 / 验证给成功，其余 {}。
final class App13a1Script: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [App13a1Stub.Reply]] = [:]

    func on(_ key: String, _ replies: App13a1Stub.Reply...) {
        lock.withLock { queues[key] = replies }
    }

    func ok(_ key: String, _ data: String) {
        on(key, .envelope(0, data))
    }

    func reply(_ request: App13a1Stub.Recorded) -> App13a1Stub.Reply {
        let key = "\(request.method) \(request.path)"
        let scripted: App13a1Stub.Reply? = lock.withLock {
            guard var queue = queues[key], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            queues[key] = queue.isEmpty ? [first] : queue
            return first
        }
        if let scripted {
            return scripted
        }
        switch key {
        case "POST /v1/auth/sms-codes":
            return .envelope(0, "{\"resend_after_sec\":60,\"expires_in_sec\":300}")
        case "POST /v1/auth/step-up":
            return .envelope(
                0, "{\"step_up_token\":\"\(App13a1PipelineFixture.stepUpToken)\",\"expire_at\":\"2099-01-01T00:05:00+08:00\"}"
            )
        default:
            return .envelope(0, "{}")
        }
    }
}

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
