import DesignSystem
import Generated
import OrderCore
import SwiftUI

extension OrdersScreen {
    // MARK: - 半屏

    var platformSheet: some View {
        let options: [String?] = [nil] + OrderPlatformOptions.platforms
        return CouliSheet(
            title: texts.text(OrderKeys.filterPlatform), closeLabel: texts.text(OrderKeys.filterClose),
            onClose: { config.sheet = nil },
            content: {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(options, id: \.self) { option in
                            sheetRow(
                                option.map { texts.text("platform." + $0) } ?? texts.text(OrderKeys.allPlatforms),
                                selected: snapshot.query.platform == option, id: option ?? "all"
                            ) {
                                if controller.setPlatform(option) {
                                    config.sheet = nil
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            },
            actions: { EmptyView() }
        )
    }

    var monthSheet: some View {
        let months = OrderMonthOptions.months(snapshot.earliestVisibleDate, nowMs: config.now())
        let options: [String?] = [nil] + months
        return CouliSheet(
            title: texts.text(OrderKeys.filterMonth), closeLabel: texts.text(OrderKeys.filterClose),
            onClose: { config.sheet = nil },
            content: {
                VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                    Text(verbatim: texts.text(OrderKeys.monthNote))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(options, id: \.self) { option in
                                let label = option.flatMap(OrderFormat.monthParts).map {
                                    texts.format(OrderKeys.monthItem, ["year": $0.year, "month": $0.month])
                                } ?? texts.text(OrderKeys.allMonths)
                                sheetRow(label, selected: snapshot.query.month == option, id: option ?? "all") {
                                    if controller.setMonth(option) {
                                        config.sheet = nil
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }
            },
            actions: { EmptyView() }
        )
    }

    func sheetRow(_ label: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(verbatim: label)
                    .couliFont(.body, weight: selected ? .couliSemibold : .regular)
                    .foregroundColor(selected ? CouliColor.brandEmphasis : CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: CouliSpacing.s2)
                if selected {
                    CouliIconView(.check)
                        .foregroundColor(CouliColor.brandEmphasis)
                }
            }
            .frame(minHeight: CouliHitTarget.minimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(CouliPlainButtonStyle())
        .disabled(snapshot.blocked)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("orders.option.\(id)")
    }
}
