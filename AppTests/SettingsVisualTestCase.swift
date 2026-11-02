@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Me
import MeCore
import SwiftUI
import UIKit
import XCTest

/// APP-12w-a 视觉用例底座：继承钱包视觉底座的断言与像素判据，测量来源换成 `SettingsVisualHost`。
/// 瞬时轻提示经生产 `MeAnnounceProbe` 旁路记录，不靠截图抓（F-IOS-62）；时钟固定。
@MainActor
class SettingsVisualTestCase: WalletVisualTestCase {
    enum Level {
        case member, guest, basic
    }

    struct Setup {
        var level = Level.member
        var profile = "settings_member"
        var canvas = SettingsVisualHost.Canvas()
        /// 系统通知状态（iOS 原始值）。
        var push = "permanently_denied"
        /// 公开版 = routes_public（G-S05）；nil = 走生产路由。
        var routes: Set<String>?
        var held: HeldNicknameBackend?
        /// Release 口径：没有服务开关后端（G-S13）。
        var noSwitch = false
        /// 覆盖 GET /v1/me 的回答（挂起、错误）。
        var reply: WalletStubProtocol.Reply?
        /// 文案替换（压力值：长标题）。
        var overrides: [String: String] = [:]
    }

    var page: SettingsVisualHost?
    var announcements: [(text: String, assertive: Bool)] = []
    var toasts: [String] = []
    var focused: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        announcements = []
        toasts = []
        focused = []
        MeAnnounceProbe.observe = { [weak self] text, assertive in self?.announcements.append((text, assertive)) }
        MeAnnounceProbe.toast = { [weak self] text in self?.toasts.append(text) }
        MeAnnounceProbe.focused = { [weak self] id in self?.focused.append(id) }
    }

    override func tearDown() async throws {
        page?.close()
        page = nil
        MeAnnounceProbe.observe = nil
        MeAnnounceProbe.toast = nil
        MeAnnounceProbe.focused = nil
        removeLocal()
        await settle()
        try await super.tearDown()
    }

    private func removeLocal() {
        guard !suiteName.isEmpty else { return }
        try? FileManager.default.removeItem(at: MeAppFixture.localDirectory(suiteName))
    }

    // MARK: - 打开页面

    func publicRoutes() throws -> Set<String> {
        try SettingsVisualData.routes("routes_public")
    }

    func fresh(_ setup: Setup) throws -> SettingsVisualHost {
        page?.close()
        page = nil
        WalletStubProtocol.reset()
        removeLocal()
        defaults?.removePersistentDomain(forName: suiteName)
        suiteName = "settings-visual-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let script = WalletScript()
        script.ok("GET /v1/config", MeSamples.config)
        script.ok("POST /v1/devices/push-token", "{}")
        script.ok("POST /v1/auth/refresh", MeVisualTestCase.refreshBody(scope: "full"))
        script.ok("DELETE /v1/me/tips/jump_tip", "{}")
        script.ok("POST /v1/auth/logout", "{}")
        if let reply = setup.reply {
            script.on("GET /v1/me", reply)
        } else if setup.level == .member {
            try script.ok("GET /v1/me", SettingsVisualData.body(setup.profile))
        }
        script.install()
        let fixture = MeAppFixture.make(
            suiteName: suiteName, defaults: defaults, account: setup.level == .member ? "settings-visual-a" : nil,
            decision: setup.level == .basic ? "basic_mode" : "consented"
        )
        let now = try SettingsVisualData.nowMillis()
        fixture.me.clock = { now }
        fixture.system.bytes = try SettingsVisualData.cacheBytes()
        fixture.system.bytesAfterClear = 0
        fixture.system.status["push"] = setup.push
        let host = SettingsVisualHost(fixture: fixture, script: script)
        if setup.routes != nil || setup.held != nil || setup.noSwitch || !setup.overrides.isEmpty {
            host.useCustomPage(routes: setup.routes, nickname: setup.held ?? fixture.nickname,
                               notify: setup.noSwitch ? nil : fixture.notify, overrides: setup.overrides)
        } else {
            host.useRoute()
        }
        page = host
        return host
    }

    /// 打开设置页并等稳定。就绪 = 缓存大小算出、已登录时 Me 到位（`setup.reply` 给了就只看 `waitFor`）、`waitFor` 测量已上报。
    /// `waitFor` 为 nil 时不等测量：行为 / 守卫用例不把「测量桥未接」混进来。
    @discardableResult
    func open(_ setup: Setup = Setup(), waitFor: String? = nil, file: StaticString = #filePath,
              line: UInt = #line) async throws -> (SettingsVisualHost, UIImage) {
        let host = try fresh(setup)
        host.mount(setup.canvas)
        let image = await host.stable(file: file, line: line) { current in
            guard let controller = current.controller else { return false }
            let loaded = setup.reply != nil || setup.level != .member || controller.deps.repo.state.me != nil
            return controller.state.cacheBytes != nil && loaded && (waitFor.map { current.probes[$0] != nil } ?? true)
        }
        return try (host, XCTUnwrap(image, "设置页没有截到稳定画面", file: file, line: line))
    }

    /// 点击 / 切换之后重新稳定一帧。
    func frame(_ waitFor: String? = nil, file: StaticString = #filePath, line: UInt = #line,
               until ready: @escaping (SettingsVisualHost) -> Bool = { _ in true }) async throws -> UIImage {
        let host = try XCTUnwrap(page, file: file, line: line)
        let image = await host.stable(file: file, line: line) { current in
            ready(current) && (waitFor.map { current.probes[$0] != nil } ?? true)
        }
        return try XCTUnwrap(image, file: file, line: line)
    }

    /// 轮询到判定成立的第一帧（轻提示只显示约 2 秒，不用 `stable`）。
    func pollFrame(seconds: Double = 1.5, _ check: @escaping (UIImage) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            page?.window?.layoutIfNeeded()
            if let image = page?.render(), check(image) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return false
    }

    // MARK: - 生产回调（页面同一份构造）

    var settings: SettingsController {
        get throws {
            try XCTUnwrap(page?.controller, "没有设置页执行器")
        }
    }

    var actions: SettingsActions {
        get throws {
            let controller = try settings
            return SettingsActions.make(controller, controller.state)
        }
    }

    func row(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> SettingsRow {
        try XCTUnwrap(
            settings.model().groups.flatMap(\.rows).first { $0.id == id },
            "没有行 \(id)",
            file: file,
            line: line
        )
    }

    func tapRow(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try actions.row(row(id, file: file, line: line))
    }

    /// 昵称子页的同一份回调。
    var nickname: NicknameController {
        get throws {
            try XCTUnwrap(settings.nickname, "昵称子页没有打开")
        }
    }

    var nicknameActions: NicknameActions {
        get throws {
            let controller = try nickname
            return NicknameActions.make(controller, controller.state)
        }
    }

    /// 进昵称子页。
    @discardableResult
    func openNickname(_ setup: Setup = Setup(), waitFor: String? = "nickname.field", file: StaticString = #filePath,
                      line: UInt = #line) async throws -> UIImage {
        try await open(setup, file: file, line: line)
        try tapRow(SettingsItems.idNickname, file: file, line: line)
        return try await frame(waitFor, file: file, line: line) { $0.controller?.nickname != nil }
    }

    /// 输入并保存，等结果落到执行器；`reply` 给服务端回答。
    func save(_ input: String, reply: ApiResult, file: StaticString = #filePath, line: UInt = #line) async throws {
        page?.fixture.nickname.reply(reply)
        try nicknameActions.input(input)
        try nicknameActions.save()
        // 不走会记失败的 `nickname` 取值：保存成功时子页已关，这里轮询到 nil 是正常结果
        await waitUntil("保存没有结束", file: file, line: line) {
            self.page?.controller?.nickname?.state.saving != true
        }
    }

    /// 进通知子页（等系统状态查完）。
    @discardableResult
    func openNotify(_ setup: Setup = Setup(), waitFor: String? = nil, file: StaticString = #filePath,
                    line: UInt = #line) async throws -> UIImage {
        try await open(setup, file: file, line: line)
        try tapRow(SettingsItems.idNotify, file: file, line: line)
        return try await frame(waitFor, file: file, line: line) { host in
            guard let state = host.controller?.notify?.state else { return false }
            return state.systemGranted != nil && !state.loading
        }
    }

    // MARK: - 测量

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

    func navBottom(file: StaticString = #filePath, line: UInt = #line) throws -> CGFloat {
        try XCTUnwrap(page?.navigationBottom, "没有系统导航栏", file: file, line: line)
    }

    /// 命中区以视觉框为中心外扩（iOS 44；视觉尺寸不被撑大）。
    func assertHitCentered(_ hitID: String, covers visualID: String, visual size: CGFloat, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        try assertHit(hitID, covers: visualID, message, file: file, line: line)
        let hit = try rect(hitID, file: file, line: line)
        let icon = try rect(visualID, file: file, line: line)
        assertNear(max(icon.width, icon.height), size, 1, "\(message)：视觉尺寸", file: file, line: line)
        assertNear(hit.midX, icon.midX, 1.5, "\(message)：命中区横向以视觉框为中心", file: file, line: line)
        assertNear(hit.midY, icon.midY, 1.5, "\(message)：命中区纵向以视觉框为中心", file: file, line: line)
    }

    /// 文字完整：框在容器内 + 按自然宽折算的行数放得下（宽度与位置都比，APP-11v-b r2）；字号不缩。
    func assertWhole(_ id: String, inside container: CGRect, _ message: String, file: StaticString = #filePath,
                     line: UInt = #line) throws {
        let item = try record(id, file: file, line: line)
        XCTAssertFalse(MeVisualJudge.truncated(item), "\(message)：被截断 \(item)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(item.fontSize + 0.01, item.baseFontSize, "\(message)：字号不缩", file: file, line: line)
        assertInside(item.rect, container, "\(message)：在容器内", file: file, line: line)
    }

    /// 控件描边墨迹：只看行框上下两条边、到 `right` 为止（避开右侧箭头的抗锯齿、不碰居中的文字）。真次按钮上下边是连续的 `border.control`，上百像素。
    func outlineInk(_ image: UIImage, _ box: CGRect, right: CGFloat) -> Int {
        let width = right - box.minX
        let top = CGRect(x: box.minX, y: box.minY - 1, width: width, height: 3)
        let bottom = CGRect(x: box.minX, y: box.maxY - 2, width: width, height: 3)
        let ink = pixel(CouliColor.borderControl, dark: false)
        return count(image, in: top, near: ink, tolerance: 6) + count(image, in: bottom, near: ink, tolerance: 6)
    }

    /// 顶部轻提示带内的成功绿像素数（DS Toast 没有测量：对勾是这一带唯一的绿色）。
    func toastGreen(_ image: UIImage, dark: Bool = false) -> Int {
        let width = page?.canvas.width ?? image.size.width
        return count(image, in: CGRect(x: 0, y: 0, width: width, height: 220),
                     near: pixel(CouliColor.statusSuccessText, dark: dark), tolerance: 24)
    }

    var meReads: Int {
        WalletStubProtocol.requests("GET", "/v1/me").count
    }
}
