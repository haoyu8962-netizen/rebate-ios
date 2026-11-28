import AuthenticationServices
@testable import Couli
import CryptoKit
import Foundation
import Trade
import XCTest

/// sha256（UTF-8 字节、小写十六进制）：测试自己算，不复用被测代码。
func webCodeReferenceSha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// 授权结果的可比较写法。
func webCodeOutcome(_ result: AuthStepResult?) -> String {
    switch result {
    case .none: "pending"
    case .cancelled?: "cancelled"
    case .failed?: "failed"
    case let .credential(.webCode(code))?: "credential:\(code)"
    case .credential(.sdkToken)?: "credential:sdkToken"
    }
}

/// 假会话句柄：记 cancel 次数，并在共用事件序列里留痕。
@MainActor
final class WebCodeFakeSession: WebAuthSessionHandle {
    let index: Int
    private(set) var cancelCount = 0
    private let onCancel: @MainActor (Int) -> Void

    init(index: Int, onCancel: @escaping @MainActor (Int) -> Void) {
        self.index = index
        self.onCancel = onCancel
    }

    func cancel() {
        cancelCount += 1
        onCancel(index)
    }
}

/// 假会话端口：记下每次 start 的参数、start 时刻的尝试记录与 completion，由测试手动回调。
@MainActor
final class WebCodeFakeLauncher: WebAuthSessionLauncher {
    struct Start {
        let url: URL
        let callbackURLScheme: String
        let prefersEphemeral: Bool
        let attemptAtStart: WebCodeAttempt?
        let completion: @MainActor (URL?, (any Error)?) -> Void
        let session: WebCodeFakeSession?
    }

    private(set) var starts: [Start] = []
    private(set) var events: [String] = []
    /// true：start 返回 nil（模拟系统 start 失败）。
    var startFails = false
    var attemptSnapshot: @MainActor () -> WebCodeAttempt? = { nil }

    func start(
        url: URL,
        callbackURLScheme: String,
        prefersEphemeralWebBrowserSession: Bool,
        completion: @escaping @MainActor (URL?, (any Error)?) -> Void
    ) -> (any WebAuthSessionHandle)? {
        let index = starts.count
        events.append("start#\(index)")
        let session = startFails ? nil : WebCodeFakeSession(index: index) { [weak self] in
            self?.events.append("cancel#\($0)")
        }
        starts.append(Start(
            url: url, callbackURLScheme: callbackURLScheme, prefersEphemeral: prefersEphemeralWebBrowserSession,
            attemptAtStart: attemptSnapshot(), completion: completion, session: session
        ))
        return session
    }
}

/// 内存尝试记录：行为同生产语义，另记每次调用。
@MainActor
final class WebCodeFakeAttempts: WebCodeAttemptStore {
    private(set) var stored: WebCodeAttempt?
    private(set) var recordCount = 0
    private(set) var clearedHashes: [String] = []
    private(set) var clearAllCount = 0

    func record(state: String, nowMillis: Int64) {
        recordCount += 1
        stored = WebCodeAttempt(stateSha256: webCodeReferenceSha256(state), startedAtMillis: nowMillis)
    }

    func current() -> WebCodeAttempt? {
        stored
    }

    func clear() {
        clearAllCount += 1
        stored = nil
    }

    func clearIfCurrent(stateSha256: String) {
        clearedHashes.append(stateSha256)
        if stored?.stateSha256 == stateSha256 {
            stored = nil
        }
    }
}

/// 一次 `authorize` 的观察点。
@MainActor
final class WebCodeAuthorizeProbe {
    var result: AuthStepResult?
    var task: Task<Void, Never>?
    var done: Bool {
        result != nil
    }

    var outcome: String {
        webCodeOutcome(result)
    }
}

/// 授权器 + 假端口 + 尝试记录 + 固定时钟。
@MainActor
final class WebCodeAuthorizerRig {
    static let authUrl = "https://oauth.taobao.com/authorize?response_type=code&client_id=12345&view=wap"
    static let startedAt: Int64 = 1_700_000_000_000
    let launcher: WebCodeFakeLauncher
    let attempts: any WebCodeAttemptStore
    let authorizer: WebAuthSessionWebCodeAuthorizer

    init(attempts: any WebCodeAttemptStore = WebCodeFakeAttempts()) {
        let launcher = WebCodeFakeLauncher()
        self.launcher = launcher
        self.attempts = attempts
        let startedAt = Self.startedAt
        authorizer = WebAuthSessionWebCodeAuthorizer(launcher: launcher, attempts: attempts, clock: { startedAt })
        launcher.attemptSnapshot = { [attempts] in attempts.current() }
    }

