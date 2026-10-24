@testable import Couli
import Foundation
@testable import Web
import WebKit
import XCTest

/// E01：真实 WKWebView + 真实系统清理 + 本机 HTTP 服务 + 真实 ApiClient 换号。
@MainActor
final class FX25DeviceTests: FX25TestCase {
    func testE01RealCookieDOMSessionAndIndexedDBDisappearInTheFirstNewDocument() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app, useRealCleaner: true)
        let controller = try page(web, path: "/device")
        try await loaded("/device")
        try await seed(controller.webView)
        let oldDocument = try XCTUnwrap(journal.documents("/device").first?.document)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "fx25-http-only", .value: "user-a", .domain: "127.0.0.1", .path: "/",
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ]))
        await store.httpCookieStore.setCookie(cookie)
        let seededCookies = await store.httpCookieStore.allCookies()
        XCTAssertTrue(seededCookies.contains { $0.name == "fx25-http-only" && $0.value == "user-a" })
        try await login(app)
        await settled(web)
        try await loaded("/device", count: 2)
        let firstNew = journal.documents("/device")[1]
        XCTAssertNotEqual(firstNew.document, oldDocument)
        try assertStorage(firstNew.body["storage"], hasOld: false)
        try assertEvent("/device", loggedIn: true)
        XCTAssertEqual(journal.events("/device").first?.document, oldDocument)
        let cookies = await store.httpCookieStore.allCookies()
        XCTAssertFalse(cookies.contains { $0.name.hasPrefix("fx25") })
        XCTAssertFalse(controller.isAuthIsolated)
        XCTAssertTrue(probe.entered.isEmpty, "E01 必须完全使用产品默认清理端口")
    }

    /// 「不清 sessionStorage」不能只靠换新 WebView 掩盖：旧 WKWebView（同一个浏览上下文、同一 sessionStorage 命名空间）
    /// 在清理完成后重新进入同源，也必须读不到旧 sessionStorage——证明系统清理真的作用到了 sessionStorage。
    func testE03SessionStorageIsClearedInTheOldBrowsingContextNotOnlyMaskedByANewView() async throws {
        XCTAssertEqual(TrustedWebDataCleaner.removalTypes(.sessionStorage), [WKWebsiteDataTypeSessionStorage])
        XCTAssertEqual(TrustedWebDataCleaner.confirmationTypes(.sessionStorage), [WKWebsiteDataTypeSessionStorage])
        try await prepare()
        let app = make()
        let web = makeWeb(app, useRealCleaner: true)
        let controller = try page(web, path: "/session-context")
        try await loaded("/session-context")
        let oldView = controller.webView
        try await seed(oldView)
        try await login(app)
        await settled(web)
        try await loaded("/session-context", count: 2)
        try assertStorage(journal.documents("/session-context").last?.body["storage"], hasOld: false)
        try XCTSkipIf(controller.webView === oldView, "产品未换 WebView 时，上面的新文档读取已在同一浏览上下文里完成")
        // 旧 WebView 已退役（摘桥、空白页）；只为取证恢复观察通道并回到同源，不经过产品容器。
        oldView.navigationDelegate = nil
        journal.install(oldView)
        host(oldView)
        oldView.load(URLRequest(url: try XCTUnwrap(URL(string: server.origin + "/session-context-old"))))
        try await loaded("/session-context-old")
        let storage = try XCTUnwrap(journal.documents("/session-context-old").first?.body["storage"] as? [String: Any])
        XCTAssertTrue(storage["session"] is NSNull, "旧浏览上下文仍读到 sessionStorage：\(storage)")
        try assertStorage(storage, hasOld: false)
        XCTAssertTrue(probe.entered.isEmpty, "E03 必须完全使用产品默认清理端口")
    }

    func testI6R106OnlyExternalOpenAndDefaultStoreRetainStorageAndHTTPResponses() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let (external, defaultView) = try await openExternalAndDefault(web)
        defer { external.teardown() }
        for view in [external.webView, defaultView] {
            try await seed(view)
        }
        // 外部容器按 APP-04 是非持久 store，WebKit 不给它开 HTTP 缓存：不拿缓存做证明，改为核对它独立 store 里的
        // 其他数据（原生写入的 HttpOnly Cookie、全部站点数据记录）在清理后原样还在，且清理端口从未拿到它。
        let externalStore = external.webView.configuration.websiteDataStore
        XCTAssertFalse(externalStore === store)
        let marker = try XCTUnwrap(HTTPCookie(properties: [
            .name: "fx25-external-only", .value: "user-a", .domain: "127.0.0.1", .path: "/",
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ]))
        await externalStore.httpCookieStore.setCookie(marker)
        let externalBefore = await records(externalStore)
        XCTAssertTrue(externalBefore.contains { $0.type == WKWebsiteDataTypeCookies }, "\(externalBefore)")
        XCTAssertTrue(externalBefore.contains { $0.type == WKWebsiteDataTypeLocalStorage }, "\(externalBefore)")
        // default 是持久 store，有 HTTP 缓存：先证明缓存真的命中。
        try await fetchCached(defaultView, path: "/fx25-cache-default")
        let warmed = server.requests("/fx25-cache-default")
        XCTAssertGreaterThan(warmed, 0)
        try await fetchCached(defaultView, path: "/fx25-cache-default")
        XCTAssertEqual(server.requests("/fx25-cache-default"), warmed, "先证明 default 的缓存真的命中")
        app.client.signOut()
        await settled(web)
        XCTAssertFalse(probe.entered.isEmpty, "没有可信页面也不能漏登记/补清")
        XCTAssertTrue(probe.stores.allSatisfy { $0 === self.store })
        XCTAssertFalse(probe.stores.contains { $0 === externalStore || $0 === WKWebsiteDataStore.default() })
        for view in [external.webView, defaultView] {
            let value = try await view.callAsyncJavaScript(
                "return await window.fx25.read();", arguments: [:], in: nil, contentWorld: .page
            )
            try assertStorage(value, hasOld: true)
        }
        try await fetchCached(defaultView, path: "/fx25-cache-default")
        XCTAssertEqual(server.requests("/fx25-cache-default"), warmed, "default 的 HTTP 缓存不能被可信清理波及")
        let externalCookies = await externalStore.httpCookieStore.allCookies()
        XCTAssertTrue(externalCookies.contains { $0.name == "fx25-external-only" && $0.value == "user-a" })
        let externalAfter = await records(externalStore)
        XCTAssertTrue(externalBefore.isSubset(of: externalAfter), "外部 store 数据被动过：\(externalBefore) → \(externalAfter)")
        XCTAssertEqual(journal.documents("/external").count, 1)
        XCTAssertEqual(journal.documents("/default").count, 1)
    }

    func testI6TrustedStoreIsIndependentOfDefaultAndExternalStore() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app, productionDefaults: true)
        let trusted = try page(web, path: "/store", start: false)
        let external = web.makeExternalController(url: nil, onClose: {})
        defer { external.teardown() }
        XCTAssertFalse(trusted.webView.configuration.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertFalse(trusted.webView.configuration.websiteDataStore === external.webView.configuration
            .websiteDataStore)
    }

    func testE02RealTrustedHTTPCacheIsRemovedBeforeTheNextDocumentUsesIt() async throws {
        try XCTSkipUnless(Self.persistentStoresAvailable, "iOS 16 的可信 store 是非持久的，WebKit 不开 HTTP 缓存")
        try await prepare()
        let app = make()
        let web = makeWeb(app, useRealCleaner: true)
        let controller = try page(web, path: "/trusted-cache")
        try await loaded("/trusted-cache")
        try await fetchCached(controller.webView)
        let warmed = server.requests("/fx25-cache")
        XCTAssertGreaterThan(warmed, 0)
        try await fetchCached(controller.webView)
        XCTAssertEqual(server.requests("/fx25-cache"), warmed, "先证明旧缓存存在")
        try await login(app)
        await settled(web)
        try await loaded("/trusted-cache", count: 2)
        try await fetchCached(controller.webView)
        XCTAssertGreaterThan(server.requests("/fx25-cache"), warmed, "新账号必须重新取 HTTP 内容")
    }

    /// 外部容器策略拒绝 http；载入时临时取消导航代理，载入后还原生产策略。default 视图直接用系统默认 store。
    private func openExternalAndDefault(_ web: AppWeb) async throws -> (ExternalWebController, WKWebView) {
        let url = try XCTUnwrap(URL(string: server.origin + "/external"))
        let external = web.makeExternalController(url: url, onClose: {})
        journal.install(external.webView)
        host(external.webView)
        let externalDelegate = external.webView.navigationDelegate
        external.webView.navigationDelegate = nil
        external.webView.load(URLRequest(url: url))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let defaultView = WKWebView(frame: .zero, configuration: config)
        journal.install(defaultView)
        host(defaultView)
        defaultView.load(URLRequest(url: try XCTUnwrap(URL(string: server.origin + "/default"))))
        try await loaded("/external")
        try await loaded("/default")
        external.webView.navigationDelegate = externalDelegate
        return (external, defaultView)
    }

    private func fetchCached(_ view: WKWebView, path: String = "/fx25-cache") async throws {
        let value = try await view.callAsyncJavaScript(
            "return (await fetch(path, {cache: 'force-cache'})).status;",
            arguments: ["path": path], in: nil, contentWorld: .page
        )
        XCTAssertEqual(value as? Int, 200)
    }

    private struct Record: Hashable {
        let site: String
        let type: String
    }

    private func records(_ store: WKWebsiteDataStore) async -> Set<Record> {
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        return Set(records.flatMap { record in record.dataTypes.map { Record(site: record.displayName, type: $0) } })
    }
}
