import DesignSystem
import SwiftUI

/// 手机号输入（D10-1223 / D10-1230 判据 1）：短信登录页与绑定手机号页共用这一个组件，改这里两页一起生效。
/// 系统单行输入框（不用纵向轴）：号码任何字号、任何宽度都只占一行、不在数字中间换行，放不下时框内横向滚动，不缩字号。
/// 「+86」与 11 位号码排得下一行时放在号码左侧（竖线隔开）；排不下时「+86」挪到号码上方单独一行（同一个框内）。
/// 排法只看字号与宽度（按 11 位样本号码量），不看当前输入：输入中途不换排法、不丢焦点。
/// 读屏：「+86」与竖线是装饰，输入框读作「手机号 +86」；清除按钮由调用方决定何时出现。
struct PhoneNumberField<Focus: Hashable>: View {
    let text: Binding<String>
    let prefix: String
    let placeholder: String
    let label: String
    let clearLabel: String
    let identifier: String
    let focus: FocusState<Focus>.Binding
    let focusValue: Focus
    var hint = ""
    var error = false
    var locked = false
    var showsClear: Bool
    let onClear: () -> Void

    /// 量排法用的样本：11 位大陆号码（取最宽的数字）。
    static var sample: String {
        "88888888888"
    }

    var body: some View {
        PhonePrefixLayout {
            Text(verbatim: prefix)
                .couliFont(.title)
                .foregroundColor(CouliColor.textPrimary)
                .lineLimit(1)
                .padding(.leading, CouliSpacing.s4)
                .padding(.trailing, CouliSpacing.s3)
                .accessibilityHidden(true)
            // 竖线：尺寸由排法给（左右排 1×24，上下排不占位、不显示）
            Rectangle().fill(CouliColor.borderSubtle)
                .accessibilityHidden(true)
            // 排法样本（不显示）：号码 + 输入框左右留白 + 清除按钮的 44pt
            HStack(spacing: 0) {
                Text(verbatim: Self.sample).couliFont(.title).lineLimit(1)
                    .padding(.horizontal, CouliSpacing.s3)
                Color.clear.frame(width: CouliHitTarget.minimum)
            }
            .hidden()
            inputRow
        }
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .fill(locked ? CouliColor.backgroundMuted : CouliColor.backgroundSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .strokeBorder(error ? CouliColor.statusErrorText
                    : (locked ? CouliColor.borderSubtle : CouliColor.borderControl))
        )
    }

    /// 未聚焦且有号码时，号码用框内可横滑的一行字显示（系统单行框未聚焦时放不下会截成省略号、藏掉末几位）；点它进入输入。
    private var showsReadout: Bool {
        focus.wrappedValue != focusValue && !text.wrappedValue.isEmpty
    }

    private var inputRow: some View {
        HStack(spacing: 0) {
            TextField(text: text, prompt: Text(verbatim: placeholder)) {
                Text(verbatim: label)
            }
            .couliFont(.title)
            .foregroundColor(showsReadout ? Color.clear : CouliColor.textPrimary)
            .keyboardType(.phonePad)
            .textContentType(.telephoneNumber)
            .disabled(locked)
            .padding(.horizontal, CouliSpacing.s3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if showsReadout {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(verbatim: text.wrappedValue)
                            .couliFont(.title)
                            .foregroundColor(CouliColor.textPrimary)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, CouliSpacing.s3)
                            .frame(maxHeight: .infinity)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !locked {
                            focus.wrappedValue = focusValue
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .focused(focus, equals: focusValue)
            .accessibilityLabel(Text(verbatim: label + " " + prefix))
            .accessibilityHint(Text(verbatim: hint))
            .accessibilityIdentifier(identifier)
            if showsClear {
                Button(action: onClear) {
                    CouliIconView(.close, size: CouliComponentMetric.iconMedium)
                        .foregroundColor(CouliColor.textSecondary)
                        .couliHitTarget()
                }
                .buttonStyle(CouliPlainButtonStyle())
                .accessibilityLabel(Text(verbatim: clearLabel))
                .accessibilityIdentifier(identifier + "Clear")
            }
        }
        .frame(minHeight: CouliComponentMetric.controlMinHeight + CouliSpacing.s1)
    }
}

/// 「+86」、竖线、排法样本、输入行四个子视图的排法：样本（「+86」+ 竖线 + 11 位号码 + 清除按钮）放得下一行就左右排，
/// 放不下就「+86」在上、输入行在下（竖线与样本不占位）。只有一个输入框实例，换排法不重建输入框。
struct PhonePrefixLayout: Layout {
    private func inline(_ width: CGFloat?, _ subviews: Subviews) -> Bool {
        guard let width, subviews.count == 4 else { return true }
        let needed = subviews[0].sizeThatFits(.unspecified).width + Self.divider.width
            + subviews[2].sizeThatFits(.unspecified).width
        return needed <= width + 0.5
    }

    /// 左右排时竖线的尺寸。
    private static let divider = CGSize(width: 1, height: CouliSpacing.s6)

    private func fixedWidth(_ subviews: Subviews) -> CGFloat {
        subviews[0].sizeThatFits(.unspecified).width + Self.divider.width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard subviews.count == 4 else { return .zero }
        let width = proposal.width
        if inline(width, subviews) {
            let fixed = fixedWidth(subviews)
            let fieldWidth = width.map { max($0 - fixed, 0) } ?? subviews[2].sizeThatFits(.unspecified).width
            let field = subviews[3].sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil)).height
            let prefix = subviews[0].sizeThatFits(.unspecified).height
            return CGSize(width: width ?? fixed + fieldWidth, height: max(field, prefix))
        }
        let full = width ?? 0
        let prefix = subviews[0].sizeThatFits(ProposedViewSize(width: full, height: nil)).height
        let field = subviews[3].sizeThatFits(ProposedViewSize(width: full, height: nil)).height
        return CGSize(width: full, height: CouliSpacing.s2 + prefix + field)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard subviews.count == 4 else { return }
        subviews[2].place(at: bounds.origin, proposal: .zero)
        if inline(bounds.width, subviews) {
            let prefix = subviews[0].sizeThatFits(.unspecified)
            let divider = Self.divider
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(prefix))
            subviews[1].place(at: CGPoint(x: bounds.minX + prefix.width, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(divider))
            let start = prefix.width + divider.width
            subviews[3].place(at: CGPoint(x: bounds.minX + start, y: bounds.minY),
                              proposal: ProposedViewSize(width: max(bounds.width - start, 0), height: bounds.height))
            return
        }
        let prefix = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + CouliSpacing.s2),
                          proposal: ProposedViewSize(width: bounds.width, height: prefix.height))
        subviews[1].place(at: bounds.origin, proposal: .zero)
        let top = CouliSpacing.s2 + prefix.height
        subviews[3].place(at: CGPoint(x: bounds.minX, y: bounds.minY + top),
                          proposal: ProposedViewSize(width: bounds.width, height: max(bounds.height - top, 0)))
    }
}

extension View {
    /// 自定义顶栏的底（D10-1223）：不透明页面底色铺到状态栏，底部 1pt 分隔线与内容区分界；内容滚上去在分隔线下裁掉，
    /// 不会看起来从标题下透出。绑定手机号页与短信登录页共用。
    func loginTopBarChrome() -> some View {
        frame(maxWidth: .infinity)
            .background(CouliColor.backgroundCanvas.ignoresSafeArea(edges: .top))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(CouliColor.borderSubtle)
                    .frame(height: CouliComponentMetric.controlBorderWidth)
                    .accessibilityHidden(true)
            }
            .zIndex(1)
    }
}
