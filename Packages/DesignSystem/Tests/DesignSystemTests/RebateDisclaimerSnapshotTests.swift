@testable import DesignSystem
import SnapshotTesting
import SwiftUI
import XCTest

/// 第 3 轮评审（ios-review-r2）的快照，基准图在 __Snapshots__/RebateDisclaimerSnapshotTests/。
/// 宽 390、默认字号；录制方式同 ComponentSnapshotTests。
@MainActor
final class RebateDisclaimerSnapshotTests: XCTestCase {
    private func snap(
        _ view: some View,
        size: DynamicTypeSize = .large,
        width: CGFloat = 390,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        let category: UIContentSizeCategory = size == .large ? .large : .accessibilityExtraExtraLarge
        let host = view
            .padding(CouliSpacing.s4)
            .frame(width: width)
            .background(CouliColor.backgroundCanvas)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .light)
        assertSnapshot(
            of: host,
            as: .image(
                precision: 0.995,
                perceptualPrecision: 0.98,
                layout: .sizeThatFits,
                traits: UITraitCollection(preferredContentSizeCategory: category)
            ),
            file: file,
            testName: testName,
            line: line
        )
    }

    /// R2-01：零返利、暂无返利、异常区间用常规文字色（不用返利橙、不带钟表）；有效返利仍用返利色。
    func testRebateAccentNeutralForZero() {
        snap(VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            AmountGrid(items: [
                AmountGridItem(label: "预估返", value: .range(minFen: 0, maxFen: 0), isRebate: true),
                AmountGridItem(label: "实付金额", value: .amount(2990)),
            ], valueStyle: .body)
                .couliCard()
            AmountGrid(items: [
                AmountGridItem(label: "预估返", value: .amount(0), isRebate: true),
                AmountGridItem(label: "预估返", value: .range(minFen: 234, maxFen: 123), isRebate: true),
            ], valueStyle: .body)
                .couliCard()
            AmountGrid(items: [
                AmountGridItem(label: "预估返", value: .amount(269), isRebate: true),
                AmountGridItem(label: "预估返", value: .range(minFen: 123, maxFen: 234), isRebate: true),
            ], valueStyle: .body)
                .couliCard()
            RebateTag(
                RebateTagModel.make(basis: "normal", minFen: 0, maxFen: 0, loginRequired: false),
                placement: .detail,
                isLarge: true
            )
        })
    }

    /// R2-02：网格卡与列表卡在暂无返利、金额隐藏时仍有价格口径 i；金额未知（无价格）时没有。
    func testDisclaimerButtonWithoutRebate() {
        var hidden = Samples.singleCard
        hidden.amountHidden = true
        snap(VStack(spacing: CouliSpacing.s3) {
            ProductCardGrid([Samples.noRebateCard, hidden, Samples.singleCard, Samples.unknownCard])
            ProductCard(Samples.noRebateCard) {}
            ProductCard(hidden, layout: .agent) {}
        })
    }
}
