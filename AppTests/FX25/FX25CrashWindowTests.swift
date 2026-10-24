@testable import Couli
import Foundation
import Web
import WebKit
import XCTest

/// 评审 r1 S1-01：待清事务登记不是原子的。「重建进程」用同进程重建整套 ApiClient / AppWeb 模拟：
/// 只共享磁盘（待清标记目录、持久化可信 store），不调用旧协调器。
@MainActor
final class FX25CrashWindowTests: FX25TestCase {
    /// 新会话 user-b 已写盘、待清标记还没写（通知没送到协调器）时进程被杀：冷启动仍须先补清 user-a 的 Web 数据，
    /// 可信页面才能发出第一个请求；补清不是身份事件，不发 auth.changed。
    func testS1SessionSavedBeforePendingMarkStillClearsOldOwnerBeforeFirstColdLoad() async throws {
        try await prepare()
        try await seedPreviousProcess(path: "/before-crash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path), "前置：崩溃窗口里标记确实没写")
        let cold = make(account: "user-b")
        try await assertColdStartClearsFirst(cold, path: "/after-crash")
    }

    /// AppWeb 创建之前（启动对账、network.attach 之后）发出的清会话通知不能丢：随后创建的 AppWeb 仍要先补清旧数据。
    func testS1SessionClearedBeforeAppWebExistsIsNotLost() async throws {
        try await prepare()
        try await seedPreviousProcess(path: "/before-launch")
        let cold = make(account: "user-a")
        cold.client.signOut()
        XCTAssertNil(try cold.tokens.readSession(), "前置：会话已在 AppWeb 创建前清掉")
        try await assertColdStartClearsFirst(cold, path: "/after-early-clear")
    }

    /// 上一个「进程」：user-a 打开可信页面并写入四类数据，正常结算后页面关闭。
    private func seedPreviousProcess(path: String) async throws {
        let previous = make()
        let web = makeWeb(previous)
        let controller = try page(web, path: path)
        try await loaded(path)
        try await seed(controller.webView)
        await settled(web)
        controller.teardown()
        probe.resetCounts()
    }

    private func assertColdStartClearsFirst(_ cold: MeAppFixture, path: String) async throws {
        var requestsAtClear: [Int] = []
        probe.beforeClear = { [server] in
            requestsAtClear.append(server?.requests(path) ?? -1)
        }
        let web = makeWeb(cold)
        let controller = try page(web, path: path)
        let succeeded = try await outcome(web)
        XCTAssertTrue(succeeded, "冷启动补清必须成功结算")
        try await loaded(path)
        try assertStorage(journal.documents(path).first?.body["storage"], hasOld: false)
        XCTAssertEqual(Set(probe.completed), Set(FX25CleanupProbe.kinds), "冷启动必须先补清旧身份的数据：\(probe.trace)")
        XCTAssertFalse(requestsAtClear.isEmpty)
        XCTAssertTrue(requestsAtClear.allSatisfy { $0 == 0 }, "可信页面在补清之前就发出了请求：\(requestsAtClear)")
        XCTAssertTrue(journal.events(path).isEmpty, "补清不是身份事件")
        XCTAssertFalse(controller.isAuthIsolated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }
}
