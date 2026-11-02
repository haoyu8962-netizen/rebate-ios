@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Me
import MeCore
import UIKit
import XCTest

/// APP-12w-a 通知设置（brief §2 第 11 条，G-S08、G-S13、G-S14；app-notify-settings §6）。三种系统状态三种画法：已开启无条、已拒绝警告条 + 去设置、
/// **iOS 从未申请（not_asked）中性条、不给按钮**（现状和已拒绝同一画法，还给【去设置】，走不通；系统设置里还没有本 App 的开关）。
@MainActor
final class SettingsVisualNotifyTests: SettingsVisualTestCase {
    /// 已拒绝：警告底 / 字、圆角 12、内边距 12、三角 20、14；「去设置」600 警告字色、文字行高、命中 44 不撑高条。
    func testDeniedBar() async throws {
        let image = try await openNotify(waitFor: "notify.bar.icon")
        let bar = try rect("notify.bar")
        let icon = try rect("notify.bar.icon")
        let body = try record("notify.bar.text")
        let link = try record("notify.goSettings.link")
        assertNear(bar.minX, 16, 1, "左边距")
        assertNear(bar.width, 358, 1, "通栏")
        try assertNear(bar.minY - navBottom(), 8, 2, "内容上 8")
        assertNear(icon.width, 20, 1, "三角 20")
        assertNear(icon.minX - bar.minX, 12, 1, "内边距 12")
        assertNear(body.rect.minX - icon.maxX, 8, 1.5, "图标到文字 8")
        XCTAssertEqual(body.text, try settings.deps.texts.text("perm.push.denied_forever"))
        try assertBase("notify.bar.text", 14, "提示句")
        XCTAssertEqual(link.text, try settings.deps.texts.text("perm.go_settings"))
        try assertBase("notify.goSettings.link", 14, "链接")
        assertNear(link.rect.minX, body.rect.minX, 1, "链接与提示句左齐")
        assertNear(link.rect.minY - body.rect.maxY, 8, 3, "提示句到链接 8")
        XCTAssertLessThanOrEqual(link.rect.height, 24, "视觉行高 = 文字行高")
        assertNear(bar.maxY - link.rect.maxY, 12, 2, "命中区不撑高条（下内边距仍 12）")
        try assertHit("notify.goSettings.hit", covers: "notify.goSettings.link", "去设置")
        let warning = pixel(CouliColor.statusWarningBackground, dark: false)
        let edge = CGRect(x: bar.minX + 2, y: bar.midY - 6, width: 6, height: 12)
        XCTAssertGreaterThan(share(image, in: edge, near: warning, tolerance: 3), 0.8, "status.warning 底（现状 10% 警告字色）")
        XCTAssertGreaterThan(count(image, in: icon, near: pixel(CouliColor.statusWarningText, dark: false)), 5, "三角警告色")
        XCTAssertGreaterThan(count(image, in: body.rect, near: pixel(CouliColor.statusWarningText, dark: false)), 20,
                             "提示句警告字色（现状主文字色）")
        XCTAssertEqual(
            count(image, in: try rect("notify.goSettings.hit"), near: pixel(CouliColor.borderControl, dark: false),
                  tolerance: 6),
            0,
            "不是次按钮描边"
        )
    }

    /// 去设置命中区不盖下面的服务卡开关。
    func testGoSettingsHitClearOfSwitch() async throws {
        try await openNotify(waitFor: "notify.goSettings.hit")
        try assertDisjoint(rect("notify.goSettings.hit"), rect("notify.switch.control"), "去设置 / 开关")
        try assertDisjoint(rect("notify.goSettings.hit"), rect("notify.bar.text"), "去设置 / 提示句")
    }

    /// 已开启：没有提示条。先正后反：已拒绝有。
    func testGrantedHasNoBar() async throws {
        try await openNotify(waitFor: "notify.bar")
        XCTAssertTrue(has("notify.bar"), "已拒绝有条")
        try await openNotify(Setup(push: "granted"), waitFor: "notify.card")
        XCTAssertFalse(has("notify.bar"), "已开启无条")
        XCTAssertFalse(has("notify.neutral"))
    }

    /// G-S14：not_asked = 中性条（muted 底、info 20 次文字色、主文字、画板原句），不给按钮、不申请。
    func testNotAskedNeutralWithoutButton() async throws {
        let image = try await openNotify(Setup(push: "not_asked"), waitFor: "notify.neutral")
        XCTAssertFalse(has("notify.bar"), "不是警告条")
        XCTAssertFalse(has("notify.goSettings.hit"), "不给【去设置】")
        let bar = try rect("notify.neutral")
        let icon = try rect("notify.neutral.icon")
        let body = try record("notify.neutral.text")
        XCTAssertEqual(body.text, "购物后回到 App 时，可以在订单同步提示里开启通知")
        XCTAssertEqual(body.text, try settings.deps.texts.text("notify.not_asked"), "草稿键（§4）")
        try assertBase("notify.neutral.text", 14, "提示句")
        assertNear(icon.width, 20, 1, "info 20")
        assertNear(icon.minX - bar.minX, 12, 1, "内边距 12")
        assertNear(body.rect.minX - icon.maxX, 8, 1.5, "图标到文字 8")
        let edge = CGRect(x: bar.minX + 2, y: bar.midY - 6, width: 6, height: 12)
        XCTAssertGreaterThan(
            share(image, in: edge, near: pixel(CouliColor.backgroundMuted, dark: false), tolerance: 2),
            0.8,
            "muted 底"
        )
        XCTAssertGreaterThan(count(image, in: icon, near: pixel(CouliColor.textSecondary, dark: false)), 5, "info 次文字色")
        XCTAssertEqual(page?.fixture.system.permissionRequests, 0, "不申请")
        XCTAssertEqual(page?.fixture.system.notificationSettingsOpened, 0, "不跳系统设置")
    }

