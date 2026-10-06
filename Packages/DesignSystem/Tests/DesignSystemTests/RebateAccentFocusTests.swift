@testable import DesignSystem
import SwiftUI
import XCTest

/// 第 3 轮评审（ios-review-r2）的组件层约定：返利强调色的适用范围（R2-01）、价格口径 i 按钮的去留（R2-02）、
/// 错误态的播报与移焦（R2-03）。
final class RebateAccentFocusTests: XCTestCase {
    /// R2-01：返利强调色只给正金额（GUIDE §7.1「无返利 / 返利 ¥0 不用橙」）；标签、金额、钟表同一判定。
    func testRebateAccentOnlyForPositiveAmounts() {
        func item(_ value: AmountValue, rebate: Bool = true) -> AmountGridItem {
            AmountGridItem(label: "预估返", value: value, isRebate: rebate)
        }
        // 有效返利：用。
        XCTAssertTrue(item(.amount(269)).usesRebateAccent(amountHidden: false))
        XCTAssertTrue(item(.range(minFen: 123, maxFen: 234)).usesRebateAccent(amountHidden: false))
        XCTAssertTrue(item(.range(minFen: 0, maxFen: 234)).usesRebateAccent(amountHidden: false))
        XCTAssertTrue(item(.range(minFen: 45, maxFen: 45)).usesRebateAccent(amountHidden: false))
        // 零返利、暂无返利、异常数据、负数、纯文字：不用。
        XCTAssertFalse(item(.amount(0)).usesRebateAccent(amountHidden: false))
        XCTAssertFalse(item(.amount(-120)).usesRebateAccent(amountHidden: false))
        XCTAssertFalse(item(.range(minFen: 0, maxFen: 0)).usesRebateAccent(amountHidden: false))
        XCTAssertFalse(item(.range(minFen: 234, maxFen: 123)).usesRebateAccent(amountHidden: false))
        XCTAssertFalse(item(.range(minFen: -1, maxFen: 100)).usesRebateAccent(amountHidden: false))
        XCTAssertFalse(item(.text("暂无返利")).usesRebateAccent(amountHidden: false))
        XCTAssertEqual(AmountValue.range(minFen: 0, maxFen: 0).display(hidden: false), "暂无返利")
        // 非返利类：从不用。
        XCTAssertFalse(item(.amount(500), rebate: false).usesRebateAccent(amountHidden: false))
        XCTAssertFalse(item(.amount(500), rebate: false).usesRebateAccent(amountHidden: true))
        // 金额隐藏：金额 / 区间按类别（不让「****」的颜色泄露是否为 0），纯文字仍不用。
        XCTAssertTrue(item(.amount(0)).usesRebateAccent(amountHidden: true))
        XCTAssertTrue(item(.amount(269)).usesRebateAccent(amountHidden: true))
        XCTAssertFalse(item(.text("暂无返利")).usesRebateAccent(amountHidden: true))

        // RebateTag / 网格卡返利块：暂无返利（含异常降级）中性；金额、区间、金额未知、登录查看用返利色。
        func tag(_ basis: String, _ minFen: Int64?, _ maxFen: Int64?, login: Bool = false) -> RebateTagContent {
            RebateTagModel.make(basis: basis, minFen: minFen, maxFen: maxFen, loginRequired: login)
        }
        XCTAssertTrue(tag("normal", 45, 45).usesRebateAccent)
        XCTAssertTrue(tag("price_compare_risk", 0, 112).usesRebateAccent)
        XCTAssertFalse(tag("normal", 0, 0).usesRebateAccent)
        XCTAssertFalse(tag("normal", 200, 100).usesRebateAccent)
        XCTAssertFalse(tag("no_rebate", 100, 100).usesRebateAccent)
        XCTAssertFalse(tag("bogus", 100, 100).usesRebateAccent)
        XCTAssertTrue(tag("amount_unknown", nil, nil).usesRebateAccent)
        XCTAssertTrue(tag("login_required", nil, nil, login: true).usesRebateAccent)
        // 调用方手工构造的 ¥0 金额（模型不产出）同样中性。
        let manualZero = RebateTagContent(
            kind: .amount, text: "预估返 ¥0", label: "预估返", amountParts: ["¥0"], singleAmount: "¥0",
            accessibilityText: "预估返 0 元"
        )
        XCTAssertFalse(manualZero.usesRebateAccent)
        let manualZeroRange = RebateTagContent(
            kind: .range, text: "预估返 ¥0–¥0", label: "预估返", amountParts: ["¥0", "–¥0"], singleAmount: nil,
            accessibilityText: "预估返 0 元到 0 元"
        )
        XCTAssertFalse(manualZeroRange.usesRebateAccent)
    }

