@testable import Couli
import DesignSystem
import Foundation
import MeCore
import SnapshotTesting
import SwiftUI
import UIKit
import XCTest

/// APP-12w-a 设置一族整页基准（brief §5；名字尽量与 Android `app/src/test/snapshots/settings-v/` 同名）：真实 App 组装、visualSettings 同一份数据。
/// 默认只比对（缺图失败）；`TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1` 只录缺图，基准由实现者录。容差 precision 0.99、perceptual 0.98（同「我的」组）。
/// 每张都等稳定 + 就绪条件 + 过 `WithdrawVisualRenderJudge`（全黑 / 单色判红，录基准时同样拦住）。
/// 不拍：SettingsClipboardConsent（D10-423 作废）、SettingsDeletionWithdrawn（iOS 没有触发链，交回 §6）、授权管理（G-S01）。
@MainActor
final class SettingsVisualSnapshotTests: SettingsVisualTestCase {
    typealias Step = @MainActor (SettingsVisualSnapshotTests) async throws -> Void

    struct Shot {
        let name: String
        var setup = Setup()
        /// 打开设置页后的一步（进子页、开弹层、出提示）。
        var step: Step?
        /// 就绪条件：该状态特有的测量编号（必须给）。
        let ready: String
        /// 这一步会出轻提示：等它出现再取帧。
        var toast = false
    }

    private static let ax3 = DynamicTypeSize.accessibility3

    private func publicSetup(dark: Bool = false, width: CGFloat = 390, height: CGFloat = 1100,
                             size: DynamicTypeSize = .large, profile: String = "settings_member") throws -> Setup {
        try Setup(profile: profile, canvas: .init(width: width, height: height, dark: dark, size: size),
                  routes: publicRoutes())
    }

    private static let toNickname: Step = { test in try test.tapRow(SettingsItems.idNickname) }
    private static let toNotify: Step = { test in try test.tapRow(SettingsItems.idNotify) }
    private static let toAgreement: Step = { test in try test.tapRow(SettingsItems.idAgreement) }
    private static let toClear: Step = { test in try test.tapRow(SettingsItems.idClearCache) }
    private static let toLogout: Step = { test in try test.actions.askLogout() }

    private static func limit(_ test: SettingsVisualSnapshotTests) async throws {
        try test.tapRow(SettingsItems.idNickname)
        try await test.save(SettingsVisualData.nicknameInput("limit"), reply: SettingsVisualData.limit)
    }

    func testMainBoards() async throws {
        let guest = Setup(level: .guest, canvas: .init(height: 900))
        let basic = Setup(level: .basic, canvas: .init(height: 900))
        try await run([
            Shot(name: "Settings-v2-light", setup: publicSetup(), ready: "settings.logout.button"),
            Shot(name: "settings-beta-no-delete-light", ready: "settings.logout.button"),
            Shot(name: "SettingsDark-dark", setup: publicSetup(dark: true), ready: "settings.logout.button"),
            Shot(name: "SettingsGuest-v2-order-GS03-light", setup: guest, ready: "settings.guest.link"),
            Shot(name: "SettingsBasic-order-GS03-light", setup: basic, ready: "settings.basic.notice"),
        ])
    }

    func testOverlays() async throws {
        let dark = Setup(canvas: .init(dark: true))
        let clear: Step = { test in
            try test.tapRow(SettingsItems.idClearCache)
            try test.actions.confirmClear(XCTUnwrap(try test.settings.state.dialog))
        }
        let reset: Step = { test in try test.tapRow(SettingsItems.idResetTip) }
        let limited: Step = { test in
            test.page?.script.fail("DELETE /v1/me/tips/jump_tip", 42901, headers: ["Retry-After": "20"])
            try test.tapRow(SettingsItems.idResetTip)
        }
        try await run([
            Shot(name: "SettingsAgreementSheet-v2-light", step: Self.toAgreement, ready: "settings.sheet.panel"),
            Shot(name: "SettingsClearCache-v2-light", step: Self.toClear, ready: "settings.dialog.clear.panel"),
            Shot(name: "SettingsLogoutConfirm-v2-light", step: Self.toLogout, ready: "settings.dialog.logout.panel"),
            Shot(name: "SettingsLogoutConfirm-dark", setup: dark, step: Self.toLogout,
                 ready: "settings.dialog.logout.panel"),
            Shot(name: "SettingsCacheCleared-v2-light", step: clear, ready: "settings.row.clear_cache", toast: true),
            Shot(name: "settings-reset-tip-toast-light", step: reset, ready: "settings.row.reset_tip", toast: true),
            Shot(
                name: "settings-rate-limited-toast-light",
                step: limited,
                ready: "settings.row.reset_tip",
                toast: true
            ),
        ])
    }