    func begin(state: String, authUrl: String = WebCodeAuthorizerRig.authUrl) -> WebCodeAuthorizeProbe {
        let probe = WebCodeAuthorizeProbe()
        let authorizer = authorizer
        probe.task = Task { @MainActor in
            probe.result = await authorizer.authorize(authUrl: authUrl, state: state)
        }
        return probe
    }

    /// 等条件成立（最多约 2 秒；不成立就返回，由随后的断言判红）。
    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// 起一次授权并等到会话启动（或调用已结束）；返回第 `index` 次 start。底座不启动会话：XCTUnwrap 按断言红。
    func beginAndStart(
        state: String, index: Int = 0
    ) async throws -> (WebCodeAuthorizeProbe, WebCodeFakeLauncher.Start) {
        let probe = begin(state: state)
        await waitUntil { launcher.starts.count > index || probe.done }
        let start = try XCTUnwrap(
            launcher.starts.count > index ? launcher.starts[index] : nil,
            "白名单内的 auth_url 应启动会话（第 \(index + 1) 次）；实际 \(probe.outcome)"
        )
        return (probe, start)
    }
}

/// FU-IOS-TB-WEBCODE-A：真实授权器 `WebAuthSessionWebCodeAuthorizer`（假会话端口，不碰系统会话；scope-ios §四「iOS 甲」写测要点）。
/// 底座 `authorize` 立即 `.failed`、`available` 为 false、`isAllowedAuthUrl` 为 false：正向用例按断言红（多数红在
/// 「应启动会话」的 XCTUnwrap），白名单外的反向用例在底座上就绿。
@MainActor
final class WebAuthSessionWebCodeAuthorizerTests: XCTestCase {
    private var canceledLogin: ASWebAuthenticationSessionError {
        ASWebAuthenticationSessionError(.canceledLogin)
    }

    private func callback(_ query: String) -> URL? {
        URL(string: "couli://auth/taobao?" + query)
    }

    // MARK: - 定值与可用性

    func testConstantsFollowTheRulings() {
        XCTAssertEqual(WebAuthSessionWebCodeAuthorizer.authScheme, "https")
        XCTAssertEqual(WebAuthSessionWebCodeAuthorizer.authHost, "oauth.taobao.com", "D10-2717 白名单只放 oauth.taobao.com")
        XCTAssertEqual(WebAuthSessionWebCodeAuthorizer.callbackURLScheme, "couli")
        XCTAssertFalse(WebAuthSessionWebCodeAuthorizer.prefersEphemeralWebBrowserSession, "D10-3567 ⑥ 共用 Safari 登录态")
    }

    func testRealAuthorizerIsAlwaysAvailable() {
        XCTAssertTrue(WebCodeAuthorizerRig().authorizer.available, "真实授权器恒可执行")
    }

    func testAllowedAuthUrls() {
        for url in [WebCodeAuthorizerRig.authUrl, "https://oauth.taobao.com/authorize", "https://OAuth.Taobao.com/x"] {
            XCTAssertTrue(WebAuthSessionWebCodeAuthorizer.isAllowedAuthUrl(url), "应放行：\(url)")
        }
    }

    // MARK: - 白名单外（反向，底座上就绿）

    func testUrlsOutsideTheAllowlistNeverStartASession() async {
        let rejected = [
            "http://oauth.taobao.com/authorize", "https://oauth.taobao.com.evil.example/authorize",
            "https://evil.example/authorize?h=oauth.taobao.com", "https://oauth.m.taobao.com/authorize",
            "https://tbsandbox.com/authorize", "https://taobao.com/authorize", "https://xoauth.taobao.com/authorize",
            "https://u@oauth.taobao.com/authorize", "https://u:p@oauth.taobao.com/authorize",
            "https://oauth.taobao.com:8443/authorize", "https://oauth.taobao.com:443/authorize",
            "https://evil.example#@oauth.taobao.com/", "oauth.taobao.com/authorize", "//oauth.taobao.com/authorize",
            "javascript:alert(1)", "file:///etc/hosts", "couli://auth/taobao?code=C1&state=S1",
            "https://oauth.example.invalid/authorize?state=st_01", "", "not a url",
            "https://oauth.taobao.com:/x", "https://oauth.taobao.com%40evil.example/", "https://oauth.taobao.com./x",
            "https://oauth%2Etaobao.com/x", "https://%6Fauth.taobao.com/x", "HTTPS://oauth.taobao.com/x",
            "https://%6F%61%75%74%68%2E%74%61%6F%62%61%6F%2E%63%6F%6D/x", "https://x\\@oauth.taobao.com/",
            "https://evil.example\\@oauth.taobao.com/", "https://u%40evil.example@oauth.taobao.com/",
        ]
        for url in rejected {
            XCTAssertFalse(WebAuthSessionWebCodeAuthorizer.isAllowedAuthUrl(url), "不放行：\(url)")
            let rig = WebCodeAuthorizerRig()
            let attempts = rig.attempts as? WebCodeFakeAttempts
            let probe = rig.begin(state: "S1", authUrl: url)
            await rig.waitUntil { probe.done }
            XCTAssertEqual(probe.outcome, "failed", "白名单外 → failed：\(url)")
            XCTAssertEqual(rig.launcher.starts.count, 0, "白名单外不启动会话：\(url)")
            XCTAssertEqual(attempts?.recordCount, 0, "白名单外不写尝试记录：\(url)")
            XCTAssertNil(rig.attempts.current(), url)
        }
    }