    /// R2-02：价格口径 i 按钮跟着价格走，与返利区是否显示无关；只有卡上没有价格时才不显示。
    @MainActor
    func testDisclaimerButtonFollowsPrice() {
        func card(basis: String, minFen: Int64?, maxFen: Int64?, hidden: Bool = false,
                  disclaimer: String = "价格按单件计算") -> ProductCardData {
            ProductCardData(
                platformName: "淘宝",
                title: "样例",
                price: PriceTagModel.make(
                    platform: "taobao", priceFen: 2990, couponFen: 0, finalPriceFen: 2990, isPresale: false
                ),
                rebate: RebateTagModel.make(basis: basis, minFen: minFen, maxFen: maxFen, loginRequired: false),
                buyBase: "去购买",
                amountHidden: hidden,
                disclaimer: disclaimer,
                disclaimerButtonLabel: "口径说明"
            )
        }
        typealias Grid = ProductGridCard<EmptyView>
        // 有返利标签：i 在返利行内。
        XCTAssertEqual(Grid.disclaimerPlacement(card(basis: "normal", minFen: 45, maxFen: 45)), .inRebateRow)
        // 暂无返利（kind none）、异常降级：返利区不显示，i 仍在（价格行右侧）。
        XCTAssertEqual(Grid.disclaimerPlacement(card(basis: "no_rebate", minFen: nil, maxFen: nil)), .besidePrice)
        XCTAssertEqual(Grid.disclaimerPlacement(card(basis: "normal", minFen: 0, maxFen: 0)), .besidePrice)
        // 金额隐藏：返利区显示「预估返 ****」（F-IOS-06），i 在返利行内。
        XCTAssertEqual(
            Grid.disclaimerPlacement(card(basis: "normal", minFen: 45, maxFen: 45, hidden: true)), .inRebateRow
        )
        // 卡上没有价格（金额未知）：不显示；没有说明全文：不显示。
        XCTAssertEqual(Grid.disclaimerPlacement(card(basis: "amount_unknown", minFen: nil, maxFen: nil)), .hidden)
        XCTAssertEqual(
            Grid.disclaimerPlacement(card(basis: "normal", minFen: 45, maxFen: 45, disclaimer: "")), .hidden
        )
        // 列表卡 / AI 卡同一判定。
        XCTAssertTrue(ProductCardData.showsDisclaimerButton(card(basis: "no_rebate", minFen: nil, maxFen: nil)))
        XCTAssertTrue(
            ProductCardData.showsDisclaimerButton(card(basis: "normal", minFen: 45, maxFen: 45, hidden: true))
        )
        XCTAssertFalse(ProductCardData.showsDisclaimerButton(card(basis: "amount_unknown", minFen: nil, maxFen: nil)))
    }

    /// R2-03：ErrorState 立即播报，播报完（只认本条的结束通知，或兜底到时）把焦点移到【重试】，只移一次。
    func testErrorStateFocusMovesToRetry() {
        let text = ErrorStateFocusCoordinator.announcement(title: "加载失败", message: "网络不太好，请重试")
        XCTAssertEqual(text, "加载失败，网络不太好，请重试")
        XCTAssertEqual(ErrorStateFocusCoordinator.announcement(title: "加载失败", message: nil), "加载失败")

        // 读屏开着：先播报，等本条播报结束再移焦。
        var coordinator = ErrorStateFocusCoordinator()
        XCTAssertEqual(coordinator.appear(announcement: text, voiceOverRunning: true), [.announce(text)])
        XCTAssertTrue(coordinator.isWaitingForAnnouncement)
        XCTAssertEqual(coordinator.announcementFinished("已复制"), [], "别的播报结束不移焦")
        XCTAssertEqual(coordinator.announcementFinished(nil), [])
        XCTAssertEqual(coordinator.announcementFinished(text), [.focusRetry])
        XCTAssertEqual(coordinator.announcementFinished(text), [], "只移一次")
        XCTAssertEqual(coordinator.fallbackElapsed(), [])
        // 同一错误重绘：不重复播报、不重复移焦。
        XCTAssertEqual(coordinator.appear(announcement: text, voiceOverRunning: true), [])

        // 换成新的错误内容：重新播报、重新移焦。
        let other = ErrorStateFocusCoordinator.announcement(title: "加载失败", message: "服务繁忙")
        XCTAssertEqual(coordinator.appear(announcement: other, voiceOverRunning: true), [.announce(other)])
        // 结束通知丢失：兜底到时移焦。
        XCTAssertEqual(coordinator.fallbackElapsed(), [.focusRetry])
        XCTAssertEqual(coordinator.announcementFinished(other), [])

        // 读屏没开：播报（无人朗读）并直接移焦，不等待。
        var silent = ErrorStateFocusCoordinator()
        XCTAssertEqual(silent.appear(announcement: text, voiceOverRunning: false), [.announce(text), .focusRetry])
        XCTAssertFalse(silent.isWaitingForAnnouncement)

        // 兜底时长足够读完一句错误说明，不会抢在正常播报结束之前打断。
        XCTAssertGreaterThanOrEqual(ErrorStateFocusCoordinator.fallbackDelayNanos, 5_000_000_000)
    }
}
