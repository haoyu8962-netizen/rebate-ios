import SwiftUI

// MARK: - EntryGrid

/// 宫格的一格。
public struct EntryGridItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let icon: CouliIcon

    public init(id: String, title: String, icon: CouliIcon) {
        self.id = id
        self.title = title
        self.icon = icon
    }
}

/// 白卡片内 4 列宫格（GUIDE §7.2「宫格入口」）：线性图标 24（墨棕）+ 14 文字，格高 ≥ 72，整格是命中区。
/// 辅助字号档改 2 列，文字换行不截断。
public struct EntryGrid: View {
    private let title: String?
    private let items: [EntryGridItem]
    private let columns: Int
    private let onSelect: (EntryGridItem) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameter columns: 列数，默认 4（「我的」页）；钱包入口行用 2。
    public init(
        title: String? = nil,
        items: [EntryGridItem],
        columns: Int = 4,
        onSelect: @escaping (EntryGridItem) -> Void
    ) {
        self.title = title
        self.items = items
        self.columns = columns
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
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .top), count: columns),
                alignment: .leading,
                spacing: 0
            ) {
                ForEach(items) { item in
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
                }
            }
        }
        .couliCard()
    }
}
