@testable import DesignSystem
import SnapshotTesting
import SwiftUI
import XCTest

/// 数字格区间金额的快照（R1-02），基准图在 __Snapshots__/AmountGridSnapshotTests/。
/// 320 宽（最窄机型）默认字号与辅助字号第 2 档（≈ 194%）各一张；录制方式同 ComponentSnapshotTests。
@MainActor
final class AmountGridSnapshotTests: XCTestCase {
    private func snap(
        _ view: some View,
        size: DynamicTypeSize,
        width: CGFloat,
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

    /// 订单数字格的区间金额（R1-02）：320 宽默认字号并排、区间在本列内只在破折号处折行；
    /// 辅助字号第 2 档上下排、返利在上；金额隐藏时整格「****」。
    private var rangeGrids: some View {
        VStack(spacing: CouliSpacing.s3) {
            AmountGrid(items: [
                AmountGridItem(label: "预估返", value: .range(minFen: 8_888_888, maxFen: 9_999_999), isRebate: true),
                AmountGridItem(label: "实付金额", value: .amount(12_345_678)),
            ], valueStyle: .body)
                .couliCard()
            AmountGrid(items: [
                AmountGridItem(label: "预估返", value: .range(minFen: 123, maxFen: 234), isRebate: true),
                AmountGridItem(label: "实付金额", value: .amount(2990)),
            ], valueStyle: .body, amountHidden: true)
                .couliCard()
        }
    }

    func testAmountGridRangeNarrow() {
        snap(rangeGrids, size: .large, width: 320)
    }

    func testAmountGridRangeNarrowLargeText() {
        snap(rangeGrids, size: .accessibility2, width: 320)
    }
}
