import DesignSystem
import SwiftUI

/// 6 个验证码格子的尺寸（共性 7）：格宽按可用宽度均分（320pt 宽也在一行内），格高随字号增高；数字字号随字号放大，
/// 但不超过格子容纳得下的大小。纯函数，单测覆盖 320pt × 100% / 200%。
public struct CodeCellLayout: Equatable, Sendable {
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    public let fontSize: CGFloat
    public let spacing: CGFloat

    /// 设计稿：格宽 52、高 56、间距 12、数字 32（390 宽）。
    public static let designWidth: CGFloat = 52
    public static let designHeight: CGFloat = 56
    public static let designFont: CGFloat = 32
    public static let designSpacing: CGFloat = 12
    /// 数字到格边的最小留白（每侧）。
    static let inset: CGFloat = 4

    /// - availableWidth：格子行的可用宽度；0 或未测得时按设计稿。
    /// - scale：系统字号相对默认的倍数（1 = 默认，2 = 200%）。
    public static func compute(availableWidth: CGFloat, count: Int = CodeInput.length,
                               scale: CGFloat) -> CodeCellLayout {
        let gaps = CGFloat(max(count - 1, 0))
        let width = availableWidth > 0
            ? availableWidth : designWidth * CGFloat(count) + designSpacing * gaps
        let spacing = min(designSpacing, max(4, (width - designWidth * CGFloat(count)) / max(gaps, 1)))
        let cell = max(1, (width - spacing * gaps) / CGFloat(count))
        let wanted = designFont * max(scale, 1)
        // 数字宽约 0.62 字号（等宽数字）；格子放不下时封顶。
        let fits = (cell - inset * 2) / 0.62
        let font = max(12, min(wanted, fits))
        let height = max(designHeight, font * 1.3 + inset * 2)
        return CodeCellLayout(cellWidth: cell, cellHeight: height, fontSize: font, spacing: spacing)
    }
}

/// 验证码格子行：上面盖一个几乎透明的输入框（读屏读「验证码，文本框，已输入的数字」，键盘只弹数字，支持短信验证码自动填充）。
struct CodeCells: View {
    let code: String
    let hasError: Bool
    let label: String
    let binding: Binding<String>
    let focused: FocusState<Bool>.Binding
    @State private var width: CGFloat = 0
    @ScaledMetric(relativeTo: .title) private var scaled: CGFloat = 100

    private var layout: CodeCellLayout {
        CodeCellLayout.compute(availableWidth: width, scale: scaled / 100)
    }

    var body: some View {
        let layout = layout
        let digits = Array(code)
        ZStack {
            HStack(spacing: layout.spacing) {
                ForEach(0..<CodeInput.length, id: \.self) { index in
                    let current = index == digits.count && focused.wrappedValue
                    Text(verbatim: index < digits.count ? String(digits[index]) : "")
                        .font(.system(size: layout.fontSize, weight: .bold).monospacedDigit())
                        .foregroundColor(CouliColor.textPrimary)
                        .lineLimit(1)
                        .frame(
                            minWidth: 0,
                            maxWidth: layout.cellWidth,
                            minHeight: layout.cellHeight,
                            maxHeight: layout.cellHeight
                        )
                        .background(
                            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                                .fill(CouliColor.backgroundSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                                .strokeBorder(
                                    current ? CouliColor.focusRing
                                        : (hasError ? CouliColor.statusErrorText : CouliColor.borderControl),
                                    lineWidth: current ? 2 : 1
                                )
                        )
                }
            }
            .accessibilityHidden(true)
            TextField(text: binding) {
                Text(verbatim: label)
            }
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .foregroundColor(.clear)
            .tint(.clear)
            .opacity(0.02)
            .frame(maxWidth: .infinity, minHeight: layout.cellHeight)
            .focused(focused)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityValue(Text(verbatim: code))
            .accessibilityIdentifier("login.code")
        }
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CodeRowWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(CodeRowWidthKey.self) { width = $0 }
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = true }
    }
}

private struct CodeRowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
