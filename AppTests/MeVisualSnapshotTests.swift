@testable import Couli
import DesignSystem
import Foundation
import MeCore
import SnapshotTesting
import SwiftUI
import UIKit
import XCTest

/// APP-12v「我的」整页基准（brief §5；名字与 Android `app/src/test/snapshots/me-v/` 同名）：真实 App 组装、visualMe 同一份数据。
/// 默认只比对（缺图失败）；`TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1` 只录缺图，基准由实现者录。容差 precision 0.99、perceptual 0.98（与钱包组同一口径）。
/// 每张都等「两帧一致」+ 就绪条件 + 比对前过 `WithdrawVisualRenderJudge`（全黑 / 单色判红，录基准时同样拦住）。
@MainActor
final class MeVisualSnapshotTests: MeVisualTestCase {
    struct Shot {
        let name: String
        var setup = Setup()
        /// 就绪条件：该状态特有的测量编号（必须给）。
        let ready: String
        /// 打开之后的一步（轻提示）；返回等到第几条提示。
        var after: (@MainActor (MeVisualHost) async -> Void)?
    }

    func testArtboards() async throws {
        let publicRoutes = try MeVisualData.routes("routes_public")
        try await run([
            Shot(name: "Me-light", ready: "me.hero"),
            Shot(name: "MeEarningsEntry-earnings-only-light",
                 setup: Setup(custom: true, routes: publicRoutes, earnings: true), ready: "me.cell.收益看板"),
            Shot(name: "MeGuest-light", setup: Setup(profile: nil, canvas: .init(height: 844), guest: true, phase: nil),
                 ready: "me.guest.login"),
            Shot(name: "MeHidden-light", setup: Setup(canvas: .init(height: 1110), hidden: true, guide: true),
                 ready: "me.guideBar"),
            Shot(
                name: "MeInviteBackfill-v2-identity-GM06-light",
                setup: Setup(profile: "me_new_user"),
                ready: "me.hero"
            ),
            Shot(name: "MeMinor-GM08-light", setup: Setup(profile: "me_no_invite_code"), ready: "me.hero"),
            Shot(name: "MeStates-negative-GM03-light", setup: Setup(profile: "me_negative"), ready: "me.hero"),
            Shot(name: "MeStates-no-switch-field-GM03-light", ready: "me.hero"),
            Shot(name: "MeStates-frozen-GM04-light", setup: Setup(profile: "me_frozen"), ready: "me.hero"),
            Shot(name: "MeDark-dark", setup: Setup(canvas: .init(dark: true)), ready: "me.hero"),
        ])
    }

    /// 轻提示样式（G-M12）、复制失败、刷新失败（浅深各一）。轻提示只显示约 2 秒，文字固定 trace6（stub 固定 6789ab）。
    func testToasts() async throws {
        let copy: @MainActor (MeVisualHost) async -> Void = { $0.actions.copyInvite() }
        let copyFailed: @MainActor (MeVisualHost) async -> Void = { host in
            host.fixture.ledgerStore.failWrites = true
            host.actions.copyInvite()
        }
        let refreshFailed: @MainActor (MeVisualHost) async -> Void = { host in
            host.script.fail("GET /v1/me", 50001)
            host.actions.refresh()
        }
        try await run([
            Shot(name: "MeInviteBound-copy-style-GM06-GM12-light", ready: "me.hero", after: copy),
            Shot(name: "state-copy-failed-light", ready: "me.hero", after: copyFailed),
            Shot(name: "state-refresh-failed-toast-light", ready: "me.hero", after: refreshFailed),
            Shot(name: "state-refresh-failed-toast-dark", setup: Setup(canvas: .init(dark: true)), ready: "me.hero",
                 after: refreshFailed),
        ])
    }

