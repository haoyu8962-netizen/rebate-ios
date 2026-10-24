import Config
@testable import Couli
import CouliNetwork
import Foundation
import Privacy
import UIKit
import Web
import XCTest

@MainActor
final class FX25ExplicitClearTests: FX25TestCase {
    func testI5R105EnvironmentSwitchRegistersPendingWithCredentialGateClosed() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let controller = try page(web, path: "/environment")
        try await loaded("/environment")
        probe.fault = (.cookies, .throwing)
        app.client.raiseWithdrawalReadBarriers()
        let reads = app.store.reads
        XCTAssertFalse(app.client.identitySnapshot(credentialsReadable: false).known)
        try app.routing.environment.switchTo(.staging)
        XCTAssertEqual(app.store.reads, reads, "切环境同步清理链不可重新读凭据判定是否需要清 Web")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path), "恢复环境准入前必须已登记")
        await settled(web, succeeds: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertTrue(controller.isAuthIsolated)
        XCTAssertEqual(journal.documents("/environment").count, 1)
        try assertEvent("/environment", loggedIn: false)
    }

    func testI5ConsentWithdrawalRegistersPendingWithoutReadingCredentials() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let controller = try page(web, path: "/withdraw")
        try await loaded("/withdraw")
        probe.fault = (.cookies, .throwing)
        app.client.raiseWithdrawalReadBarriers()
        let reads = app.store.reads
        app.routing.privacy.withdraw()
        await settled(web, succeeds: false)
        XCTAssertEqual(app.store.reads, reads)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertTrue(controller.isAuthIsolated)
        try assertEvent("/withdraw", loggedIn: false)
    }

    func testI5ExplicitSignOutIncludingAccountDeletionTerminalNeedsNoIdentityRead() async throws {
        try await prepare()
        let app = make()
        // 本端尚无原生注销提交；明确清会话终点按 signOut 覆盖，不能冒称已测注销 UI。
        app.store.failReads(fromNth: 1)
        let web = makeWeb(app)
        let controller = try page(web, path: "/unknown-clear", start: false)
        app.client.raiseWithdrawalReadBarriers()
        let reads = app.store.reads
        probe.fault = (.cookies, .throwing)
        app.client.signOut()
        await settled(web, succeeds: false)
        XCTAssertEqual(app.store.reads, reads)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        controller.start()
        XCTAssertTrue(controller.isAuthIsolated)
        XCTAssertEqual(server.requests("/unknown-clear"), 0)
        app.store.stopFailing()
    }

    func testI510404RecordsPendingEvenWhenLaterIdentityReadsFail() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let controller = try page(web, path: "/expired")
        try await loaded("/expired")
        script.on("GET /v1/me", .hold)
        let call = Task { await app.client.send(ApiCall(operationId: "getMe")) }
        try await until("请求没有进入网络端口") { !WalletStubProtocol.heldIds.isEmpty }
        let request = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        app.store.failReads(fromNth: 1)
        probe.fault = (.cookies, .throwing)
        WalletStubProtocol.release(request, with: .envelope(code: 10404, data: "null", headers: [:]))
        let result = await call.value
        guard case let .failure(code, _, _, _, effect, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(code, 10404)
        XCTAssertEqual(effect.kind, .clearSessionLogin)
        await settled(web, succeeds: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertTrue(controller.isAuthIsolated)
        try assertEvent("/expired", loggedIn: false)
        app.store.stopFailing()
    }

    func testI7UnknownSnapshotDoesNotLogoutAndRecoveryStillComparesLastKnownIdentity() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        _ = try page(web, path: "/unreadable")
        try await loaded("/unreadable")
        app.store.failReads(fromNth: 1)
        app.routing.sessionStateChanged(resumePending: false)
        await settled(web)
        XCTAssertTrue(journal.events("/unreadable").isEmpty)
        XCTAssertTrue(probe.entered.isEmpty)
        app.store.stopFailing()
        try await login(app)
        await settled(web)
        try assertEvent("/unreadable", loggedIn: true)
        try await loaded("/unreadable", count: 2)
    }

    func testI7ColdIdentityConfirmationSendsNoEventAndDoesNotClearCleanStore() async throws {
        try await prepare()
        for account in [nil, "user-a"] as [String?] {
            // 每一轮都是一次全新安装的冷启动：上一轮留下的待清 / 归属 / store 登记文件不能带进来（r2 起有归属记录时身份未知会补清）。
            try forgetPreviousInstall()
            let app = make(account: account)
            app.store.failReads(fromNth: 1)
            let web = makeWeb(app)
            let path = account == nil ? "/cold-guest" : "/cold-member"
            _ = try page(web, path: path)
            app.store.stopFailing()
            app.routing.sessionStateChanged(resumePending: false)
            NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
            await settled(web)
            try await loaded(path)
            XCTAssertTrue(journal.events(path).isEmpty)
            XCTAssertTrue(probe.entered.isEmpty)
        }
    }

    /// 删掉待清标记目录里上一次「安装」留下的可信 Web 记录（待清标记、归属记录、store 登记等 `trusted-web*`）。
    private func forgetPreviousInstall() throws {
        let directory = pending.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: pending)
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
            where name.hasPrefix("trusted-web") {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
