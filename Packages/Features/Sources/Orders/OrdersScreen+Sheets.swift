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
                sheetOptions {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        if index > 0 {
                            sheetDivider
                        }
                        sheetRow(
                            option.map { texts.text("platform." + $0) } ?? texts.text(OrderKeys.allPlatforms),
                            selected: snapshot.query.platform == option, id: option ?? "all", platform: option
                        ) {
                            if controller.setPlatform(option) {
                                config.sheet = nil
                            }
                        }
                    }
                }
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
                    OrderProbedText(texts.text(OrderKeys.monthNote), style: .footnote, probeID: "orders.sheet.note")
                        .foregroundColor(CouliColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    sheetOptions {
                        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                            if index > 0 {
                                sheetDivider
                            }
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
            },
            actions: { EmptyView() }
        )
    }

    /// 选项区：按内容高（画板半屏随内容高），高度上限一次定为屏高的 45%（`OrderLayout.sheetOptionsMaxHeight`，常量、不随布局结果变），
    /// 超出就在选项区内滚动；半屏外壳的 ScrollingBody 因此总放得下（评审 r1 S2-3 / 测试 v3）。
    func sheetOptions(@ViewBuilder _ rows: () -> some View) -> some View {
        // 不靠布局结果挑分支：滚动容器的理想高 = 内容高，经 maxHeight 夹到上限，fixedSize 让它按理想高定高
        ScrollView {
            VStack(spacing: 0) { rows() }
        }
        .frame(maxHeight: OrderLayout.sheetOptionsMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 选项间 1 分隔线（`border.subtle`）。
    var sheetDivider: some View {
        Rectangle().fill(CouliColor.borderSubtle).frame(height: 1).accessibilityHidden(true)
    }

    /// 半屏选项行（≥ 44，iOS 命中区；画板行高 44）：平台项前 20 官方图标（装饰，读屏只读平台名一次）；选中 17/600 `brand.emphasis` + 右侧圆圈对勾。
    func sheetRow(_ label: String, selected: Bool, id: String, platform: String? = nil,
                  action: @escaping () -> Void) -> some View {
        let probe = "orders.sheet.option.\(id)"
        return Button(action: action) {
            HStack(spacing: CouliSpacing.s2) {
                if let platform, PlatformIcon.hasBuiltinImage(platform) {
                    PlatformIcon(platformCode: platform, size: .select)
                        .couliProbe(probe + ".icon", role: "icon")
                }
                OrderProbedText(label, style: .body, weight: selected ? .couliSemibold : .regular,
                                probeID: probe + ".label")
                    .foregroundColor(selected ? CouliColor.brandEmphasis : CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: CouliSpacing.s2)
                if selected {
                    CouliIconView(.check, size: CouliGuideMetric.iconMedium)
                        .foregroundColor(CouliColor.brandEmphasis)
                        .couliProbe(probe + ".check", role: "icon")
                }
            }
            .frame(minHeight: CouliHitTarget.minimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(CouliPlainButtonStyle())
        .disabled(snapshot.blocked)
        .couliProbe(probe, role: "row")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("orders.option.\(id)")
    }
}
