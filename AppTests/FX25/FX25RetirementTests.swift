import Combine
@testable import Couli
import Foundation
@testable import Web
import WebKit
import XCTest

/// 评审 r1 S0-01、r2 S0-R2-01 / S2-R2-06：旧文档写回。真实 WKWebView、真实系统清理（探针只同步记录并调用产品的真实清理器，
/// 不 await 任何观察、不睡眠，不改变清理时序）、本机 HTTP。
@MainActor
final class FX25RetirementTests: FX25TestCase {
    /// 同步记录的时刻：容器换上新 WebView（旧文档开始退役）与解除隔离（恢复、发起重新加载）。
    final class Timeline {
        var swaps: [Date] = []
        var lifts: [Date] = []
        var isolated = false
        var released = false
        var attempts = 1
        var cancellables: [AnyCancellable] = []
    }

    /// 旧文档在 visibilitychange / pagehide 里写入（第一次忙等 250ms）、0ms 定时器、未提交的 IndexedDB 长事务，
    /// 加一个在第一次 Cookie 确认时（同步）放出的迟到 Set-Cookie。
    /// - 每次结算失败都保持隔离、不加载新文档、保留标记；至多 3 次尝试内成功；成功后读不到任何旧写入。
    /// - 卸载屏障：旧文档开始退役之后开始的每一项清理，都必须晚于旧文档隐藏 / 离开处理结束的时刻。
    /// 区分力说明：当前产品第一遍失败即整体失败、不做最后一遍，「退役后不等卸载」在本例没有可观察的差别（重试时旧文档早已卸载）；
    /// 若产品改为第一遍失败仍做最后一遍（评审 r2 S2-R2-01），本例的屏障断言对该变异有区分力。确定性的屏障证明由 S0-B 承担。
    func testS0OldDocumentLateWritesAfterReadBackNeverReachTheNewAccount() async throws {
        let (controller, timeline) = try await switchWithOldWriter("/writer", continuous: true, maxAttempts: 3)
        guard let controller else { return }
        try await assertNoOldWrites(controller, path: "/writer")
        try await assertBarrier(timeline)
    }

    /// 确定性的卸载屏障：旧文档只在隐藏 / 离开时写，第一遍不受干扰，必须第一次就成功；最后一遍每项清理都晚于卸载处理结束。
    /// 「退役后不等卸载」：最后一遍在退役的同一轮里开始，早于忙等结束（至少 250ms），必红。
    func testS0FinalPassStartsOnlyAfterTheOldDocumentHasUnloaded() async throws {
        let (controller, timeline) = try await switchWithOldWriter("/hide-writer", continuous: false, maxAttempts: 1)
        guard let controller else { return }
        XCTAssertEqual(timeline.attempts, 1)
        try await assertNoOldWrites(controller, path: "/hide-writer")
        try await assertBarrier(timeline)
    }