    func testNicknameBoards() async throws {
        let plain = Setup(canvas: .init(height: 844))
        let dark = Setup(canvas: .init(height: 844, dark: true))
        let sensitive: Step = { test in
            try test.tapRow(SettingsItems.idNickname)
            try await test.save(SettingsVisualData.nicknameInput("sensitive"), reply: SettingsVisualData.sensitive)
        }
        let long: Step = { test in
            try test.tapRow(SettingsItems.idNickname)
            try test.nicknameActions.input(SettingsVisualData.nickname("tooLong"))
        }
        let saved: Step = { test in
            // 保存后设置页会再读 Me：回答要带新昵称，否则行值显示旧昵称（夹具问题，不是产品差距）
            try test.page?.script.ok("GET /v1/me", MeSamples.me(nickname: SettingsVisualData.nickname("saved")))
            try test.tapRow(SettingsItems.idNickname)
            try await test.save(SettingsVisualData.nickname("saved"),
                                reply: .success(data: Data("{}".utf8), traceId: nil, idempotencyKey: nil))
        }
        try await run([
            Shot(name: "SettingsNickname-light", setup: plain, step: Self.toNickname, ready: "nickname.bar"),
            Shot(name: "SettingsNicknameLimit-save-enabled-GS10-light", setup: plain, step: Self.limit,
                 ready: "nickname.error"),
            Shot(name: "SettingsNicknameLimit-dark", setup: dark, step: Self.limit, ready: "nickname.error"),
            Shot(name: "SettingsNicknameSensitive-light", setup: plain, step: sensitive, ready: "nickname.error"),
            Shot(name: "nickname-too-long-light", setup: plain, step: long, ready: "nickname.error"),
            Shot(name: "SettingsNicknameSaved-v2-light", step: saved, ready: "settings.row.nickname", toast: true),
        ])
    }

    func testNotifyBoards() async throws {
        func setup(_ push: String, dark: Bool = false, noSwitch: Bool = false) -> Setup {
            Setup(canvas: .init(height: 844, dark: dark), push: push, noSwitch: noSwitch)
        }
        try await run([
            Shot(name: "NotifySettings-light", setup: setup("permanently_denied"), step: Self.toNotify,
                 ready: "notify.goSettings.link"),
            Shot(name: "NotifySettingsOn-light", setup: setup("granted"), step: Self.toNotify, ready: "notify.card"),
            Shot(name: "NotifySettingsNotAsked-light", setup: setup("not_asked"), step: Self.toNotify,
                 ready: "notify.neutral"),
            Shot(name: "NotifySettingsDark-dark", setup: setup("permanently_denied", dark: true), step: Self.toNotify,
                 ready: "notify.goSettings.link"),
            Shot(name: "notify-release-no-switch-light", setup: setup("granted", noSwitch: true), step: Self.toNotify,
                 ready: "notify.desc"),
        ])
    }

    /// 无稿状态：账号资料加载中 / 失败（G-M11 口径，外观不改）。
    func testAccountStates() async throws {
        let server = WalletStubProtocol.Reply.envelope(code: 50001, data: "null", headers: [:])
        try await run([
            Shot(name: "settings-me-loading-light", setup: Setup(reply: .hold), ready: "settings.logout.button"),
            Shot(name: "settings-me-loading-dark", setup: Setup(canvas: .init(dark: true), reply: .hold),
                 ready: "settings.logout.button"),
            Shot(name: "settings-me-error-50001-light", setup: Setup(reply: server), ready: "settings.logout.button"),
        ])
    }

