import Foundation
import HomeCore
import UIKit
import XCTest

/// r2 S1-A（D10-270）：信息流超过 10 行时的窗口化路径。真实 HomeSduiScreen、UIWindow、UIScrollView：
/// 4 页 × 20 件（40 行）由真实加载行逐页翻到底，再逐屏滚回顶部。
/// - 位置不跳：滚动期间测试设的 contentOffset 不被改动；内容总高不变；每张卡回到实际布局时，内容坐标里的顶边与第一次布局时一致（≤0.5pt）。
/// - 同时布局的卡数有上限：每次停稳后实际布局的商品卡不超过「6 屏能放下的行」；任何瞬间（每次上报都计峰值）不超过
///   「6 屏 + 新到一页」；在底部时远处的卡确实被换成了占位。
/// - 占位恢复：滚回视口的行都是实际商品卡（视口里没有空占位），回到顶部后曾被换成占位的第一行恢复成实际商品卡。
/// 读屏与点击（打开商品）要 App 的读屏树（单元测试进程里为空），见 CouliUITests/HomeVisualFeedWindowUITests。
@MainActor
final class HomeVisualFeedWindowTests: XCTestCase {
    private static let pages = 4
    private static let perPage = 20
    /// 每次滚动停稳后实际布局的商品卡数的最大值（停稳后新到的行已量完，只剩窗口内的行）。
    private var settledPeak = 0

    override func setUp() {
        HomeColorBlockImages.install()
    }

    override func tearDown() {
        HomeColorBlockImages.uninstall()
    }

    func testLongFeedScrollsToBottomAndBackWithoutJumpWithBoundedCardsAndRestoredRows() async throws {
        let port = try HomeVisualLongFeedPort(pages: Self.pages, perPage: Self.perPage)
        let fixture = try HomeVisualFixture(portOverride: port)
        addTeardownBlock { @MainActor in await fixture.close() }
        await fixture.start()
        XCTAssertEqual(fixture.controller.state.section("feed")?.items.count, Self.perPage)

        let view = HomeVisualWindowHost(controller: fixture.controller)
        defer { view.close() }
        var tops: [String: CGFloat] = [:]
        let bottom = try await scrollDown(view, fixture: fixture, tops: &tops)
        let total = Self.pages * Self.perPage
        XCTAssertEqual(port.itemCalls, ["feed|", "feed|w1", "feed|w2", "feed|w3"], "4 页都由真实加载行请求、各一次")
        XCTAssertEqual(tops.count, total, "每件商品都至少实际布局过一次")

        let cap = try capacity(tops) + Self.perPage
        XCTAssertLessThan(cap, total, "前提：上限必须小于总件数，否则断言没有意义")
        XCTAssertLessThanOrEqual(view.peak, cap,
                                 "同时实际布局的商品卡（峰值 \(view.peak)）超过「6 屏 + 新到一页」的 \(cap) 张")
        XCTAssertLessThanOrEqual(settledPeak, cap - Self.perPage,
                                 "停稳后实际布局的商品卡（最多 \(settledPeak)）超过 6 屏能放下的 \(cap - Self.perPage) 张")
        let parked = Set(tops.keys).subtracting(bottom.cards.keys)
        XCTAssertTrue(parked.contains(card(0)), "滚到底后第一行必须已换成占位（窗口化生效）")
        XCTAssertGreaterThanOrEqual(parked.count, total / 2, "到底时被换成占位的卡（\(parked.count)）太少")

        let top = try await scrollUp(view, from: bottom, tops: tops)
        let restored = parked.intersection(top.cards.keys)
        XCTAssertTrue(restored.contains(card(0)) && restored.contains(card(1)), "回到顶部后第一行必须恢复成实际商品卡")
        XCTAssertTrue(HomeColorBlockImages.unexpected.isEmpty)
    }

