import Combine
@testable import Couli
import Foundation
@testable import Web
import WebKit
import XCTest

/// 评审 r2 S1-R2-01：页面在切号清理进行中被关闭（teardown），界面随即放掉它的 WebView——测试也不持有任何强引用。
/// 关闭阶段的 pagehide / unload 写入（第一次忙等 300ms 后再写一次）不能留给新账号，且恢复必须等到这段卸载处理结束之后。
@MainActor
final class FX25TeardownTests: FX25TestCase {
    func testS1R2ReleasedTornDownPageUnloadWritesNeverReachTheNewAccount() async throws {
        try await prepare()
        let app = make()
        let web = makeWeb(app)
        let survivor = try page(web, path: "/survivor")
        try await loaded("/survivor")
        weak var closingView: WKWebView?
        try await openClosingPage(web) { closingView = $0 }
        var lifts: [Date] = []
        var sawIsolation = false
        let lift = survivor.$isAuthIsolated.sink { isolated in
            MainActor.assumeIsolated {
                if isolated {
                    sawIsolation = true
                } else if sawIsolation {
                    lifts.append(Date())
                }
            }
        }
        defer { lift.cancel() }
        probe.held = .cookies
        try await login(app)
        try await until("第一遍清理没开始") { self.probe.entered.contains(.cookies) }
        closeAndRelease(path: "/closing")
        probe.release()
        let succeeded = try await outcome(web)
        XCTAssertTrue(succeeded)
        try await loaded("/survivor", count: 2)
        try await until("被关闭页面的 pagehide / unload 没有执行到底（没有报告结束）") {
            !self.server.targets(prefix: "/fx25-unload-end").isEmpty
        }
        let end = try XCTUnwrap(server.targets(prefix: "/fx25-unload-end").compactMap(FX25OldPageScripts.stamp).min())
        let restored = try XCTUnwrap(lifts.first, "幸存页没有恢复")
        XCTAssertGreaterThan(
            restored.timeIntervalSince1970 * 1000, end, "恢复早于被关闭页面的卸载处理结束（没等它卸载）"
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        let leftovers = try await survivor.webView.callAsyncJavaScript(
            FX25OldPageScripts.readAll, arguments: [:], in: nil, contentWorld: .page
        )
        XCTAssertEqual(leftovers as? [String], [], "新账号的文档读到了被关闭页面的写入")
        let currentStore = survivor.webView.configuration.websiteDataStore
        let cookies = await currentStore.httpCookieStore.allCookies()
        XCTAssertFalse(cookies.contains { $0.name.hasPrefix("fx25") }, "\(cookies.map(\.name))")
        try await until("被关闭页面的 WebView 一直没有释放（产品应在确认卸载后放掉）", timeout: 10) { closingView == nil }
    }

    /// 打开将被关闭的页面、种旧数据、装上关闭阶段的写入；只把弱引用交给调用方。
    private func openClosingPage(_ web: AppWeb, expose: (WKWebView) -> Void) async throws {
        let closing = try page(web, path: "/closing")
        try await loaded("/closing")
        try await seed(closing.webView)
        let script = FX25OldPageScripts.hideWriters(spin: 300, endPath: "/fx25-unload-end") + "\nreturn true;"
        let armed = try await closing.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(armed as? Bool, true)
        expose(closing.webView)
    }

    /// 路由出栈：teardown，并放掉夹具持有的全部强引用（容器数组、承载窗口）。
    private func closeAndRelease(path: String) {
        guard let index = controllers.firstIndex(where: { $0.webView.url?.path == path }) else {
            return XCTFail("找不到 \(path) 的容器")
        }
        let controller = controllers.remove(at: index)
        let view = controller.webView
        controller.teardown()
        if let window = view.window {
            view.removeFromSuperview()
            window.isHidden = true
            windows.removeAll { $0 === window }
        } else {
            view.removeFromSuperview()
        }
    }
}
