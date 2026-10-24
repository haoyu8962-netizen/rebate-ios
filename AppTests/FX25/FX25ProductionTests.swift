import Combine
@testable import Couli
import CouliNetwork
import Foundation
import UIKit
@testable import Web
import WebKit
import XCTest

@MainActor
final class FX25ProductionTests: FX25TestCase {
    func testP01LogoutEventOnceAndEveryCleanupCompletesBeforeReload() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let page = try page(web, path: "/logout")
        try await loaded("/logout")
        try await seed(page.webView)
        let oldDocument = try XCTUnwrap(journal.documents("/logout").first?.document)
        let oldToken = page.methodsSync.token
        onNewView = { [weak self, probe, journal] view in
            guard let controller = view.navigationDelegate as? TrustedWebController else {
                return XCTFail("观察钩子应在生产导航代理装好之后、首次 load 之前调用")
            }
            let navigation = FX25NavigationProbe(controller)
            self?.navigationProbes.append(navigation)
            view.navigationDelegate = navigation
            navigation.admitted = {
                XCTAssertEqual(Set(probe.completed), Set(FX25CleanupProbe.kinds), "在导航准入时检查")
                XCTAssertEqual(journal.events("/logout").count, 1, "事件必须实际执行到旧文档")
                probe.trace.append("reload")
            }
        }
        onNewView?(page.webView)
        // 解除隔离与发起重新加载在产品的同一个同步步骤里（authRestore），比 WebKit 导航准入回调早；在这一刻核对清理已全部
        // 完成，本机 http 源下「先重载后清理」也逃不过（导航准入回调可能晚于假清理完成）。
        let isolation = page.$isAuthIsolated.sink { [probe] isolated in
            MainActor.assumeIsolated {
                if isolated {
                    probe.trace.append("isolate")
                } else if probe.trace.contains("isolate") {
                    XCTAssertEqual(Set(probe.completed), Set(FX25CleanupProbe.kinds), "解除隔离 / 发起重新加载时")
                    probe.trace.append("lift")
                }
            }
        }
        defer { isolation.cancel() }
        let ended = await app.login.logout()
        XCTAssertTrue(ended)
        await settled(web)
        try assertCleanupPrecedesReload(probe.trace)
        try await loaded("/logout", count: 2)
        try assertEvent("/logout", loggedIn: false)
        XCTAssertEqual(journal.events("/logout").first?.document, oldDocument)
        XCTAssertNotEqual(journal.documents("/logout").last?.document, oldDocument)
        XCTAssertNotEqual(page.methodsSync.token, oldToken)
        try assertStorage(journal.documents("/logout").last?.body["storage"], hasOld: false)
        XCTAssertEqual(probe.trace.filter { $0 == "reload" }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    /// 顺序：隔离 → 每项清理开始与完成 → 解除隔离（同步发起重新加载）→ 新导航准入；解除之后不得再有任何清理开始或完成。
    private func assertCleanupPrecedesReload(_ trace: [String]) throws {
        let isolate = try XCTUnwrap(trace.firstIndex(of: "isolate"), "\(trace)")
        let lift = try XCTUnwrap(trace.firstIndex(of: "lift"), "\(trace)")
        let reload = try XCTUnwrap(trace.firstIndex(of: "reload"), "\(trace)")
        let cleanup = trace.indices.filter { trace[$0].hasPrefix("begin:") || trace[$0].hasPrefix("done:") }
        XCTAssertFalse(cleanup.isEmpty, "\(trace)")
        XCTAssertTrue(cleanup.allSatisfy { isolate < $0 && $0 < lift }, "清理必须整段落在隔离与重新加载之间：\(trace)")
        XCTAssertLessThan(lift, reload, "\(trace)")
        XCTAssertEqual(trace.filter { $0 == "lift" }.count, 1, "\(trace)")
        for kind in FX25CleanupProbe.kinds {
            XCTAssertTrue(trace[..<lift].contains("done:\(kind)"), "\(kind) 未在重新加载前完成：\(trace)")
        }
    }

    func testP02AllMountedPagesIncludingCoveredAndBackgroundReceiveOneChange() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let front = try page(web, path: "/front")
        let covered = try page(web, path: "/under-login")
        let background = try page(web, path: "/background")
        for path in ["/front", "/under-login", "/background"] {
            try await loaded(path)
        }
        for controller in [front, covered, background] {
            try await seed(controller.webView)
        }
        covered.pageVisible(false)
        background.pageVisible(false)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await login(app)
        await settled(web)
        for path in ["/front", "/under-login", "/background"] {
            try await loaded(path, count: 2)
            try assertEvent(path, loggedIn: true)
            try assertStorage(journal.documents(path).last?.body["storage"], hasOld: false)
        }
        XCTAssertTrue([front, covered, background].allSatisfy { !$0.isAuthIsolated })
    }