    /// 每次往下滚 0.4 屏，直到 4 页全部合入、滚到最底。返回到底时的状态；`tops` 记下每张卡第一次实际布局时的内容顶边。
    private func scrollDown(_ view: HomeVisualWindowHost, fixture: HomeVisualFixture,
                            tops: inout [String: CGFloat]) async throws -> HomeVisualWindowHost.Frame {
        var frame = try await view.settled()
        for _ in 0..<400 {
            record(frame, into: &tops)
            let feed = fixture.controller.state.section("feed")
            if feed?.feed?.exhausted == true, feed?.items.count == Self.pages * Self.perPage,
               frame.offset >= frame.maxOffset - 0.5 {
                return frame
            }
            let target = min(frame.offset + frame.viewport.height * 0.4, frame.maxOffset)
            frame = try await view.scroll(to: target)
            XCTAssertEqual(frame.offset, target, accuracy: 0.5, "往下滚时偏移被改动")
        }
        XCTFail("400 步内没有滚到信息流底部")
        throw WindowTestError.notReached
    }

    /// 每次往上滚 0.4 屏到顶。每一步：偏移不被改动、内容总高不变、实际布局的卡顶边与第一次一致、视口里没有空占位。
    private func scrollUp(_ view: HomeVisualWindowHost, from bottom: HomeVisualWindowHost.Frame,
                          tops: [String: CGFloat]) async throws -> HomeVisualWindowHost.Frame {
        var frame = bottom
        while frame.offset > 0 {
            let target = max(0, frame.offset - frame.viewport.height * 0.4)
            frame = try await view.scroll(to: target)
            let step = "回滚到 \(Int(target))"
            settledPeak = max(settledPeak, frame.cards.count)
            XCTAssertEqual(frame.offset, target, accuracy: 0.5, "\(step)：偏移被改动（位置跳）")
            XCTAssertEqual(frame.contentHeight, bottom.contentHeight, accuracy: 0.5, "\(step)：内容总高变了（占位高度不对）")
            for (key, rect) in frame.cards {
                let first = try XCTUnwrap(tops[key], "\(step)：\(key) 没有记录")
                XCTAssertEqual(rect.minY, first, accuracy: 0.5, "\(step)：\(key) 的内容顶边与第一次布局不一致（内容跳动）")
            }
            let blank = frame.visible(tops).filter { frame.cards[$0] == nil }
            XCTAssertTrue(blank.isEmpty, "\(step)：视口里的行仍是空占位：\(blank.sorted())")
        }
        return frame
    }

    private func record(_ frame: HomeVisualWindowHost.Frame, into tops: inout [String: CGFloat]) {
        settledPeak = max(settledPeak, frame.cards.count)
        for (key, rect) in frame.cards {
            if let first = tops[key] {
                XCTAssertEqual(rect.minY, first, accuracy: 0.5, "往下滚时 \(key) 的内容顶边变了")
            } else {
                tops[key] = rect.minY
            }
        }
    }

    /// 上限的窗口部分：6 屏（视口上方 2 屏 + 视口 + 下方 3 屏）内按最矮行距能放下的行，每行两张，再加首尾各一行余量。
    /// 调用方再加一页（20 件）：新到一页的行还没量过高度，按实现约定先全部实际布局、量完才可能换占位，这是有界的瞬时峰值。
    /// 上限与总件数无关：全量布局（不窗口化）时 80 张全在，必然超过。
    private func capacity(_ tops: [String: CGFloat]) throws -> Int {
        let rows = Set(tops.values.map { ($0 * 2).rounded() / 2 }).sorted()
        let pitches = zip(rows.dropFirst(), rows).map { $0 - $1 }.filter { $0 > 1 }
        let pitch = try XCTUnwrap(pitches.min(), "行距没有量到")
        return (Int((844 * 6 / pitch).rounded(.up)) + 2) * 2
    }

    private func card(_ index: Int) -> String {
        "home.product.feed.\(index)"
    }

    private enum WindowTestError: Error {
        case notReached
    }
}
