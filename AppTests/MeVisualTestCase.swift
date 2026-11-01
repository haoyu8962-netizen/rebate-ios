@testable import Couli
import DesignSystem
import Foundation
import Me
import MeCore
import SwiftUI
import UIKit
import XCTest

/// APP-12v 视觉用例底座：继承钱包视觉底座（断言、像素判据同一份，只把测量来源换成 `MeVisualHost`）。每个页面一份新的偏好套件与本机目录；
/// 网络是生产 WalletStubProtocol + WalletScript；时钟固定；读屏播报与轻提示经生产的 `MeAnnounceProbe` 旁路记录（瞬时轻提示不靠截图抓，F-IOS-62）。
@MainActor
class MeVisualTestCase: WalletVisualTestCase {
    struct Setup {
        /// visualMe.profiles 的一份报文；nil = 不登记（游客用）。
        var profile: String? = "me_member"
        var canvas = MeVisualHost.Canvas()
        var guest = false
        var hidden = false
        /// visualMe.localStates.me_hidden_guide 的通知状态：被拒 ≥ 48 小时、从未关闭。
        var guide = false
        var scope = "full"
        var decision = "consented"
        /// 覆盖 GET /v1/me 的回答（挂起、错误）。
        var reply: WalletStubProtocol.Reply?
        /// 就绪时快照所处阶段；nil = 不看（游客）。
        var phase: MeSnapshot.Phase? = .content
        /// 包一层的页面（公开版宫格、文案替换、动作计数）。
        var custom = false
        var routes: Set<String>?
        var earnings: Bool?
        var overrides: [String: String] = [:]
    }