    func testP03RealTokenRefreshRotatesBothTokensWithoutEventClearOrReload() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let controller = try page(web, path: "/refresh")
        try await loaded("/refresh")
        let identity = app.client.identitySnapshot(credentialsReadable: true)
        let old = try XCTUnwrap(app.tokens.readSession())
        // 10002 才是 token 过期；必须实际经过 refresh 管线，不直接改存储。
        script.on("GET /v1/me", .envelope(code: 10002, data: "null", headers: [:]),
                  .envelope(code: 0, data: MeSamples.me(), headers: [:]))
        script.ok("POST /v1/auth/refresh", """
        {"access_token":"at-rotated","refresh_token":"rt-rotated","session_scope":"full","expires_in":7200}
        """)
        let result = await app.client.send(ApiCall(operationId: "getMe"))
        guard case .success = result else { return XCTFail("刷新未成功：\(result)") }
        let new = try XCTUnwrap(app.tokens.readSession())
        XCTAssertNotEqual(new.access, old.access)
        XCTAssertNotEqual(new.refresh, old.refresh)
        XCTAssertEqual(app.client.identitySnapshot(credentialsReadable: true).mark, identity.mark)
        await settled(web)
        XCTAssertEqual(journal.documents("/refresh").count, 1)
        XCTAssertTrue(journal.events("/refresh").isEmpty)
        XCTAssertTrue(probe.entered.isEmpty)
        XCTAssertFalse(controller.isAuthIsolated)
    }

    func testP04SameUserNewEpochOnlyNotifiesAndDuplicateWakeDoesNotRepeat() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        _ = try page(web, path: "/same")
        try await loaded("/same")
        let oldEpoch = app.client.identitySnapshot(credentialsReadable: true).loginEpoch
        try await login(app, account: "user-a")
        XCTAssertNotEqual(app.client.identitySnapshot(credentialsReadable: true).loginEpoch, oldEpoch)
        await settled(web)
        app.routing.sessionStateChanged(resumePending: false)
        app.routing.sessionStateChanged(resumePending: false)
        await settled(web)
        try assertEvent("/same", loggedIn: true)
        XCTAssertEqual(journal.documents("/same").count, 1)
        XCTAssertTrue(probe.entered.isEmpty)
    }

    func testP06DisposedPageStopsObservingWhileLivePageContinues() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let disposed = try page(web, path: "/disposed")
        _ = try page(web, path: "/live")
        try await loaded("/disposed")
        try await loaded("/live")
        disposed.teardown()
        try await login(app)
        await settled(web)
        try assertEvent("/live", loggedIn: true)
        XCTAssertTrue(journal.events("/disposed").isEmpty)
        XCTAssertEqual(journal.documents("/disposed").count, 1)
    }

    func testP09CookieCallbackGatePreventsEarlyReload() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let controller = try page(web, path: "/cookie-gate")
        try await loaded("/cookie-gate")
        probe.held = .cookies
        try await login(app)
        try await until("未调用 Cookie 清理") { self.probe.entered.contains(.cookies) }
        XCTAssertTrue(controller.isAuthIsolated)
        XCTAssertEqual(journal.documents("/cookie-gate").count, 1)
        XCTAssertFalse(probe.completed.contains(.cookies))
        probe.release()
        await settled(web)
        try await loaded("/cookie-gate", count: 2)
        try assertEvent("/cookie-gate", loggedIn: true)
    }
}