    /// 映射：unavailable 仍按「未开启」给警告条（只有 not_asked 走中性，规格 §6）。
    func testUnavailableKeepsWarningBar() async throws {
        try await openNotify(Setup(push: "unavailable"), waitFor: "notify.bar")
        XCTAssertFalse(has("notify.neutral"))
    }

    /// 回前台重查后画法跟着变：not_asked → 已拒绝（用户在待跟单卡拒绝过）→ 已开启。
    func testRefreshSwitchesPresentation() async throws {
        try await openNotify(Setup(push: "not_asked"), waitFor: "notify.neutral")
        let host = try XCTUnwrap(page)
        host.fixture.system.status["push"] = "permanently_denied"
        try XCTUnwrap(try settings.notify).refreshSystem()
        _ = try await frame("notify.bar")
        XCTAssertFalse(has("notify.neutral"), "换成警告条")
        host.fixture.system.status["push"] = "granted"
        try XCTUnwrap(try settings.notify).refreshSystem()
        _ = try await frame { _ in !self.has("notify.bar") }
    }

    /// 服务卡：内边距 12/16、纵向 4；开关行 ≥ 44、标题 17；说明 12 通栏在开关行下方（现状在开关左边挤着）。
    func testServiceCard() async throws {
        try await openNotify(Setup(push: "granted"), waitFor: "notify.desc")
        let card = try rect("notify.card")
        let title = try rect("notify.switch.title")
        let toggle = try rect("notify.switch.control")
        let line = try rect("notify.switch")
        let desc = try rect("notify.desc")
        try assertNear(card.minY - navBottom(), 8, 2, "内容上 8")
        assertNear(card.minX, 16, 1, "左边距")
        assertNear(card.width, 358, 1, "通栏")
        assertNear(line.minY - card.minY, 12, 2, "上内边距 12")
        XCTAssertGreaterThanOrEqual(line.height, 43.5, "开关行 ≥ 44")
        try assertBase("notify.switch.title", 17, "标题")
        try assertBase("notify.desc", 12, "说明")
        assertNear(toggle.maxX, card.maxX - 16, 1, "开关靠右")
        assertNear(toggle.midY, title.midY, 2, "开关与标题同行")
        assertNear(desc.minX - card.minX, 16, 1, "说明左齐")
        assertNear(card.maxX - desc.maxX, 16, 1, "说明通栏到右内边距")
        assertNear(desc.minY - line.maxY, 4, 2, "纵向 4")
        assertNear(card.maxY - desc.maxY, 12, 2, "下内边距 12")
    }

    /// G-S13：Release 没有后端时只留说明句，不画开关。
    func testReleaseShowsDescOnly() async throws {
        try await openNotify(Setup(push: "granted", noSwitch: true), waitFor: "notify.desc")
        XCTAssertFalse(has("notify.switch"), "没有开关行")
        XCTAssertEqual(try text("notify.desc"), try settings.deps.texts.text("notify.service_desc"))
    }

    /// 读取失败块保持现状（无稿）：错误 + 重试；重试恰一次（现状已符合、加守卫）。
    func testLoadFailureKeepsNoticeBar() async throws {
        try await open()
        let backend = FailingOnceNotify()
        let host = try XCTUnwrap(page)
        host.useCustomPage(routes: nil, nickname: nil, notify: backend)
        host.mount(host.canvas)
        _ = try await frame { $0.controller?.state.cacheBytes != nil }
        try tapRow(SettingsItems.idNotify)
        await waitUntil("读取失败没有呈现") { (try? self.settings.notify?.state.error) != nil }
        XCTAssertEqual(backend.gets, 1)
        let notify = try XCTUnwrap(try settings.notify)
        NotifyActions.make(notify, notify.state).retry()
        await waitUntil("重试没有恢复") { notify.state.service != nil }
        XCTAssertEqual(backend.gets, 2, "重试一次")
        XCTAssertNil(notify.state.error)
    }
}

/// 第一次读取失败、之后成功的通知后端。
private final class FailingOnceNotify: NotifyBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var gets: Int {
        lock.withLock { count }
    }

    func get(owner _: RequestOwnership?, allowed _: @escaping @Sendable () -> Bool) async -> ApiResult {
        let first = lock.withLock {
            count += 1
            return count == 1
        }
        if first {
            return .failure(code: 50001, msg: "", data: nil, traceId: "settings-visual-a1b2c3",
                            effect: ErrorEffect(code: 50001, kind: .toast), idempotencyKey: nil)
        }
        return .success(data: Data(#"{"service":true}"#.utf8), traceId: nil, idempotencyKey: nil)
    }

    func put(service _: Bool, owner _: RequestOwnership?,
             allowed _: @escaping @Sendable () -> Bool) async -> ApiResult {
        .success(data: Data("{}".utf8), traceId: nil, idempotencyKey: nil)
    }
}