    var page: MeVisualHost?
    var announcements: [(text: String, assertive: Bool)] = []
    var toasts: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        announcements = []
        toasts = []
        MeAnnounceProbe.observe = { [weak self] text, assertive in self?.announcements.append((text, assertive)) }
        MeAnnounceProbe.toast = { [weak self] text in self?.toasts.append(text) }
    }

    override func tearDown() async throws {
        page?.close()
        page = nil
        MeAnnounceProbe.observe = nil
        MeAnnounceProbe.toast = nil
        removeLocal()
        await settle()
        try await super.tearDown()
    }

    private func removeLocal() {
        guard !suiteName.isEmpty else { return }
        try? FileManager.default.removeItem(at: MeAppFixture.localDirectory(suiteName))
    }

    /// 刷新回答：受限会话的启动屏障要它，否则刷新被拒、会话清掉、掉成游客，根本走不到受限分支（测试 v1 的 T2）。
    static func refreshBody(scope: String) -> String {
        "{\"access_token\":\"at-r\",\"refresh_token\":\"rt-r\",\"session_scope\":\"\(scope)\",\"expires_in\":7200}"
    }

    // MARK: - 打开页面

    func fresh(_ setup: Setup) throws -> MeVisualHost {
        page?.close()
        page = nil
        WalletStubProtocol.reset()
        removeLocal()
        defaults?.removePersistentDomain(forName: suiteName)
        suiteName = "me-visual-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let script = WalletScript()
        script.ok("GET /v1/config", MeSamples.config)
        script.ok("POST /v1/devices/push-token", "{}")
        script.ok("POST /v1/auth/refresh", Self.refreshBody(scope: setup.scope))
        if let reply = setup.reply {
            script.on("GET /v1/me", reply)
        } else if let profile = setup.profile {
            try script.ok("GET /v1/me", MeVisualData.body(profile))
        }
        script.install()
        let fixture = MeAppFixture.make(suiteName: suiteName, defaults: defaults,
                                        account: setup.guest ? nil : "me-visual-a", scope: setup.scope,
                                        decision: setup.decision)
        let now = try MeVisualData.nowMillis()
        fixture.me.clock = { now }
        fixture.me.mask.set(setup.hidden)
        if setup.guide {
            let local = try MeVisualData.local("me_hidden_guide")
            fixture.system.status["push"] = try XCTUnwrap(local["notification"] as? String)
            fixture.system.deniedAt["push"] = try MeVisualData.millis(XCTUnwrap(local["deniedAt"] as? String))
        }
        let host = MeVisualHost(fixture: fixture, script: script)
        if setup.custom {
            host.useCustomPage(routes: setup.routes, earnings: setup.earnings, overrides: setup.overrides)
        }
        page = host
        return host
    }

    /// 打开页面并等稳定（就绪 = 快照到 `setup.phase`、`waitFor` 测量已上报、要求的引导条已判定显示）。
    /// `waitFor` 为 nil 时不等测量：资金 / 行为守卫只看执行器，不把「测量桥未接」混进来。
    @discardableResult
    func open(_ setup: Setup = Setup(), waitFor: String? = "me.hero", file: StaticString = #filePath,
              line: UInt = #line) async throws -> (MeVisualHost, UIImage) {
        let host = try fresh(setup)
        await host.show(setup.canvas)
        let image = await host.stable(file: file, line: line) { current in
            (setup.phase.map { current.repo.state.phase == $0 } ?? true)
                && (!setup.guide || current.controller.guideVisible)
                && (waitFor.map { current.probes[$0] != nil } ?? true)
        }
        return try (host, XCTUnwrap(image, "「我的」没有截到稳定画面", file: file, line: line))
    }

    /// 重新稳定一帧（点击 / 切换之后）。
    func frame(file: StaticString = #filePath, line: UInt = #line,
               until ready: @escaping (MeVisualHost) -> Bool = { _ in true }) async throws -> UIImage {
        let host = try XCTUnwrap(page, file: file, line: line)
        let image = await host.stable(file: file, line: line, until: ready)
        return try XCTUnwrap(image, file: file, line: line)
    }

    // MARK: - 测量（来源换成本页宿主；断言与像素判据全部沿用底座）

    override func rect(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        try XCTUnwrap(page?.probes[id], "缺测量 \(id)（交回 §4）", file: file, line: line).rect
    }

    override func record(_ id: String, file: StaticString = #filePath,
                         line: UInt = #line) throws -> CouliLayoutProbeRecord {
        try XCTUnwrap(page?.probes[id], "缺测量 \(id)（交回 §4）", file: file, line: line)
    }

    override var allTexts: [String] {
        page?.probes.records.values.map(\.text).filter { !$0.isEmpty } ?? []
    }

    func has(_ id: String) -> Bool {
        page?.probes[id] != nil
    }

    func assertSameLine(_ lhs: String, _ rhs: String, _ message: String, file: StaticString = #filePath,
                        line: UInt = #line) throws {
        XCTAssertTrue(try sameRow(rect(lhs, file: file, line: line), rect(rhs, file: file, line: line)),
                      "\(message)：\(lhs) 与 \(rhs) 不同行", file: file, line: line)
    }

    /// 命中区以视觉框为中心外扩（iOS 44；视觉尺寸不被撑大）。
    func assertHitCentered(_ hitID: String, covers visualID: String, visual size: CGFloat, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        try assertHit(hitID, covers: visualID, message, file: file, line: line)
        let hit = try rect(hitID, file: file, line: line)
        let icon = try rect(visualID, file: file, line: line)
        assertNear(max(icon.width, icon.height), size, 1, "\(message)：视觉尺寸", file: file, line: line)
        assertNear(hit.midX, icon.midX, 1.5, "\(message)：命中区横向以图标为中心", file: file, line: line)
        assertNear(hit.midY, icon.midY, 1.5, "\(message)：命中区纵向以图标为中心", file: file, line: line)
    }

    /// 文字完整：框在容器内 + 按自然宽折算的行数放得下（宽度与位置都比，APP-11v-b r2）。
    func assertWhole(_ id: String, inside container: CGRect, _ message: String, file: StaticString = #filePath,
                     line: UInt = #line) throws {
        let item = try record(id, file: file, line: line)
        XCTAssertFalse(MeVisualJudge.truncated(item), "\(message)：被截断 \(item)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(item.fontSize + 0.01, item.baseFontSize, "\(message)：字号不缩", file: file, line: line)
        assertInside(item.rect, container, "\(message)：在容器内", file: file, line: line)
    }

    /// 顶部轻提示带内的成功绿像素数（DS Toast 没有测量：对勾是这一带唯一的绿色）。
    func toastGreen(_ image: UIImage, dark: Bool = false) -> Int {
        let width = page?.canvas.width ?? image.size.width
        return count(image, in: CGRect(x: 0, y: 0, width: width, height: 180),
                     near: pixel(CouliColor.statusSuccessText, dark: dark), tolerance: 24)
    }

    /// `GET /v1/me` 的请求次数。
    var meReads: Int {
        WalletStubProtocol.requests("GET", "/v1/me").count
    }
}