    /// 评审 r2 S0-R2-01：旧页在 pagehide 里发 sendBeacon 与 fetch keepalive；本机服务扣住两者的响应（带 Set-Cookie），
    /// 到解除隔离（最后一遍读回已确认、页面开始恢复）那一刻才放出。新文档与当前可信 store 都不能有这两个 Cookie。
    /// 前置：两条请求确实发出；放出后 Cookie 确实被某个 store 收下（旧 store），否则本例证明不了任何事，按失败处理。
    func testS0R2KeepaliveAndBeaconSetCookieAfterFinalReadBackStaysOutOfTheNewAccount() async throws {
        try await prepare()
        server.setCookie("fx25-beacon=user-a; Path=/; Max-Age=600", for: "/fx25-beacon")
        server.setCookie("fx25-keepalive=user-a; Path=/; Max-Age=600", for: "/fx25-keepalive")
        server.holdResponses(for: ["/fx25-beacon", "/fx25-keepalive"])
        let app = make()
        let web = makeWeb(app)
        let controller = try page(web, path: "/beacon")
        try await loaded("/beacon")
        let oldStore = controller.webView.configuration.websiteDataStore
        _ = try await controller.webView.callAsyncJavaScript(
            FX25OldPageScripts.keepaliveOnHide + "\nreturn true;", arguments: [:], in: nil, contentWorld: .page
        )
        var requestsAtLift: [Int] = []
        var sawIsolation = false
        let lift = controller.$isAuthIsolated.sink { [server] isolated in
            MainActor.assumeIsolated {
                if isolated {
                    sawIsolation = true
                } else if sawIsolation, requestsAtLift.isEmpty, let server {
                    requestsAtLift = [server.requests("/fx25-beacon"), server.requests("/fx25-keepalive")]
                    server.releaseResponse()
                }
            }
        }
        defer { lift.cancel() }
        try await login(app)
        let succeeded = try await outcome(web)
        XCTAssertTrue(succeeded)
        try await loaded("/beacon", count: 2)
        XCTAssertEqual(requestsAtLift.count, 2, "没有观察到解除隔离")
        try await until("pagehide 里的 beacon / keepalive 没有发出") {
            self.server.requests("/fx25-beacon") > 0 && self.server.requests("/fx25-keepalive") > 0
        }
        server.releaseResponse()
        try await until("被扣住的响应没有放出") {
            self.server.responded("/fx25-beacon") > 0 && self.server.responded("/fx25-keepalive") > 0
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let names = ["fx25-beacon", "fx25-keepalive"]
        let landed = await oldStore.httpCookieStore.allCookies().filter { names.contains($0.name) }
        XCTAssertFalse(landed.isEmpty, "前置不成立：迟到 Set-Cookie 没有落进任何可信 store，证明不了读回之后的写入")
        let currentStore = controller.webView.configuration.websiteDataStore
        let current = await currentStore.httpCookieStore.allCookies().filter { names.contains($0.name) }
        XCTAssertTrue(current.isEmpty, "当前可信 store 里有旧账号的迟到 Cookie：\(current.map(\.name))")
        let visible = try await controller.webView.callAsyncJavaScript(
            "return document.cookie;", arguments: [:], in: nil, contentWorld: .page
        ) as? String ?? ""
        XCTAssertFalse(names.contains { visible.contains($0) }, "新文档读到了迟到 Cookie：\(visible)")
    }

    private func switchWithOldWriter(
        _ path: String, continuous: Bool, maxAttempts: Int
    ) async throws -> (TrustedWebController?, Timeline) {
        try await prepare()
        server.setCookie("fx25-late-set-cookie=user-a; Path=/; Max-Age=600", for: "/fx25-late-cookie")
        server.holdResponse(for: "/fx25-late-cookie")
        let app = make()
        let web = makeWeb(app)
        let controller = try page(web, path: path)
        try await loaded(path)
        try await seed(controller.webView)
        let script = [
            FX25OldPageScripts.hideWriters(spin: 250, endPath: "/fx25-hide-end"),
            continuous ? FX25OldPageScripts.continuousWriters : "",
            FX25OldPageScripts.lateFetch, "return true;",
        ].joined(separator: "\n")
        let armed = try await controller.webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        XCTAssertEqual(armed as? Bool, true)
        try await until("迟到的 Set-Cookie 请求没有发出") { self.server.isHoldingResponse }
        let timeline = observe(controller)
        probe.onConfirmed = { [server] kind in
            guard kind == .cookies, !timeline.released else { return }
            timeline.released = true
            server?.releaseResponse()
        }
        try await login(app)
        var succeeded = try await outcome(web)
        while !succeeded {
            XCTAssertTrue(controller.isAuthIsolated, "第 \(timeline.attempts) 次失败后必须保持隔离")
            XCTAssertTrue(controller.loadFailed)
            XCTAssertEqual(journal.documents(path).count, 1, "失败时不能加载新文档")
            XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
            guard timeline.attempts < maxAttempts else {
                XCTFail("\(maxAttempts) 次尝试都失败：\(probe.trace)")
                return (nil, timeline)
            }
            timeline.attempts += 1
            controller.retry()
            succeeded = try await outcome(web)
        }
        try await loaded(path, count: 2)
        XCTAssertTrue(timeline.released, "迟到的 Set-Cookie 必须在某次 Cookie 读回之后才放出")
        return (controller, timeline)
    }

    /// 只用同步的 Combine 订阅记录时刻，不介入产品流程。
    private func observe(_ controller: TrustedWebController) -> Timeline {
        let timeline = Timeline()
        timeline.cancellables.append(controller.$webView.dropFirst().sink { _ in
            MainActor.assumeIsolated { timeline.swaps.append(Date()) }
        })
        timeline.cancellables.append(controller.$isAuthIsolated.sink { isolated in
            MainActor.assumeIsolated {
                if isolated {
                    timeline.isolated = true
                } else if timeline.isolated {
                    timeline.isolated = false
                    timeline.lifts.append(Date())
                }
            }
        })
        return timeline
    }

    private func assertNoOldWrites(_ controller: TrustedWebController, path: String) async throws {
        XCTAssertFalse(controller.isAuthIsolated)
        try assertStorage(journal.documents(path).last?.body["storage"], hasOld: false)
        let leftovers = try await controller.webView.callAsyncJavaScript(
            FX25OldPageScripts.readAll, arguments: [:], in: nil, contentWorld: .page
        )
        XCTAssertEqual(leftovers as? [String], [], "新账号的文档读到了旧文档的写入")
        let currentStore = controller.webView.configuration.websiteDataStore
        let cookies = await currentStore.httpCookieStore.allCookies()
        XCTAssertFalse(cookies.contains { $0.name.hasPrefix("fx25") }, "\(cookies.map(\.name))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    /// 旧文档开始退役（第一次换 WebView）之后开始的每一项清理，都必须晚于它隐藏 / 离开处理结束的时刻；且这样的清理五类俱全。
    private func assertBarrier(_ timeline: Timeline) async throws {
        try await until("旧文档的隐藏 / 离开处理没有报告结束") {
            !self.server.targets(prefix: "/fx25-hide-end").isEmpty
        }
        let end = try XCTUnwrap(server.targets(prefix: "/fx25-hide-end").compactMap(FX25OldPageScripts.stamp).min())
        let retired = try XCTUnwrap(timeline.swaps.first, "旧文档没有退役（没有换 WebView）")
        let after = probe.begins.filter { $0.at > retired }
        XCTAssertEqual(Set(after.map(\.kind)), Set(FX25CleanupProbe.kinds), "退役之后没有完整的最后一遍：\(probe.trace)")
        for begin in after {
            let at = begin.at.timeIntervalSince1970 * 1000
            XCTAssertGreaterThan(at, end, "\(begin.kind) 在旧文档卸载处理结束前 \(Int(end - at))ms 就开始了")
        }
        XCTAssertTrue(timeline.lifts.allSatisfy { $0.timeIntervalSince1970 * 1000 > end })
    }
}
