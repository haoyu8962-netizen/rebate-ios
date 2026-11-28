import AuthenticationServices
@testable import Couli
import Foundation
import Network
import UIKit
import XCTest

/// D10-3694 ③-B 自愿开启的实验：未登记 URL Types（Info.plist 里没有 couli）时，ASWebAuthenticationSession 以
/// `callbackURLScheme = "couli"` 能截获服务器 302 到 `couli://auth/taobao?…` 的回跳。
/// - 只在环境变量 `COULI_WEBAUTH_EXPERIMENT=1` 时运行（锁内用 `TEST_RUNNER_COULI_WEBAUTH_EXPERIMENT=1` 单独跑），否则 XCTSkip。
/// - `prefersEphemeralWebBrowserSession = true`（D10-3694）：避开系统「想要使用 … 登录」同意弹窗（单元测试宿主点不了
///   springboard），**只证截获、不证同意步**；生产仍是 false（D10-3567 ⑥）。
/// - 回跳页是本测试进程里的回环 HTTP 服务（127.0.0.1、随机端口，不访问外网）：首个请求回 302 Location 到 couli 回跳，其余 404。
///   会话页在 SafariViewService 里加载，App 的 ATS 不管它（Debug 另有 127.0.0.1 例外）。
/// - 不经授权器白名单：用例 1 直接用系统 ASWebAuthenticationSession（证系统行为，底座上即可绿）；用例 2 用底座的
///   `SystemWebAuthSessionLauncher`（证本仓端口，底座 start 返回 nil，今天红在「start 应返回句柄」）。
/// 每条用例等 completion 最多 `timeout` 秒。
@MainActor
final class WebAuthInterceptExperimentTests: XCTestCase {
    private static let timeout: TimeInterval = 30
    private static let code = "SIMcode_1"
    private static let state = "SIMstate_1"
    private static let callback = "couli://auth/taobao?code=\(code)&state=\(state)"

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["COULI_WEBAUTH_EXPERIMENT"] == "1" else {
            throw XCTSkip("D10-3694 实验用例：会弹系统授权会话，只在 COULI_WEBAUTH_EXPERIMENT=1 时运行")
        }
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        guard !schemes.contains("couli") else {
            throw XCTSkip("前提不成立：Info.plist 已登记 couli（\(schemes)），本实验不再能证明「未登记也能截获」")
        }
    }

    // MARK: - 用例

    /// 系统会话本身（不经本仓端口）：证截获机制。
    func testSystemSessionInterceptsCouliRedirectWithoutUrlTypes() async throws {
        let server = try ExperimentRedirectServer(location: Self.callback)
        try await server.start()
        defer { server.stop() }
        let anchor = ExperimentAnchorProvider()
        XCTAssertNotNil(anchor.keyWindow(), "宿主 App 要有 key window 作展示锚点")
        let box = ExperimentCompletionBox()
        let session = ASWebAuthenticationSession(
            url: try XCTUnwrap(server.startURL), callbackURLScheme: "couli"
        ) { url, error in
            box.set(url, error)
        }
        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = anchor
        XCTAssertTrue(session.start(), "系统会话 start 应返回 true（锚点、主线程）")
        let finished = await waitForCompletion(box)
        if !finished {
            session.cancel()
        }
        try assertIntercepted(box, server: server, finished: finished)
    }

    /// 本仓系统端口 `SystemWebAuthSessionLauncher`（实现后：建会话、设锚点与 ephemeral、start）：证同一截获走得通。
    func testSystemLauncherInterceptsCouliRedirect() async throws {
        let server = try ExperimentRedirectServer(location: Self.callback)
        try await server.start()
        defer { server.stop() }
        let launcher = SystemWebAuthSessionLauncher()
        let box = ExperimentCompletionBox()
        let started = launcher.start(
            url: try XCTUnwrap(server.startURL), callbackURLScheme: WebAuthSessionWebCodeAuthorizer.callbackURLScheme,
            prefersEphemeralWebBrowserSession: true
        ) { url, error in
            box.set(url, error)
        }
        let handle = try XCTUnwrap(started, "SystemWebAuthSessionLauncher.start 应返回会话句柄（底座返回 nil）")
        let finished = await waitForCompletion(box)
        if !finished {
            handle.cancel()
        }
        try assertIntercepted(box, server: server, finished: finished)
        withExtendedLifetime(launcher) {}
    }

    // MARK: - 辅助

    /// 每 50ms 看一次，最多 `timeout` 秒；返回是否已回调。
    private func waitForCompletion(_ box: ExperimentCompletionBox) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.timeout)
        while Date() < deadline {
            if box.value != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return box.value != nil
    }

    private func assertIntercepted(
        _ box: ExperimentCompletionBox, server: ExperimentRedirectServer, finished: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertTrue(finished, "completion 应在 \(Int(Self.timeout)) 秒内回调；回环服务收到：\(server.served)",
                      file: file, line: line)
        XCTAssertEqual(server.served.first, "/start", "会话页确实请求了回环服务", file: file, line: line)
        let (url, error) = try XCTUnwrap(box.value, "没有 completion", file: file, line: line)
        XCTAssertNil(error, "截获回跳时错误应为 nil：\(String(describing: error))", file: file, line: line)
        let got = try XCTUnwrap(url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) },
                                "completion 应带回跳地址", file: file, line: line)
        let sent = try XCTUnwrap(URLComponents(string: Self.callback))
        XCTAssertEqual(got.scheme, "couli", file: file, line: line)
        XCTAssertEqual(got.host, "auth", file: file, line: line)
        XCTAssertEqual(got.path, "/taobao", file: file, line: line)
        XCTAssertEqual(got.queryItems, sent.queryItems, "查询项与 302 Location 一致", file: file, line: line)
        XCTAssertEqual(got.queryItems?.first { $0.name == "code" }?.value, Self.code, file: file, line: line)
        XCTAssertEqual(got.queryItems?.first { $0.name == "state" }?.value, Self.state, file: file, line: line)
    }
}

/// 会话展示锚点：宿主 App 的 key window（仿 ThirdPartyAuth.swift 的 presentationAnchor）。
@MainActor
private final class ExperimentAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow)
    }

    nonisolated func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            keyWindow() ?? ASPresentationAnchor()
        }
    }
}

/// completion 的结果（系统可能在任意线程回调，加锁存取）。
private final class ExperimentCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (URL?, (any Error)?)?

    var value: (URL?, (any Error)?)? {
        lock.withLock { stored }
    }

    func set(_ url: URL?, _ error: (any Error)?) {
        lock.withLock {
            if stored == nil {
                stored = (url, error)
            }
        }
    }
}

/// 本机回环 HTTP 服务（Network.framework，127.0.0.1、随机端口）：首个请求回 302 到 `location`，其余 404。
private final class ExperimentRedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let location: String
    private let queue = DispatchQueue(label: "couli.test.webauth-experiment-server")
    private let lock = NSLock()
    private var paths: [String] = []
    private var readyResumed = false

    var served: [String] {
        lock.withLock { paths }
    }

    var startURL: URL? {
        listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)/start") }
    }

    init(location: String) throws {
        self.location = location
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready, .failed, .cancelled:
                    if self?.claimReady() ?? false {
                        continuation.resume()
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        guard (listener.port?.rawValue ?? 0) != 0 else {
            throw URLError(.cannotConnectToHost)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func claimReady() -> Bool {
        lock.withLock {
            defer { readyResumed = true }
            return !readyResumed
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let first = lock.withLock {
                paths.append(path)
                return paths.count == 1
            }
            let response = first
                ? "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
