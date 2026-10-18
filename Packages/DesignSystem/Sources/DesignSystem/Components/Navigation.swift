import SwiftUI

/// 二级页导航栏（GUIDE §3「导航栏」）：最小高 44，左侧返回（44 命中区），标题居中 body/600；右侧可放同尺寸操作。
/// 标题封顶在辅助字号第 2 档（03 §10.4，约 200%），长按用大内容查看器。
public struct NavBar<Trailing: View>: View {
    private let title: String
    private let backLabel: String?
    private let onBack: () -> Void
    private let trailing: Trailing
    private let foreground: Color

    /// - Parameters:
    ///   - backLabel: 返回按钮读屏名称（字典文案）；nil 时不显示返回（一级页）。
    ///   - foreground: 返回图标与标题的颜色；缺省主文字色（H5 容器按页面设置的标题栏配色传入）。
    public init(
        title: String,
        backLabel: String?,
        foreground: Color = CouliColor.textPrimary,
        onBack: @escaping () -> Void = {},
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.foreground = foreground
        self.title = title
        self.backLabel = backLabel
        self.onBack = onBack
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 0) {
            Group {
                if let backLabel {
                    Button(action: onBack) {
                        CouliIconView(.back)
                            .foregroundColor(foreground)
                            .couliHitTarget()
                    }
                    .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                    .accessibilityLabel(Text(verbatim: backLabel))
                } else {
                    Color.clear.frame(width: CouliHitTarget.minimum, height: CouliHitTarget.minimum)
                }
            }
            Text(verbatim: title)
                .couliFont(.body, weight: .couliSemibold)
                .foregroundColor(foreground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
                .accessibilityShowsLargeContentViewer()
            trailing
                .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
        }
        .padding(.horizontal, CouliSpacing.s1)
        .frame(minHeight: CouliHitTarget.minimum)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

public extension NavBar where Trailing == EmptyView {
    init(title: String, backLabel: String?, onBack: @escaping () -> Void = {}) {
        self.init(title: title, backLabel: backLabel, onBack: onBack) { EmptyView() }
    }
}

/// 一级 Tab 的一项。
public struct TabBarItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let icon: CouliIcon

    public init(id: String, title: String, icon: CouliIcon) {
        self.id = id
        self.title = title
        self.icon = icon
    }
}

/// 一级 Tab 栏（首页 / AI 助手 / 订单 / 我的，文字由调用方给）。选中项图标主色、文字强调色 600；
/// 未选次文字色；选中状态同时由读屏「已选」表达（不只靠颜色）。可以不等比放大（03 §10.4），封顶第 2 档辅助字号。
public struct TabBar: View {
    private let items: [TabBarItem]
    private let selectedID: String
    private let onSelect: (TabBarItem) -> Void

    public init(items: [TabBarItem], selectedID: String, onSelect: @escaping (TabBarItem) -> Void) {
        self.items = items
        self.selectedID = selectedID
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let selected = item.id == selectedID
                Button {
                    onSelect(item)
                } label: {
                    VStack(spacing: CouliSpacing.s1 / 2) {
                        CouliIconView(item.icon)
                            .foregroundColor(selected ? CouliColor.brandPrimary : CouliColor.textSecondary)
                        Text(verbatim: item.title)
                            .couliFont(.caption, weight: selected ? .couliSemibold : .regular)
                            .foregroundColor(selected ? CouliColor.brandEmphasis : CouliColor.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(1)
                    }
                    .padding(.vertical, CouliSpacing.s1)
                    .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                // 读屏 / 自动化里每个 Tab 只是一个按钮：容器带标签栏特征（iOS 17+）时，按钮里的图标、文字也会被当成按钮，
                // 树里出现同名的多个「首页」；用只含名称的按钮作无障碍表示，激活仍走 onSelect
                .accessibilityRepresentation {
                    Button {
                        onSelect(item)
                    } label: {
                        Text(verbatim: item.title)
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                .accessibilityShowsLargeContentViewer {
                    Label {
                        Text(verbatim: item.title)
                    } icon: {
                        CouliIconView(item.icon)
                    }
                }
            }
        }
        .padding(.top, CouliSpacing.s1 + CouliSpacing.s1 / 2)
        .background(
            CouliColor.backgroundSurface
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    Rectangle().fill(CouliColor.borderSubtle).frame(height: CouliComponentMetric.controlBorderWidth)
                }
        )
        // 读屏按标签栏朗读「首页，标签，第 1 个，共 4 个，已选中」（adaptation-a11y-spec；iOS 17 起有标签栏特征，
        // iOS 16 只读名称与「已选中」）。
        .accessibilityElement(children: .contain)
        .modifier(TabBarAccessibilityTrait())
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

/// 容器的标签栏特征（iOS 17+）：VoiceOver 据此给每个按钮读「标签，第 n 个，共 m 个」。
private struct TabBarAccessibilityTrait: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.accessibilityAddTraits(.isTabBar)
        } else {
            content
        }
    }
}