    /// 页面级状态（无稿）。整页错误沿用 DS ErrorState（G-M11）。
    func testPageStates() async throws {
        let server = WalletStubProtocol.Reply.envelope(code: 50001, data: "null", headers: [:])
        let limited = WalletStubProtocol.Reply.envelope(code: 42901, data: "null", headers: ["Retry-After": "30"])
        try await run([
            Shot(name: "state-loading-light", setup: Setup(reply: .hold, phase: .loading), ready: "me.skeleton.grid"),
            Shot(name: "state-loading-dark", setup: Setup(canvas: .init(dark: true), reply: .hold, phase: .loading),
                 ready: "me.skeleton.grid"),
            Shot(name: "state-restricted-light", setup: Setup(profile: nil, scope: "deletion_only", phase: nil),
                 ready: "me.skeleton.grid"),
            Shot(name: "StateLoadFailed-GM11-light", setup: Setup(reply: server, phase: .error), ready: "me.error"),
            Shot(
                name: "StateLoadFailed-GM11-dark",
                setup: Setup(canvas: .init(dark: true), reply: server, phase: .error),
                ready: "me.error"
            ),
            Shot(
                name: "StateNetworkError-GM11-light",
                setup: Setup(reply: .disconnect, phase: .error),
                ready: "me.error"
            ),
            Shot(name: "state-blocked-retry-light", setup: Setup(reply: limited, phase: .error), ready: "me.error"),
        ])
    }

    /// 适配：AX3（≈ 200%）× 390 / 320、840 大屏。
    func testAdaptation() async throws {
        let ax = DynamicTypeSize.accessibility3
        func member(_ width: CGFloat, _ height: CGFloat, dark: Bool = false) -> Setup {
            Setup(profile: "me_long", canvas: .init(width: width, height: height, dark: dark, size: ax))
        }
        func guest(_ width: CGFloat) -> Setup {
            Setup(profile: nil, canvas: .init(width: width, height: 1400, size: ax), guest: true, phase: nil)
        }
        func hidden(_ width: CGFloat, _ height: CGFloat) -> Setup {
            Setup(canvas: .init(width: width, height: height, size: ax), hidden: true, guide: true)
        }
        try await run([
            Shot(name: "Me-font200-w390-light", setup: member(390, 2300), ready: "me.hero"),
            Shot(name: "Me-font200-w390-dark", setup: member(390, 2300, dark: true), ready: "me.hero"),
            Shot(name: "Me-font200-w320-light", setup: member(320, 2600), ready: "me.hero"),
            Shot(name: "MeGuest-font200-w390-light", setup: guest(390), ready: "me.guest.login"),
            Shot(name: "MeGuest-font200-w320-light", setup: guest(320), ready: "me.guest.login"),
            Shot(name: "MeHidden-font200-w390-light", setup: hidden(390, 2500), ready: "me.guideBar"),
            Shot(name: "MeHidden-font200-w320-light", setup: hidden(320, 2700), ready: "me.guideBar"),
            Shot(name: "Me-w840-light", setup: Setup(canvas: .init(width: 840, height: 1000)), ready: "me.hero"),
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
        let (host, first) = try await open(shot.setup, waitFor: shot.ready, file: file, line: line)
        var image = first
        if let after = shot.after {
            toasts = []
            await after(host)
            await waitUntil("\(shot.name)：轻提示没有出现", timeout: 6, file: file, line: line) { !self.toasts.isEmpty }
            image = try await frame(file: file, line: line)
        }
        XCTAssertEqual(image.size, CGSize(width: shot.setup.canvas.width, height: shot.setup.canvas.height),
                       "\(shot.name)：画布尺寸", file: file, line: line)
        let problems = WithdrawVisualRenderJudge.problems(image)
        XCTAssertEqual(problems, [], "\(shot.name)：没有画出页面", file: file, line: line)
        guard problems.isEmpty else { return }
        withSnapshotTesting(record: ProcessInfo.processInfo
            .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: shot.name,
                               file: file, testName: testName, line: line)
            }
    }
}
