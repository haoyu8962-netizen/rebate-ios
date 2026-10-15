import SwiftUI

// MARK: - EntryGrid

/// 宫格的一格。
public struct EntryGridItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let icon: CouliIcon
    /// 读屏与 UI 测试的稳定标识（APP-12「我的」宫格：me.wallet、me.authManage…）；nil 时不设。
    public let accessibilityIdentifier: String?

    public init(id: String, title: String, icon: CouliIcon, accessibilityIdentifier: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

/// 白卡片内 4 列宫格（GUIDE §7.2「宫格入口」）：线性图标 24（墨棕）+ 14 文字，格高 ≥ 72，整格是命中区。
/// 辅助字号档改 2 列，文字换行不截断。
public struct EntryGrid: View {
    private let title: String?
    private let items: [EntryGridItem]
    private let columns: Int
    private let eager: Bool
    private let onSelect: (EntryGridItem) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - columns: 列数，默认 4（「我的」页）；钱包入口行用 2。
    ///   - eager: 一次建出全部格子（「我的」页：屏幕外的格子也在读屏树里，返回时位置稳定）；缺省按懒加载网格。
    public init(
        title: String? = nil,
        items: [EntryGridItem],
        columns: Int = 4,
        eager: Bool = false,
        onSelect: @escaping (EntryGridItem) -> Void
    ) {
        self.title = title
        self.items = items
        self.columns = columns
        self.eager = eager
        self.onSelect = onSelect
    }

    public var body: some View {
        let columns = dynamicTypeSize >= .accessibility1 ? min(columns, 2) : columns
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            if let title {
                Text(verbatim: title)
                    .couliFont(.body, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            if eager {
                VStack(spacing: 0) {
                    ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(start..<start + columns, id: \.self) { index in
                                if index < items.count {
                                    cell(items[index])
                                } else {
                                    Color.clear.frame(maxWidth: .infinity, minHeight: 1)
                                }
                            }
                        }
                    }
                }
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .top), count: columns),
                    alignment: .leading,
                    spacing: 0
                ) {
                    ForEach(items) { item in
                        cell(item)
                    }
                }
            }
        }
        .couliCard()
    }

    private func cell(_ item: EntryGridItem) -> some View {
        Button {
            onSelect(item)
        } label: {
            VStack(spacing: CouliSpacing.s1) {
                CouliIconView(item.icon)
                Text(verbatim: item.title)
                    .couliFont(.footnote)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(CouliColor.textPrimary)
            .padding(.vertical, CouliSpacing.s2)
            .frame(maxWidth: .infinity, minHeight: CouliGuideMetric.gridCellMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.button))
        .accessibilityLabel(Text(verbatim: item.title))
        .modifier(OptionalIdentifier(identifier: item.accessibilityIdentifier))
    }
}

/// 有标识才设 accessibilityIdentifier（没有时不改动元素，快照与读屏不变）。
private struct OptionalIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
