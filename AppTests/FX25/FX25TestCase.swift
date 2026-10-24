import BridgeHost
import ClientCore
@testable import Couli
import CouliNetwork
import Foundation
import UIKit
import Web
import WebKit
import XCTest

/// 真实 AppWeb / ApiClient / WKWebView 组合。测试不订阅身份、不发身份事件、不手补 reload。
@MainActor
class FX25TestCase: MeTestCase {
    var server: FX25PageServer!
    var probe = FX25CleanupProbe()
    var journal = FX25WebJournal()
    var controllers: [TrustedWebController] = []
    var windows: [UIWindow] = []
    var webs: [AppWeb] = []
    var navigationProbes: [FX25NavigationProbe] = []
    var onNewView: ((WKWebView) -> Void)?
    /// 与生产一致的可信专用 store：iOS 17+ 为按标识的持久化独立 store（每个用例一个新标识，互不串数据）；WebKit 对非持久
    /// store 不开 HTTP 缓存，用非持久 store 证明不了「旧缓存被清掉」。iOS 16 生产同样退回非持久（见 TrustedWebDataStore）。
    let storeIdentifier: UUID? = FX25TestCase.persistentStoresAvailable ? UUID() : nil
    lazy var store: WKWebsiteDataStore = {
        if #available(iOS 17.0, *), let storeIdentifier {
            return WKWebsiteDataStore(forIdentifier: storeIdentifier)
        }
        return .nonPersistent()
    }()

    nonisolated static var persistentStoresAvailable: Bool {
        if #available(iOS 17.0, *) {
            return true
        }
        return false
    }

    var pending: URL {
        MeAppFixture.localDirectory(suiteName).appendingPathComponent("web-pending.json")
    }

    /// 在测试体开始后调用，确保 MeTestCase.setUpWithError 已建好 suiteName / 假服务。
    func prepare() async throws {
        let html = "<!doctype html><title>F-X-25</title><script>" + FX25WebJournal.source + "</script>"
        server = try FX25PageServer(page: html)
        try await server.start()
        try FileManager.default.createDirectory(
            at: pending.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        probe.pendingFile = pending
    }

    override func tearDown() async throws {
        probe.release()
        controllers.forEach { $0.teardown() }
        windows.forEach { $0.isHidden = true }
        windows = []
        navigationProbes = []
        onNewView = nil
        controllers = []
        webs = []
        server?.stop()
        await removeFixtureStore()
        try await super.tearDown()
    }

    /// 用例自建的持久 store 用完即清：先删数据，再尽力删掉按标识的目录（仍被退役 WebView 引用时删不掉，不影响结论）。
    private func removeFixtureStore() async {
        guard let storeIdentifier else { return }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        if #available(iOS 17.0, *) {
            try? await WKWebsiteDataStore.remove(forIdentifier: storeIdentifier)
        }
    }

    func makeWeb(
        _ app: MeAppFixture,
        timeout: TimeInterval = 30,
        useRealCleaner: Bool = false,
        productionDefaults: Bool = false
    ) -> AppWeb {
        let directory = MeAppFixture.localDirectory(suiteName)
        let tracker = AppTracker(
            privacy: app.routing.privacy, update: app.update, network: app.network,
            environmentReady: { true }, credentialsReadable: { app.runner.credentialsReadable },
            file: ClientFile(name: "fx25-tracker.json", baseDirectory: directory),
            withdrawalRegistry: app.withdrawal, environmentRegistry: app.environmentSwitch
        )
        var auth = TrustedWebAuthDependencies(dataStore: store, pendingFile: pending)
        auth.cleanupTimeout = timeout
        auth.configureWebView = { [weak self, journal] view in
            journal.install(view)
            self?.onNewView?(view)
        }
        if !useRealCleaner {
            auth.clear = { [probe] kind, store, documents in
                try await probe.clear(kind, store: store, documents: documents)
            }
        }
        let web = AppWeb(
            config: app.config, network: app.network, routing: app.routing, privacy: app.routing.privacy,
            update: app.update, tracker: tracker,
            permissions: AppPermissions(file: ClientFile(name: "fx25-permissions.json", baseDirectory: directory)),
            withdrawalRegistry: app.withdrawal, environmentRegistry: app.environmentSwitch,
            auth: productionDefaults ? nil : auth
        )
        webs.append(web)
        return web
    }

    func page(_ web: AppWeb, path: String, start: Bool = true) throws -> TrustedWebController {
        let origin = server.origin
        let controller = web.makeTrustedController(
            url: try XCTUnwrap(URL(string: origin + path)),
            protocolProvider: {
                BridgeProtocol(trustedOrigins: [], linkPatterns: [:], shareDomains: [],
                               extraOriginAllowed: { $0 == origin })
            },
            caller: { web.callerState(fromForceUpdatePage: false) }, onClose: {}
        )
        controllers.append(controller)
        host(controller.webView)
        if start {
            controller.start()
        }
        return controller
    }

    func host(_ view: WKWebView) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        window.frame = UIScreen.main.bounds
        let root = UIViewController()
        window.rootViewController = root
        view.frame = root.view.bounds
        root.view.addSubview(view)
        window.isHidden = false
        windows.append(window)
    }

    func loaded(_ path: String, count: Int = 1) async throws {
        try await until("没有加载新文档 \(path)") { self.journal.documents(path).count >= count }
        XCTAssertEqual(journal.documents(path).count, count)
        XCTAssertFalse(journal.entries.contains { $0.path == path && $0.kind == "error" })
    }

    func until(_ message: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail(message)
                throw URLError(.timedOut)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func settled(_ web: AppWeb, succeeds: Bool = true) async {
        let done = expectation(description: "只观察生产队列的结算，不能靠查询触发处理")
        let task = Task { @MainActor in
            let result = await web.whenAuthSettled()
            XCTAssertEqual(result, succeeds)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        task.cancel()
    }

    /// 只观察结算结果（成功 / 失败都接受），由用例自己判断；超时视为没有结算。
    func outcome(_ web: AppWeb, timeout: TimeInterval = 20) async throws -> Bool {
        let box = FX25Box<Bool>()
        let task = Task { @MainActor in
            box.value = await web.whenAuthSettled()
        }
        defer { task.cancel() }
        try await until("切号事务没有结算", timeout: timeout) { box.value != nil }
        return try XCTUnwrap(box.value)
    }

    func login(_ app: MeAppFixture, account: String = "user-b") async throws {
        script.ok("POST /v1/auth/login/sms", MeSamples.json([
            "user_id": account, "tokens": ["access_token": "at-new-\(account)",
                                           "refresh_token": "rt-new-\(account)",
                                           "session_scope": "full", "expires_in": 7200],
        ]))
        let result = await app.client.send(ApiCall(operationId: "loginBySms", body:
            #"{"phone":"13800138000","code":"123456","scene":"login"}"#))
        guard case .success = result else { return XCTFail("真实登录未成功：\(result)") }
        XCTAssertEqual(app.client.isolatedAccount, account)
        XCTAssertEqual(app.tokens.accessToken, "at-new-\(account)")
    }

    func seed(_ view: WKWebView) async throws {
        let result = try await view.callAsyncJavaScript(
            FX25WebJournal.seed,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        try assertStorage(result, hasOld: true)
    }

    func assertStorage(_ value: Any?, hasOld: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let storage = try XCTUnwrap(value as? [String: Any], file: file, line: line)
        for key in ["local", "session", "indexed"] {
            if hasOld {
                XCTAssertEqual(storage[key] as? String, "user-a", key, file: file, line: line)
            } else {
                XCTAssertTrue(storage[key] is NSNull, "\(key)：\(storage)", file: file, line: line)
            }
        }
        XCTAssertEqual(storage["cookie"] as? Bool, hasOld, file: file, line: line)
    }

    func assertEvent(_ path: String, loggedIn: Bool, count: Int = 1) throws {
        let events = journal.events(path)
        XCTAssertEqual(events.count, count, path)
        for entry in events {
            let event = try XCTUnwrap(entry.body["event"] as? [String: Any])
            XCTAssertEqual(event["event"] as? String, "auth.changed")
            let payload = try XCTUnwrap(event["data"] as? [String: Any])
            XCTAssertEqual(Set(payload.keys), ["logged_in"])
            XCTAssertEqual(payload["logged_in"] as? Bool, loggedIn)
        }
    }
}

@MainActor
final class FX25Box<Value> {
    var value: Value?
}
