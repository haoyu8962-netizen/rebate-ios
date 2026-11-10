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
