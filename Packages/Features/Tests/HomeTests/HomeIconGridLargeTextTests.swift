import DesignSystem
import Foundation
@testable import Home
import HomeCore
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-ADAPT-CHECK ③（QA-11 iOS #6：`Main320-200`、首页 font200 截图金刚区 5 列，格名「超 / 市 / 百 / 货」一行一个字）：
/// 大字号下金刚区每项格名不被拆成逐字竖排——每格可用宽度至少放得下格名前两个字（按格名实际字号：caption 12 随字号缩放）。
/// 放不下时可改列数、换行成每行两字以上，或别的不缩字做法；不准缩字。进程内用生产 `HomeSduiScreen` + 生产测量（`home.icon.<区段>.<序号>`）。
@MainActor
final class HomeIconGridLargeTextTests: XCTestCase {
    private struct Tier {
        let name: String
        let width: CGFloat
        let size: DynamicTypeSize
    }

    private let tiers = [
        Tier(name: "320 宽 + 200%（AX2）", width: 320, size: .accessibility2),
        Tier(name: "320 宽 + AX3", width: 320, size: .accessibility3),
        Tier(name: "390 + AX3", width: 390, size: .accessibility3),
        Tier(name: "AXXXL（AX5）390", width: 390, size: .accessibility5),
    ]

    override func setUp() {
        HomeColorBlockImages.install()
    }

    override func tearDown() {
        HomeColorBlockImages.uninstall()
    }

    func testIconTitlesNeverStackOneCharacterPerLine() async throws {
        for page in ["guest_v3", "main_v3"] {
            for tier in tiers {
                let fixture = try HomeVisualFixture(page: page)
                await fixture.start()
                let items = try XCTUnwrap(fixture.controller.state.section("icons")?.items, "前提：有金刚区")
                XCTAssertGreaterThanOrEqual(items.count, 5, "前提：金刚区至少一行 5 格")
                let records = await measure(fixture.controller, tier: tier, count: items.count)
                let size = Self.captionSize(tier.size)
                XCTAssertGreaterThan(size, 12 * 1.5, "\(tier.name)：格名字号真放大")
                for (index, item) in items.enumerated() {
                    let title = item.title ?? ""
                    guard title.count >= 2 else { continue }
                    guard let cell = records["home.icon.icons.\(index)"] else {
                        XCTFail("\(page) \(tier.name)：缺测量 home.icon.icons.\(index)")
                        continue
                    }
                    let pair = Self.width(String(title.prefix(2)), size: size)
                    XCTAssertGreaterThanOrEqual(
                        cell.rect.width + 0.5, pair,
                        "\(page) \(tier.name)：「\(title)」格宽 \(cell.rect.width) 放不下两个字（\(pair)）——逐字竖排"
                    )
                    XCTAssertLessThanOrEqual(cell.rect.maxX, tier.width + 0.5, "\(page) \(tier.name)：「\(title)」格出屏")
                }
                await fixture.close()
            }
        }
    }

    static func captionSize(_ size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return UIFontMetrics(forTextStyle: .caption1).scaledValue(for: CouliTextStyle.caption.baseSize,
                                                                  compatibleWith: traits)
    }

    static func width(_ text: String, size: CGFloat) -> CGFloat {
        let font = UIFont(name: "PingFangSC-Regular", size: size) ?? UIFont.systemFont(ofSize: size)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func measure(_ controller: HomeController, tier: Tier,
                         count: Int) async -> [String: CouliLayoutProbeRecord] {
        var records: [String: CouliLayoutProbeRecord] = [:]
        let probe = CouliLayoutProbe(report: { records[$0.id] = $0 }, remove: { records[$0] = nil })
        let root = HomeSduiScreen(controller: controller)
            .background(CouliColor.backgroundCanvas)
            .frame(width: tier.width, height: 3200)
            .environment(\.couliLayoutProbe, probe)
            .environment(\.dynamicTypeSize, tier.size)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: tier.width, height: 3200))
        let host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        let deadline = Date().addingTimeInterval(6)
        var previous: [String: CGRect] = [:]
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
            host.view.layoutIfNeeded()
            let cells = records.filter { $0.key.hasPrefix("home.icon.icons.") }.mapValues(\.rect)
            if cells.count >= count, cells == previous {
                break
            }
            previous = cells
        }
        // tests v2：先取结果再拆窗——拆窗触发各格 onDisappear，测量桥 remove 会清空记录（v1 因此怎么跑都报「缺测量」）。
        let taken = records
        window.isHidden = true
        window.rootViewController = nil
        return taken
    }
}
