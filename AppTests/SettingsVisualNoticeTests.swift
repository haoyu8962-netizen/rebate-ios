@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
@testable import Me
import MeCore
import SwiftUI
import UIKit
import XCTest

/// APP-12w-a 轻提示（G-S06，brief §2 第 9 条）：成功类带对勾、错误 / 限流类不带（现状 `MeToastMessage` 一律成功勾，「我的」Tab 已由队列改掉，设置一族还是）。
/// 内容经生产 `MeAnnounceProbe.toast` 记录；一条提示只有一个播报出口。撤回注销在 iOS 没有触发链（交回 §6），只测映射。
@MainActor
final class SettingsVisualNoticeTests: SettingsVisualTestCase {
    private func green() async -> Bool {
        await pollFrame { self.toastGreen($0) > 10 }
    }

    /// 生产的「提示 → 轻提示请求」（`meToast` 同一个入口）。
    private func message(_ key: String) -> CouliToastMessage {
        MeToastMessage.make(MeNotice(key, id: 1), texts: MeDraftTexts())
    }

    /// 视图层纯映射：visualSettings.notices 全表（含 iOS 尚无触发链的 deletion.cancelled_toast）。
    func testIconMappingTable() throws {
        for row in try SettingsVisualData.notices() {
            let expected: CouliToastIcon = row.check ? .success : .none
            XCTAssertEqual(message(row.key).icon, expected, row.key)
        }
    }

    /// 映射表驱动的渲染：同一个生产 `couliToast` 下，成功有绿、错误没有（先正后反）。
    func testMappedIconRenders() async {
        func shot(_ key: String) async -> Int {
            let (image, _) = await ProductVisualRender.standalone(SettingsToastSample(message: message(key)),
                                                                  size: CGSize(width: 390, height: 200))
            return count(image, in: CGRect(x: 0, y: 0, width: 390, height: 200),
                         near: pixel(CouliColor.statusSuccessText, dark: false))
        }
        let success = await shot("deletion.cancelled_toast")
        let failure = await shot("error.42901")
        XCTAssertGreaterThan(success, 10, "撤回注销带对勾")
        XCTAssertEqual(failure, 0, "限流不带对勾")
    }

    /// 已清除：真实路径，带对勾，「清除缓存」行变 0KB，提示一次。
    func testClearedToastHasTick() async throws {
        try await open()
        try tapRow(SettingsItems.idClearCache)
        try actions.confirmClear(XCTUnwrap(try settings.state.dialog))
        await waitUntil("已清除没有出现") { self.toasts.count == 1 }
        XCTAssertEqual(toasts, [try settings.deps.texts.text(SettingsController.clearedKey)])
        let ticked = await green()
        XCTAssertTrue(ticked, "已清除带对勾")
        XCTAssertEqual(try settings.state.cacheBytes, 0)
        XCTAssertEqual(page?.fixture.system.cleared, 1)
    }

    /// 清除失败（error.50001）不带对勾（现状带）。
    func testClearFailedNoTick() async throws {
        try await open()
        page?.fixture.system.clearSucceeds = false
        try tapRow(SettingsItems.idClearCache)
        try actions.confirmClear(XCTUnwrap(try settings.state.dialog))
        await waitUntil("失败提示没有出现") { !self.toasts.isEmpty }
        let ticked = await green()
        XCTAssertFalse(ticked, "失败不带对勾")
    }

    /// 重新显示下单须知：成功带对勾、42901 不带；不跳页。
    func testResetTipToast() async throws {
        try await open()
        try tapRow(SettingsItems.idResetTip)
        await waitUntil("成功提示没有出现") { !self.toasts.isEmpty }
        XCTAssertEqual(toasts.last, try settings.deps.texts.text(SettingsController.resetDoneKey))
        let ticked = await green()
        XCTAssertTrue(ticked, "成功带对勾")
        let host = try XCTUnwrap(page)
        await quietWindow(2.2)
        toasts = []
        host.script.fail("DELETE /v1/me/tips/jump_tip", 42901, headers: ["Retry-After": "20"])
        try tapRow(SettingsItems.idResetTip)
        await waitUntil("限流提示没有出现") { !self.toasts.isEmpty }
        let limited = await green()
        XCTAssertFalse(limited, "限流不带对勾")
        XCTAssertTrue(host.fixture.router.path.last?.route == "Settings", "不跳页")
    }

    /// 昵称已修改：回到设置页、带对勾、只提示一次。
    func testNicknameSavedToast() async throws {
        try await openNickname(waitFor: nil)
        toasts = []
        try await save(SettingsVisualData.nickname("saved"), reply: .success(data: Data("{}".utf8), traceId: nil,
                                                                             idempotencyKey: nil))
        await waitUntil("昵称已修改没有出现") { !self.toasts.isEmpty }
        XCTAssertEqual(toasts, [try settings.deps.texts.text(SettingsController.savedKey)])
        let ticked = await green()
        XCTAssertTrue(ticked, "带对勾")
        await quietWindow(0.5)
        XCTAssertEqual(toasts.count, 1, "一次")
    }

    /// 切换失败：回原值、提示、不带对勾（现状带）。
    func testSwitchFailedNoTick() async throws {
        try await openNotify(Setup(push: "granted"))
        let host = try XCTUnwrap(page)
        host.fixture.notify.putReply = .failure(code: 50001, msg: "", data: nil, traceId: nil,
                                                effect: ErrorEffect(code: 50001, kind: .toast), idempotencyKey: nil)
        let notify = try XCTUnwrap(try settings.notify)
        NotifyActions.make(notify, notify.state).toggle(false)
        await waitUntil("失败提示没有出现") { !self.toasts.isEmpty }
        XCTAssertEqual(notify.state.service, true, "回原值")
        let ticked = await green()
        XCTAssertFalse(ticked, "失败不带对勾")
    }

    /// 同一条提示只走一个出口（设置一族用 DS 礼貌播报，`MeAnnounce` 不再播一遍；Android r1 S2 同类）。
    func testToastHasSingleOutlet() async throws {
        try await open()
        try tapRow(SettingsItems.idResetTip)
        await waitUntil("提示没有出现") { !self.toasts.isEmpty }
        await quietWindow(0.5)
        XCTAssertEqual(toasts.count, 1)
        XCTAssertFalse(announcements.contains { $0.text == self.toasts[0] }, "没有第二个播报出口")
    }

    /// 换身份：上一账号的提示不带到新身份（`.id(host.serial)` 整页重建；现状已符合、换写法后守卫）。
    func testToastDroppedOnIdentityChange() async throws {
        try await open()
        let host = try XCTUnwrap(page)
        let before = try settings
        try tapRow(SettingsItems.idResetTip)
        await waitUntil("提示没有出现") { !self.toasts.isEmpty }
        host.script.ok("GET /v1/me", MeSamples.me(account: "user-b", nickname: "B 用户"))
        try host.fixture.switchAccount(to: "user-b")
        await waitUntil("身份没换代") { host.fixture.me.currentIdentity.account == "user-b" }
        XCTAssertTrue(before.hasLeft, "旧执行器作废")
        await quietWindow(0.7)
        let image = try XCTUnwrap(host.render())
        XCTAssertEqual(toastGreen(image), 0, "新身份下没有上一账号的提示")
    }
}

/// 只挂一个常显轻提示。
private struct SettingsToastSample: View {
    @State var message: CouliToastMessage?

    var body: some View {
        Color.clear.couliToast($message, duration: 30)
    }
}
