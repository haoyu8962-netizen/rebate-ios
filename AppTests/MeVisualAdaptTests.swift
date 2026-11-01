@testable import Couli
import DesignSystem
import Foundation
import MeCore
import SwiftUI
import UIKit
import XCTest

/// APP-12v 大字号 / 窄屏 / 大屏（brief §2.1、§4.6、§4.7；AX3 ≈ 200%）。不截断不缩小：宽度与位置都比（APP-11v-b r2），金额加像素判据；字号确实放大。
/// 进程内用 `.environment(\.dynamicTypeSize)`：本页没有半屏（`.dynamicTypeSize` 进不了 `.sheet` 的坑不涉及）。
@MainActor
final class MeVisualAdaptTests: MeVisualTestCase {
    private let ax3 = DynamicTypeSize.accessibility3

    private func large(_ width: CGFloat, height: CGFloat = 2600, profile: String = "me_long", hidden: Bool = false,
                       guide: Bool = false) -> Setup {
        Setup(profile: profile, canvas: .init(width: width, height: height, size: ax3), hidden: hidden, guide: guide)
    }

    func testAX3W390Member() async throws {
        try await assertMember(width: 390)
    }

    func testAX3W320Member() async throws {
        try await assertMember(width: 320)
    }

    /// 昵称 16 字折行不省略；码 + 邀请人换行、复制紧随码；复制命中区不盖邀请人；金额 / 按钮完整；眼睛与【提现】不重叠；宫格 2 列不截断。
    private func assertMember(width: CGFloat, file: StaticString = #filePath, line: UInt = #line) async throws {
        let (_, image) = try await open(large(width), waitFor: "me.cell.设置.icon", file: file, line: line)
        let identity = try rect("me.identity", file: file, line: line)
        let name = try record("me.nickname", file: file, line: line)
        XCTAssertGreaterThan(name.fontSize, name.baseFontSize * 1.3, "昵称真放大", file: file, line: line)
        XCTAssertEqual(name.text.count, 16, "16 字", file: file, line: line)
        try assertWhole("me.nickname", inside: identity, "昵称", file: file, line: line)
        try assertInviteWrap(identity: identity, file: file, line: line)
        try await assertHero(image, file: file, line: line)
        let order = try rect("me.cell.我的订单", file: file, line: line)
        let wallet = try rect("me.cell.钱包", file: file, line: line)
        let ledger = try rect("me.cell.余额流水", file: file, line: line)
        XCTAssertTrue(sameRow(order, wallet), "第一行两格", file: file, line: line)
        XCTAssertGreaterThanOrEqual(ledger.minY, order.maxY - 0.5, "降列：第三格另起一行", file: file, line: line)
    }

    private func assertInviteWrap(identity: CGRect, file: StaticString, line: UInt) throws {
        let code = try record("me.invite.code", file: file, line: line)
        XCTAssertGreaterThan(code.fontSize, code.baseFontSize * 1.3, "码真放大", file: file, line: line)
        XCTAssertEqual(code.text, "K7M3QX", "码不拆不省略", file: file, line: line)
        assertInside(code.rect, identity, "码在卡内", file: file, line: line)
        let copy = try rect("me.invite.copy", file: file, line: line)
        XCTAssertTrue(sameRow(code.rect, copy), "换行后复制仍紧随码", file: file, line: line)
        XCTAssertGreaterThanOrEqual(copy.minX, code.rect.maxX - 0.5, "复制在码之后", file: file, line: line)
        XCTAssertLessThanOrEqual(copy.minX - code.rect.maxX, 16, "复制紧随码", file: file, line: line)
        assertInside(copy, identity, "复制在卡内", file: file, line: line)
        let hit = try rect("me.invite.copy.hit", file: file, line: line)
        try assertHit("me.invite.copy.hit", covers: "me.invite.copy", "复制", file: file, line: line)
        assertDisjoint(
            hit,
            try rect("me.invite.inviter", file: file, line: line),
            "复制命中区不盖「邀请人」",
            file: file,
            line: line
        )
        assertDisjoint(hit, try rect("me.nickname", file: file, line: line), "复制命中区不盖昵称", file: file, line: line)
        try assertWhole("me.invite.inviter", inside: identity, "邀请人", file: file, line: line)
    }

