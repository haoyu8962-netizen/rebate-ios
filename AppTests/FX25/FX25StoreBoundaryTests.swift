@testable import Couli
import Foundation
import Web
import WebKit
import XCTest

@MainActor
final class FX25StoreBoundaryTests: FX25TestCase {
    func testI6TrustedCleanupPreservesSimultaneouslyOpenExternalPage() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let trusted = try page(web, path: "/trusted-with-external")
        let external = web.makeExternalController(url: nil, onClose: {})
        defer { external.teardown() }
        let view = external.webView
        journal.install(view)
        host(view)
        let delegate = view.navigationDelegate
        view.navigationDelegate = nil
        view.load(URLRequest(url: try XCTUnwrap(URL(string: server.origin + "/external-with-trusted"))))
        try await loaded("/trusted-with-external")
        try await loaded("/external-with-trusted")
        view.navigationDelegate = delegate
        try await seed(trusted.webView)
        try await seed(view)
        try await login(app)
        await settled(web)
        try await loaded("/trusted-with-external", count: 2)
        try assertStorage(journal.documents("/trusted-with-external").last?.body["storage"], hasOld: false)
        let remaining = try await view.callAsyncJavaScript(
            "return await window.fx25.read();", arguments: [:], in: nil, contentWorld: .page
        )
        try assertStorage(remaining, hasOld: true)
        XCTAssertEqual(journal.documents("/external-with-trusted").count, 1)
        XCTAssertTrue(journal.events("/external-with-trusted").isEmpty)
        XCTAssertTrue(probe.stores.allSatisfy { $0 === self.store })
    }

    func testI3CorruptPendingRecordCannotBeTreatedAsClean() async throws {
        try await prepare()
        try Data("not-a-valid-pending-record".utf8).write(to: pending)
        let app = make(account: "user-b")
        let web = makeWeb(app)
        let controller = try page(web, path: "/corrupt-pending")
        probe.fault = (.cookies, .unconfirmed)
        await settled(web, succeeds: false)
        XCTAssertEqual(server.requests("/corrupt-pending"), 0)
        XCTAssertTrue(controller.loadFailed)
        XCTAssertTrue(controller.isAuthIsolated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
    }

    func testR102HistorySessionStorageCannotReturnAfterAccountSwitch() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app, useRealCleaner: true)
        let controller = try page(web, path: "/history-a")
        try await loaded("/history-a")
        try await seed(controller.webView)
        controller.webView.load(URLRequest(url: try XCTUnwrap(URL(string: server.origin + "/history-b"))))
        try await loaded("/history-b")
        try await login(app)
        await settled(web)
        // 恢复必须仍为当前入口 /history-b（不能退回 initialURL 的 /history-a）。
        try await loaded("/history-b", count: 2)
        try assertStorage(journal.documents("/history-b").last?.body["storage"], hasOld: false)
        if controller.webView.canGoBack {
            // 允许产品清空历史；若保留历史，真正恢复后的旧源也不能带回旧 sessionStorage。
            let before = journal.entries.filter { $0.kind == "shown" }.count
            controller.webView.goBack()
            try await until("后退没有结算到文档") {
                self.journal.entries.filter { $0.kind == "shown" }.count > before
            }
            let value = try await controller.webView.callAsyncJavaScript(
                "return await window.fx25.read();", arguments: [:], in: nil, contentWorld: .page
            )
            try assertStorage(value, hasOld: false)
        }
    }
}
