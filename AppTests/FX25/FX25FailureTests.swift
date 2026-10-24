@testable import Couli
import Foundation
import Web
import XCTest

@MainActor
final class FX25FailureTests: FX25TestCase {
    /// R1-02/R1-07：五类独立端口，包含 sessionStorage 专项；每种故障在首次、恢复后的第二次分别发生。
    func testI2EveryStorageFailureUnconfirmedAndTimeoutIsAnOverallFailure() async throws {
        try await prepare()
        for kind in FX25CleanupProbe.kinds {
            for mode in FX25CleanupProbe.Fault.allCases {
                let app = make()
                let web = makeWeb(app, timeout: mode == .timeout ? 0.2 : 30)
                let path = "/fault-\(kind)-\(mode)"
                let controller = try page(web, path: path)
                try await loaded(path)
                for attempt in 1...2 {
                    try await seed(controller.webView)
                    probe.fault = (kind, mode)
                    let documents = journal.documents(path).count
                    let calls = probe.entered.filter { $0 == kind }.count
                    try await login(app, account: "fault-\(attempt)-\(kind)-\(mode)")
                    await settled(web, succeeds: false)
                    XCTAssertGreaterThan(probe.entered.filter { $0 == kind }.count, calls, "故障必须实际命中端口")
                    XCTAssertTrue(controller.isAuthIsolated, "\(kind) \(mode) 第 \(attempt) 次")
                    XCTAssertTrue(controller.loadFailed)
                    XCTAssertEqual(journal.documents(path).count, documents)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
                    // 超时后的迟到成功不能翻转已失败事务或偷偷重载。
                    probe.release()
                    await settled(web, succeeds: false)
                    XCTAssertEqual(journal.documents(path).count, documents)
                    XCTAssertTrue(controller.isAuthIsolated)
                    probe.fault = nil
                    controller.retry()
                    await settled(web)
                    try await loaded(path, count: documents + 1)
                    XCTAssertFalse(controller.isAuthIsolated)
                    try assertStorage(journal.documents(path).last?.body["storage"], hasOld: false)
                }
                controller.teardown()
                probe.resetCounts()
            }
        }
    }

    func testI4R103PagesOpenedDuringCleanupAndFailureRecoverTogether() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let first = try page(web, path: "/existing")
        try await loaded("/existing")
        probe.held = .cookies
        probe.fault = (.cookies, .throwing)
        try await login(app)
        try await until("清理没开始") { self.probe.entered.contains(.cookies) }
        let during = try page(web, path: "/opened-during")
        XCTAssertTrue(during.isAuthIsolated)
        XCTAssertNil(during.webView.url)
        probe.release()
        await settled(web, succeeds: false)
        let failed = try page(web, path: "/opened-after-failure")
        XCTAssertTrue(failed.isAuthIsolated)
        XCTAssertTrue(failed.loadFailed)
        XCTAssertEqual(server.requests("/opened-during"), 0)
        XCTAssertEqual(server.requests("/opened-after-failure"), 0)
        probe.fault = nil
        failed.retry() // 只点新页重试，必须同时恢复旧页与清理中加入的页。
        await settled(web)
        try await loaded("/existing", count: 2)
        try await loaded("/opened-during")
        try await loaded("/opened-after-failure")
        XCTAssertTrue([first, during, failed].allSatisfy { !$0.isAuthIsolated })
        try assertEvent("/existing", loggedIn: true)
        XCTAssertTrue(journal.events("/opened-during").isEmpty, "还没有旧文档的新页不伪造事件")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testI3R104PersistentPendingSurvivesRecreationAndColdFailureHasRetry() async throws {
        try await prepare()
        let firstApp = make()
        let firstWeb = makeWeb(firstApp)
        let first = try page(firstWeb, path: "/before-restart")
        try await loaded("/before-restart")
        try await seed(first.webView)
        probe.fault = (.indexedDB, .throwing)
        try await login(firstApp)
        await settled(firstWeb, succeeds: false)
        let bytes = try Data(contentsOf: pending)
        XCTAssertFalse(bytes.isEmpty)
        XCTAssertEqual(firstWeb.pendingAuthClearOwner?.account, "user-a", "持久事务归属旧身份")
        first.teardown()
        // 换整套 ApiClient / AppWeb；只共享磁盘标记与 WK 数据存储，不调用旧 coordinator。
        let secondApp = make(account: "user-b")
        let secondWeb = makeWeb(secondApp)
        let second = try page(secondWeb, path: "/after-restart")
        await settled(secondWeb, succeeds: false)
        XCTAssertEqual(secondWeb.pendingAuthClearOwner?.account, "user-a")
        XCTAssertEqual(server.requests("/after-restart"), 0)
        XCTAssertTrue(second.isAuthIsolated)
        XCTAssertTrue(second.loadFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        probe.fault = nil
        second.retry()
        await settled(secondWeb)
        try await loaded("/after-restart")
        try assertStorage(journal.documents("/after-restart").last?.body["storage"], hasOld: false)
        XCTAssertTrue(journal.events("/after-restart").isEmpty, "补清不等于冷启动身份事件")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testI3PendingWriteFailureBlocksEveryPageBeforeAnyCleanupOrReload() async throws {
        try await prepare()
        // 把标记父目录替换为普通文件：真实持久写必败，不伪造一个总返回成功的标记后端。
        let app = make()
        let web = makeWeb(app)
        let controller = try page(web, path: "/mark-failed")
        try await loaded("/mark-failed")
        let directory = pending.deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try Data("not-a-directory".utf8).write(to: directory)
        try await login(app)
        await settled(web, succeeds: false)
        XCTAssertTrue(controller.isAuthIsolated)
        XCTAssertTrue(controller.loadFailed)
        XCTAssertTrue(probe.entered.isEmpty)
        XCTAssertEqual(journal.documents("/mark-failed").count, 1)
    }
}
