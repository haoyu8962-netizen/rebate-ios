import Foundation
import Network
import WebKit
import XCTest

/// 能力核对（cross-platform-rulings「拦不到子框架重定向时」，03 §5.6）：WKWebView 对子框架的每一跳（含服务器重定向）都会
/// 再调一次 `decidePolicyFor navigationAction`。用本机回环 HTTP 服务（只在测试进程里、端口随机，Debug 的 ATS 例外允许
/// 127.0.0.1）实测：子框架地址 /hop1 → 302 /hop2 → 302 /final，三跳都以子框架身份进入导航判定回调。
/// ExternalWebController 的子框架判定就挂在同一个回调上，所以每一跳都过统一判定。
@MainActor
final class SubframeRedirectProbeTests: WebViewTestCase {
    func testEverySubframeRedirectHopReachesNavigationPolicy() async throws {
        let server = try LoopbackRedirectServer()
        try await server.start()
        defer { server.stop() }
        let recorder = PolicyRecorder()
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = recorder
        host(webView)
        let base = "http://127.0.0.1:\(server.port)"
        webView.load(URLRequest(url: try XCTUnwrap(URL(string: base + "/parent"))))
        // FU-IOS-0712（F-IOS-01 偶发）：导航判定回调先于对应请求到达服务端——只等到回调里出现 /final 就核对 `served`，服务端还没收到
        // /final 时会偶发失败。改为等流程的两个终点都到：判定回调记下 /final、服务端也已回应 /final。上限 30 秒只用来判失败。
        try await waitUntil(timeout: 30) {
            recorder.subframePaths.contains("/final") && server.served.contains("/final")
        }
        XCTAssertEqual(recorder.subframePaths, ["/hop1", "/hop2", "/final"], "子框架的每一跳都进入导航判定回调")
        XCTAssertEqual(recorder.mainPaths, ["/parent"])
        XCTAssertEqual(server.served, ["/parent", "/hop1", "/hop2", "/final"])
    }
}

/// 只记录导航判定回调（全部放行）。
@MainActor
private final class PolicyRecorder: NSObject, WKNavigationDelegate {
    var subframePaths: [String] = []
    var mainPaths: [String] = []

    func webView(
        _: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let path = action.request.url?.path ?? ""
        if action.targetFrame?.isMainFrame == false {
            subframePaths.append(path)
        } else {
            mainPaths.append(path)
        }
        decisionHandler(.allow)
    }
}

/// 本机回环 HTTP 服务（Network.framework），只回应四个固定路径。
private final class LoopbackRedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "couli.test.redirect-server")
    private let lock = NSLock()
    private var paths: [String] = []

    var served: [String] {
        lock.withLock { paths }
    }

    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    if once.claim() {
                        continuation.resume()
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        guard port != 0 else {
            throw URLError(.cannotConnectToHost)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            lock.withLock { paths.append(path) }
            connection.send(content: Data(Self.response(path).utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static func response(_ path: String) -> String {
        switch path {
        case "/parent":
            page("<p>parent</p><iframe src=\"/hop1\"></iframe>")
        case "/hop1":
            redirect("/hop2")
        case "/hop2":
            redirect("/final")
        default:
            page("<p>final</p>")
        }
    }

    private static func redirect(_ location: String) -> String {
        "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    }

    private static func page(_ body: String) -> String {
        let html = "<!doctype html><html><body>\(body)</body></html>"
        return "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\n"
            + "Connection: close\r\n\r\n" + html
    }
}

/// 只放行第一次。
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