    /// AX3（≈ 200%）× 390 / 320、840 大屏。
    func testAdaptation() async throws {
        let ax3 = Self.ax3
        func member(_ width: CGFloat, _ height: CGFloat, dark: Bool = false) throws -> Setup {
            try publicSetup(dark: dark, width: width, height: height, size: ax3, profile: "settings_long_nickname")
        }
        let guest = Setup(level: .guest, canvas: .init(width: 320, height: 2400, size: ax3))
        let basic = Setup(level: .basic, canvas: .init(width: 320, height: 2000, size: ax3))
        let tall = Setup(canvas: .init(width: 320, height: 1400, size: ax3))
        try await run([
            Shot(name: "Settings-font200-w390-light", setup: member(390, 2700), ready: "settings.logout.button"),
            Shot(
                name: "Settings-font200-w390-dark",
                setup: member(390, 2700, dark: true),
                ready: "settings.logout.button"
            ),
            Shot(name: "Settings-font200-w320-light", setup: member(320, 2700), ready: "settings.logout.button"),
            Shot(name: "SettingsGuest-font200-w320-light", setup: guest, ready: "settings.guest.link"),
            Shot(name: "SettingsBasic-font200-w320-light", setup: basic, ready: "settings.basic.notice"),
            Shot(name: "SettingsAgreementSheet-font200-w320-light", setup: tall, step: Self.toAgreement,
                 ready: "settings.sheet.panel"),
            Shot(name: "SettingsLogoutConfirm-font200-w320-light", setup: tall, step: Self.toLogout,
                 ready: "settings.dialog.logout.panel"),
            Shot(name: "SettingsNicknameLimit-font200-w320-light", setup: tall, step: Self.limit,
                 ready: "nickname.error"),
            Shot(name: "NotifySettings-font200-w320-light", setup: tall, step: Self.toNotify,
                 ready: "notify.goSettings.link"),
            Shot(
                name: "Settings-w840-light",
                setup: publicSetup(width: 840, height: 1100),
                ready: "settings.logout.button"
            ),
            Shot(name: "SettingsNickname-w840-light", setup: Setup(canvas: .init(width: 840, height: 844)),
                 step: Self.toNickname, ready: "nickname.bar"),
        ])
    }

    // MARK: - 执行

    private func run(_ shots: [Shot], file: StaticString = #filePath, testName: String = #function,
                     line: UInt = #line) async throws {
        for shot in shots {
            try await take(shot, file: file, testName: testName, line: line)
        }
    }

    private func take(_ shot: Shot, file: StaticString, testName: String, line: UInt) async throws {
        XCTAssertFalse(shot.ready.isEmpty, "\(shot.name)：必须给就绪条件", file: file, line: line)
        toasts = []
        try await open(shot.setup, file: file, line: line)
        toasts = []
        if let step = shot.step {
            try await step(self)
        }
        if shot.toast {
            await waitUntil("\(shot.name)：轻提示没有出现", timeout: 6, file: file, line: line) { !self.toasts.isEmpty }
        }
        let image = try await frame(shot.ready, file: file, line: line)
        compare(image, named: shot.name, canvas: shot.setup.canvas, file: file, testName: testName, line: line)
    }

    private func compare(_ image: UIImage, named name: String, canvas: SettingsVisualHost.Canvas,
                         file: StaticString = #filePath, testName: String = #function, line: UInt = #line) {
        XCTAssertEqual(image.size, CGSize(width: canvas.width, height: canvas.height), "\(name)：画布尺寸", file: file,
                       line: line)
        let problems = WithdrawVisualRenderJudge.problems(image)
        XCTAssertEqual(problems, [], "\(name)：没有画出页面", file: file, line: line)
        guard problems.isEmpty else { return }
        withSnapshotTesting(record: ProcessInfo.processInfo
            .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: name,
                               file: file, testName: testName, line: line)
            }
    }
}