    private func assertHero(_ image: UIImage, file: StaticString, line: UInt) async throws {
        let hero = try rect("me.hero", file: file, line: line)
        let solid = pixel(CouliColor.token("rebate.solid.background"), dark: false)
        let amount = try record("me.hero.amount", file: file, line: line)
        XCTAssertGreaterThan(amount.fontSize, amount.baseFontSize * 1.3, "大数真放大", file: file, line: line)
        // 比卡内可用宽还宽时沿用 DS AmountText「不截断、不缩字、段内折行」（钱包 a v2 同口径）
        if amount.naturalWidth > hero.width - 40 + 0.5 {
            try await assertWrappedAmount("me.hero.amount", inside: hero, image: image, background: solid, "大数（段内折行）",
                                          file: file, line: line)
        } else {
            try assertWholeAmount("me.hero.amount", inside: hero, "大数", file: file, line: line)
            try assertAmountInkFillsFrame(
                "me.hero.amount",
                image: image,
                background: solid,
                "大数",
                file: file,
                line: line
            )
        }
        try assertWholeAmount("me.estimate.value", inside: hero, "预估", file: file, line: line)
        try assertAmountInkFillsFrame(
            "me.estimate.value",
            image: image,
            background: solid,
            "预估",
            file: file,
            line: line
        )
        let label = try record("me.hero.withdraw.label", file: file, line: line)
        XCTAssertGreaterThanOrEqual(label.rect.width + 0.5, label.naturalWidth, "【提现】字不截断", file: file, line: line)
        let button = try rect("me.hero.withdraw", file: file, line: line)
        assertInside(button, hero, "【提现】在主卡内", file: file, line: line)
        try assertHit("me.hero.eye.hit", covers: "me.hero.eye", "眼睛", file: file, line: line)
        assertDisjoint(try rect("me.hero.eye.hit", file: file, line: line), button, "眼睛 / 【提现】", file: file, line: line)
        assertDisjoint(
            try rect("me.hero.eye.hit", file: file, line: line),
            amount.rect,
            "眼睛 / 大数",
            file: file,
            line: line
        )
    }

    /// 隐藏 + 引导条：整句完整（在条内、不被关闭压住）、关闭与正文命中不重叠；金额遮罩放大后完整。
    func testAX3HiddenGuide() async throws {
        for width in [390, 320] as [CGFloat] {
            try await open(large(width, profile: "me_member", hidden: true, guide: true), waitFor: "me.guideBar.text")
            let bar = try rect("me.guideBar")
            try assertWhole("me.guideBar.text", inside: bar, "\(width) 正文")
            let item = try record("me.guideBar.text")
            XCTAssertGreaterThan(item.fontSize, item.baseFontSize * 1.3, "\(width) 正文真放大")
            let close = try rect("me.guideBar.close.hit")
            assertDisjoint(try rect("me.guideBar.open.hit"), close, "\(width) 正文 / 关闭 命中区")
            assertDisjoint(item.rect, close, "\(width) 正文不被关闭压住")
            XCTAssertEqual(try text("me.hero.amount"), MeView.mask)
            XCTAssertEqual(try text("me.estimate.value"), MeView.mask)
        }
    }

    /// 游客：标题、说明完整，【登录 / 注册】完整。
    func testAX3Guest() async throws {
        for width in [390, 320] as [CGFloat] {
            let setup = Setup(
                profile: nil,
                canvas: .init(width: width, height: 1400, size: ax3),
                guest: true,
                phase: nil
            )
            try await open(setup, waitFor: "me.guest.login")
            let card = try rect("me.guest")
            try assertWhole("me.guest.title", inside: card, "\(width) 标题")
            try assertWhole("me.guest.desc", inside: card, "\(width) 说明")
            assertInside(try rect("me.guest.login"), card, "\(width) 按钮")
            XCTAssertGreaterThanOrEqual(try rect("me.guest.login").height, 47.5, "\(width) 按钮高")
        }
    }

    /// 840：内容限宽 600 居中（现状已符合、加守卫）。
    func testW840ContentWidth() async throws {
        try await open(Setup(canvas: .init(width: 840, height: 1000)), waitFor: "me.grid.more")
        for id in ["me.identity", "me.hero", "me.grid.more"] {
            let box = try rect(id)
            XCTAssertLessThanOrEqual(box.width, 600.5, "\(id) 限宽 600")
            assertNear(box.midX, 420, 1, "\(id) 居中")
        }
    }

    /// 切 Tab 往返保持滚动位置（§9 第 7 条，现状已符合、加守卫）：iOS 外壳是 TabView，切走不销毁 Tab 根，这里同样不重挂窗口；回来按新的一次进入
    /// 换执行器、重取 Me 之后，位置与最上面那一块都不变。
    func testScrollKeptAcrossTabs() async throws {
        let (host, _) = try await open(Setup(canvas: .init(height: 600)), waitFor: nil)
        let scroller = try XCTUnwrap(host.scroller, "没有滚动视图")
        scroller.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
        _ = try await frame()
        let anchor = try XCTUnwrap(host.fixture.me.scroll.anchor(for: host.controller.identity), "没有记下位置")
        XCTAssertNotEqual(anchor, "me.section.top", "已滚动")
        let first = host.controller
        let reads = meReads
        _ = host.fixture.routing.selectTab(.home)
        await settle()
        _ = host.fixture.routing.selectTab(.me)
        await waitUntil("回来没有重取") { self.meReads == reads + 1 && host.controller !== first }
        _ = try await frame { $0.repo.state.phase == .content }
        XCTAssertEqual(host.fixture.me.scroll.anchor(for: host.controller.identity), anchor, "同一可见首项")
        XCTAssertEqual(scroller.contentOffset.y, 200, accuracy: 2, "位置不变")
    }
}
