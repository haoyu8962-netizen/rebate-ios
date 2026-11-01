import Combine
@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Me
import MeCore
import SwiftUI
import UIKit
import XCTest

/// APP-12v 轻提示与播报（G-M12、G-M13、G-M14；brief §2.9、§9 第 10 条；Android 评审 r1 S1「换身份当帧带出上一账号的提示」、S2「一条提示两个播报出口」）。
/// 轻提示内容经生产 `MeAnnounceProbe.toast`、读屏经 `MeAnnounceProbe.observe` 记录；瞬时轻提示不靠 XCUI 抓（F-IOS-62）。
@MainActor
final class MeVisualNoticeTests: MeVisualTestCase {
    private func copiedText(_ host: MeVisualHost) -> String {
        host.texts.text(MeTabController.copied)
    }

    /// 让下一次读取失败（已有内容时的刷新失败），发起刷新并等到轻提示。
    private func failRefresh(_ host: MeVisualHost, code: Int = 50001) async {
        host.script.fail("GET /v1/me", code)
        host.actions.refresh()
        await waitUntil("刷新失败提示没有出现", timeout: 8) { !self.toasts.isEmpty }
    }

    /// 轮询到判定成立的第一帧（轻提示只显示约 2 秒，不用 `stable`）。
    private func pollFrame(seconds: Double = 1.5, _ check: (UIImage) -> Bool) async -> Bool {
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

    // MARK: - G-M12 对勾

    /// 先正后反：复制成功带绿对勾；复制失败、刷新失败不带图标（现状 MeToastMessage 一律成功勾）。
    func testToastIconPerKind() async throws {
        let (host, _) = try await open(waitFor: nil)
        host.actions.copyInvite()
        await waitUntil("复制提示没有出现") { self.toasts.count == 1 }
        XCTAssertEqual(toasts.last, copiedText(host))
        let green = await pollFrame { self.toastGreen($0) > 10 }
        XCTAssertTrue(green, "复制成功：顶部绿色对勾（G-M12）")

        let (failing, _) = try await open(waitFor: nil)
        toasts = []
        failing.fixture.ledgerStore.failWrites = true
        failing.actions.copyInvite()
        await waitUntil("复制失败提示没有出现") { self.toasts.count == 1 }
        XCTAssertEqual(toasts.last, failing.texts.text(MeTabController.copyFailed))
        let wrong = await pollFrame { self.toastGreen($0) > 10 }
        XCTAssertFalse(wrong, "复制失败不带对勾")

        let (reading, _) = try await open(waitFor: nil)
        toasts = []
        await failRefresh(reading)
        let error = await pollFrame { self.toastGreen($0) > 10 }
        XCTAssertFalse(error, "刷新失败不带对勾")
    }

    /// 同文再复制是新请求，再播一次；提示文字不含码以外的账号信息。
    func testCopyAgainIsNewToast() async throws {
        let (host, _) = try await open(waitFor: nil)
        host.actions.copyInvite()
        await waitUntil("第一次提示") { self.toasts.count == 1 }
        host.actions.copyInvite()
        await waitUntil("第二次提示", timeout: 6) { self.toasts.count == 2 }
        XCTAssertEqual(host.fixture.clipboard.last, "K7M3QX")
        XCTAssertEqual(Set(toasts), [copiedText(host)])
    }

    // MARK: - G-M13 隐藏切换播报

    /// 用户点眼睛后 polite 播报一次；进入、别处改偏好、重挂都不播。走页面同一份回调 `MeTabActions.toggleMask`（交回 §4）。
    func testMaskToggleAnnouncesOnce() async throws {
        let (host, _) = try await open(waitFor: nil)
        XCTAssertEqual(announcements.count, 0, "进入不播")
        XCTAssertEqual(host.texts.text("me.amount_shown"), "金额已显示", "新草稿键（G-M16）")
        host.actions.toggleMask()
        await settle()
        XCTAssertEqual(announcements.map(\.text), ["金额已隐藏"], "隐藏时播一次")
        XCTAssertEqual(announcements.map(\.assertive), [false], "polite")
        host.actions.toggleMask()
        await settle()
        XCTAssertEqual(announcements.map(\.text), ["金额已隐藏", "金额已显示"], "显示时播一次")
        XCTAssertEqual(announcements.map(\.assertive), [false, false], "polite")
        await quietWindow(0.5)
        XCTAssertEqual(announcements.count, 2, "不重复")
        host.fixture.me.mask.set(true)
        await quietWindow(0.5)
        XCTAssertEqual(announcements.count, 2, "别处改偏好（钱包页）回来不播")
        host.remount(host.canvas)
        _ = try await frame { $0.repo.state.phase == .content }
        XCTAssertEqual(announcements.count, 2, "回前台 / 重挂不播")
    }

    // MARK: - G-M14 一次一条、刷新失败优先

    /// 刷新失败：assertive 恰一次（同一条提示只留一个播报出口）；已有内容保留。
    func testRefreshFailureAssertiveOnce() async throws {
        let (host, _) = try await open(waitFor: nil)
        await failRefresh(host)
        await settle()
        let spoken = announcements.filter { $0.text.contains("6789ab") }
        XCTAssertEqual(spoken.count, 1, "读屏恰一次：\(announcements)")
        XCTAssertEqual(spoken.first?.assertive, true, "刷新失败 assertive（G-M14，现状 polite）")
        XCTAssertNotNil(host.repo.state.me, "已有内容保留")
        await quietWindow(2.5)
        XCTAssertEqual(announcements.filter { $0.text.contains("6789ab") }.count, 1, "结束后不重播")
        XCTAssertEqual(toasts.count, 1, "轻提示不重放")
    }

    /// 错误显示中复制：排在其后，不抢位；错误结束后才显示。
    func testCopyQueuedBehindError() async throws {
        let (host, _) = try await open(waitFor: nil)
        await failRefresh(host)
        host.actions.copyInvite()
        await settle()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(toasts.count, 1, "错误显示中不换成复制提示（G-M14）：\(toasts)")
        await waitUntil("复制提示没有接着显示", timeout: 8) { self.toasts.count == 2 }
        XCTAssertEqual(toasts.last, copiedText(host))
        await quietWindow(2.5)
        XCTAssertEqual(toasts.count, 2, "两条各一次，不重放")
    }

    /// 同一拍同时到（快照发布的同一轮里按下复制）：刷新失败先显示。
    func testSameBeatErrorFirst() async throws {
        let (host, _) = try await open(waitFor: nil)
        let actions = host.actions
        var fired = false
        let subscription = host.repo.$state.sink { state in
            guard state.error != nil, !fired else { return }
            fired = true
            actions.copyInvite()
        }
        defer { subscription.cancel() }
        host.script.fail("GET /v1/me", 50001)
        host.actions.refresh()
        await waitUntil("没有同拍", timeout: 8) { fired && !self.toasts.isEmpty }
        XCTAssertTrue(try XCTUnwrap(toasts.first).contains("6789ab"), "刷新失败优先：\(toasts)")
        await waitUntil("复制提示没有接着显示", timeout: 8) { self.toasts.count == 2 }
        XCTAssertEqual(toasts.last, copiedText(host))
    }

    /// 正在显示的提示随身份作废（M16c，Android 评审 r1 S1）：上一账号的复制提示显示中换账号 / 退出，不等 2 秒走完就要消失。条目自带的 isValid 只管排队的，
    /// 显示中的只有换执行器时的 `drop()` 能清掉，本例就是它的判据。出现后留 0.7 秒给退场动画，此时距显示满 2 秒至少还有约 1 秒。
    func testVisibleToastClearedOnIdentityChange() async throws {
        for leave in ["switch", "logout"] {
            let (host, _) = try await open(waitFor: nil)
            host.script.ok("GET /v1/me", try MeVisualData.body("me_new_user"))
            host.actions.copyInvite()
            let shown = await pollFrame { self.toastGreen($0) > 10 }
            XCTAssertTrue(shown, "\(leave)：前提，上一账号的提示显示中")
            if leave == "switch" {
                try host.fixture.switchAccount(to: "user-b")
            } else {
                host.fixture.client.signOut()
                host.fixture.routing.sessionStateChanged(resumePending: false)
            }
            await quietWindow(0.7)
            host.window?.layoutIfNeeded()
            let image = try XCTUnwrap(host.render())
            XCTAssertLessThanOrEqual(toastGreen(image), 10, "\(leave)：上一账号的提示不带到新身份")
        }
    }

    /// 排队中的提示随身份作废（Android 评审 r1 S1）：错误显示中排着上一账号的复制提示，换账号 / 退出之后全程不再出现。
    func testQueuedToastDroppedOnIdentityChange() async throws {
        for leave in ["switch", "logout"] {
            let (host, _) = try await open(waitFor: nil)
            toasts = []
            await failRefresh(host)
            host.actions.copyInvite()
            await settle()
            let before = toasts
            XCTAssertEqual(before.count, 1, "\(leave)：排队中")
            host.script.ok("GET /v1/me", try MeVisualData.body("me_new_user"))
            if leave == "switch" {
                try host.fixture.switchAccount(to: "user-b")
            } else {
                host.fixture.client.signOut()
                host.fixture.routing.sessionStateChanged(resumePending: false)
            }
            await quietWindow(3.5)
            XCTAssertEqual(toasts, before, "\(leave)：上一账号的提示不带到新身份")
        }
    }
}