    // MARK: - 启动参数与记录顺序

    func testStartPassesUrlSchemeAndSharedSessionAfterRecordingTheAttempt() async throws {
        let rig = WebCodeAuthorizerRig()
        let (probe, start) = try await rig.beginAndStart(state: "S1")
        XCTAssertEqual(start.url.absoluteString, WebCodeAuthorizerRig.authUrl, "auth_url 原样交给会话")
        XCTAssertEqual(start.callbackURLScheme, "couli")
        XCTAssertFalse(start.prefersEphemeral, "prefersEphemeralWebBrowserSession 传 false（D10-3567 ⑥）")
        XCTAssertEqual(
            start.attemptAtStart,
            WebCodeAttempt(stateSha256: webCodeReferenceSha256("S1"), startedAtMillis: WebCodeAuthorizerRig.startedAt),
            "先写尝试记录（哈希 + clock 时间）再 start"
        )
        start.completion(nil, canceledLogin)
        await rig.waitUntil { probe.done }
    }

    // MARK: - completion 映射

    func testMatchingCallbackGivesCredentialAndClearsTheRecordByHash() async throws {
        let attempts = WebCodeFakeAttempts()
        let rig = WebCodeAuthorizerRig(attempts: attempts)
        let (probe, start) = try await rig.beginAndStart(state: "S1")
        start.completion(callback("code=C1&state=S1"), nil)
        await rig.waitUntil { probe.done }
        XCTAssertEqual(probe.outcome, "credential:C1", "匹配的回跳 → 凭证")
        XCTAssertEqual(attempts.clearedHashes, [webCodeReferenceSha256("S1")], "按本次哈希删记录")
        XCTAssertEqual(attempts.clearAllCount, 0, "不调 clear()（两次尝试并存时不删后一次的记录）")
        XCTAssertNil(attempts.current())
        start.completion(nil, canceledLogin)
        await settleAuthorizer()
        XCTAssertEqual(probe.outcome, "credential:C1", "completion 再到一次：忽略，只 resume 一次")
        XCTAssertEqual(attempts.clearedHashes.count, 1)
    }

    func testCanceledLoginIsCancelledAndKeepsTheRecord() async throws {
        let attempts = WebCodeFakeAttempts()
        let rig = WebCodeAuthorizerRig(attempts: attempts)
        let (probe, start) = try await rig.beginAndStart(state: "S1")
        start.completion(nil, canceledLogin)
        await rig.waitUntil { probe.done }
        XCTAssertEqual(probe.outcome, "cancelled", "canceledLogin → cancelled")
        XCTAssertEqual(attempts.current()?.stateSha256, webCodeReferenceSha256("S1"), "记录保留（留给晚到回跳核对）")
        XCTAssertEqual(attempts.clearedHashes, [])
        XCTAssertEqual(attempts.clearAllCount, 0)
    }

    func testErrorOneIsFailedAndClearsTheRecordByHash() async throws {
        let attempts = WebCodeFakeAttempts()
        let rig = WebCodeAuthorizerRig(attempts: attempts)
        let (probe, start) = try await rig.beginAndStart(state: "S1")
        start.completion(callback("state=S1&error=1"), nil)
        await rig.waitUntil { probe.done }
        XCTAssertEqual(probe.outcome, "failed", "error=1 → failed")
        XCTAssertEqual(attempts.clearedHashes, [webCodeReferenceSha256("S1")], "按本次哈希删记录")
        XCTAssertEqual(attempts.clearAllCount, 0)
    }

    func testUnusableCompletionsAreFailed() async throws {
        struct Row {
            let why: String
            let url: URL?
            let error: (any Error)?
        }
        let rows = [
            Row(why: "state 不符", url: callback("code=C1&state=OTHER"), error: nil),
            Row(why: "error=1 但 state 不符", url: callback("state=OTHER&error=1"), error: nil),
            Row(why: "解析不了（fragment）", url: callback("code=C1&state=S1#x"), error: nil),
            Row(why: "别的 host", url: URL(string: "couli://r/taobao?code=C1&state=S1"), error: nil),
            Row(why: "没有地址也没有错误", url: nil, error: nil),
            Row(why: "presentationContextNotProvided", url: nil,
                error: ASWebAuthenticationSessionError(.presentationContextNotProvided)),
            Row(why: "presentationContextInvalid", url: nil,
                error: ASWebAuthenticationSessionError(.presentationContextInvalid)),
            Row(why: "其他错误", url: nil,
                error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)),
        ]
        for row in rows {
            let rig = WebCodeAuthorizerRig()
            let (probe, start) = try await rig.beginAndStart(state: "S1")
            start.completion(row.url, row.error)
            await rig.waitUntil { probe.done }
            XCTAssertEqual(probe.outcome, "failed", "\(row.why) → failed")
        }
    }

    func testStartFailureIsFailedAndClearsTheRecordByHash() async {
        let attempts = WebCodeFakeAttempts()
        let rig = WebCodeAuthorizerRig(attempts: attempts)
        rig.launcher.startFails = true
        let probe = rig.begin(state: "S1")
        await rig.waitUntil { probe.done }
        XCTAssertEqual(rig.launcher.starts.count, 1, "应尝试启动一次会话")
        XCTAssertEqual(probe.outcome, "failed", "start 返回 nil → failed")
        XCTAssertEqual(attempts.recordCount, 1, "start 之前已写记录")
        XCTAssertEqual(attempts.clearedHashes, [webCodeReferenceSha256("S1")], "start 失败按本次哈希删记录")
        XCTAssertNil(attempts.current())
    }

    // MARK: - 一次只开一个会话、只 resume 一次

    func testSecondAuthorizeCancelsTheFirstSessionBeforeStarting() async throws {
        let rig = WebCodeAuthorizerRig()
        let (first, firstStart) = try await rig.beginAndStart(state: "S1")
        let (second, secondStart) = try await rig.beginAndStart(state: "S2", index: 1)
        XCTAssertEqual(rig.launcher.events, ["start#0", "cancel#0", "start#1"], "先 cancel 旧会话再开新会话")
        await rig.waitUntil { first.done }
        XCTAssertEqual(first.outcome, "cancelled", "被新一次授权取代：旧调用以 cancelled 结束")
        firstStart.completion(nil, canceledLogin)
        firstStart.completion(callback("code=C1&state=S1"), nil)
        await settleAuthorizer()
        XCTAssertEqual(first.outcome, "cancelled", "旧会话迟到的 completion 忽略")
        XCTAssertFalse(second.done, "旧会话迟到的 completion 不影响新会话")
        XCTAssertEqual(firstStart.session?.cancelCount, 1)
        secondStart.completion(callback("code=C2&state=S2"), nil)
        await rig.waitUntil { second.done }
        XCTAssertEqual(second.outcome, "credential:C2")
        XCTAssertEqual(secondStart.session?.cancelCount, 0)
    }

    func testAbortCancelsTheSessionOnceAndIgnoresTheLateCompletion() async throws {
        let rig = WebCodeAuthorizerRig()
        let (probe, start) = try await rig.beginAndStart(state: "S1")
        rig.authorizer.abort()
        await rig.waitUntil { probe.done }
        XCTAssertEqual(probe.outcome, "cancelled", "abort → cancelled")
        XCTAssertEqual(start.session?.cancelCount, 1, "abort 时 cancel 旧会话")
        start.completion(callback("code=C1&state=S1"), nil)
        await settleAuthorizer()
        XCTAssertEqual(probe.outcome, "cancelled", "abort 之后到达的 completion 忽略")
        rig.authorizer.abort()
        XCTAssertEqual(start.session?.cancelCount, 1, "没有活会话时 abort 不再 cancel")
    }

    func testCallerTaskCancellationCancelsTheSession() async throws {
        let rig = WebCodeAuthorizerRig()
        let (probe, start) = try await rig.beginAndStart(state: "S1")
        probe.task?.cancel()
        await rig.waitUntil { probe.done }
        XCTAssertEqual(probe.outcome, "cancelled", "调用方任务被取消 → cancelled")
        XCTAssertEqual(start.session?.cancelCount, 1, "并 cancel 会话")
        start.completion(nil, canceledLogin)
        await settleAuthorizer()
        XCTAssertEqual(probe.outcome, "cancelled")
    }

    func testSequentialAuthorizationsAfterCompletionDoNotCancelAnything() async throws {
        let rig = WebCodeAuthorizerRig()
        let (first, firstStart) = try await rig.beginAndStart(state: "S1")
        firstStart.completion(nil, canceledLogin)
        await rig.waitUntil { first.done }
        let (second, secondStart) = try await rig.beginAndStart(state: "S2", index: 1)
        XCTAssertEqual(rig.launcher.events, ["start#0", "start#1"], "上一次已结束：不再 cancel 它")
        secondStart.completion(callback("code=C2&state=S2"), nil)
        await rig.waitUntil { second.done }
        XCTAssertEqual(second.outcome, "credential:C2")
    }

    /// 给迟到的 completion 几轮调度。
    private func settleAuthorizer() async {
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
