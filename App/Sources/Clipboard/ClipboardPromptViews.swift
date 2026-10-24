import DesignSystem
import SwiftUI

// 剪贴板提示条与识别结果内联卡的版式（APP-11v-b：HomeClipboardInvite-v3、HomeClipboardResults-v3 ①⑤）。

/// 提示条的版式（设计稿：白底圆角浮起卡片，左文案 14/600，右按钮，独立【关闭】48pt 命中区）。
/// `keepLastClause`（HomeClipboardInvite-v3「绑定为邀请人？」不拆行，APP-11v A6）：文案最后一个「，」之后的问句整句成行——整条放不下
/// 一行时问句另起一行；文字栏连问句都放不下（窄屏 / 大字号）时按钮与关闭整体换到文字下方靠右，文字取整行宽。问句比整行还长时照常换行。
/// 只改排版，不插字符：读屏仍读完整原文。
struct PromptBarFrame<Action: View>: View {
    let text: String
    let closeLabel: String
    let closeId: String
    var keepLastClause = false
    let onClose: () -> Void
    @ViewBuilder let action: () -> Action

    var body: some View {
        let clause = keepLastClause ? PromptClause(text) : nil
        PromptBarLayout(spacing: CouliSpacing.s2, keepWidth: clause != nil) {
            PromptText(text: text, clause: clause)
            HStack(spacing: CouliSpacing.s2) {
                action()
                Button(action: onClose) {
                    CouliIconView(.close, size: 18)
                        .foregroundColor(CouliColor.textSecondary)
                        .couliHitTarget()
                }
                .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                .accessibilityLabel(Text(verbatim: closeLabel))
                .accessibilityIdentifier(closeId)
            }
            // 问句的自然宽（排版用的隐藏量尺；读屏、点击都没有）
            PromptMeasureText(text: clause?.tail ?? "")
        }
        .padding(.leading, CouliSpacing.s4)
        .padding(.trailing, CouliSpacing.s1)
        .padding(.vertical, CouliSpacing.s2)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.backgroundSurface)
                .couliShadow(.floating)
        )
        .accessibilityElement(children: .contain)
    }
}

/// 文案按最后一个「，」拆成前段与问句（没有「，」或问句为空时不拆）。
struct PromptClause: Equatable {
    let head: String
    let tail: String

    init?(_ text: String) {
        guard let comma = text.lastIndex(of: "，") else { return nil }
        let head = String(text[...comma])
        let tail = String(text[text.index(after: comma)...])
        guard !tail.isEmpty, !head.isEmpty else { return nil }
        self.head = head
        self.tail = tail
    }
}

private struct PromptText: View {
    let text: String
    let clause: PromptClause?

    var body: some View {
        Group {
            if let clause {
                // 整条放得下一行就一行；否则前段照常换行、问句另起一行整句排
                ViewThatFits(in: .horizontal) {
                    line(text).lineLimit(1)
                    VStack(alignment: .leading, spacing: 0) {
                        line(clause.head)
                        line(clause.tail)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: text))
                .accessibilityAddTraits(.isStaticText)
            } else {
                line(text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ value: String) -> some View {
        Text(verbatim: value)
            .couliFont(.footnote, weight: .couliSemibold)
            .foregroundColor(CouliColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PromptMeasureText: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .couliFont(.footnote, weight: .couliSemibold)
            .lineLimit(1)
            .fixedSize()
            .hidden()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// 提示条排版：子视图依次是 文字、按钮组、问句量尺。并排时文字栏 = 总宽 − 按钮组 − 间距；`keepWidth` 时文字栏比问句窄就把按钮组
/// 换到文字下方靠右（文字取整行宽）。
struct PromptBarLayout: Layout {
    let spacing: CGFloat
    let keepWidth: Bool

    private func stacked(width: CGFloat, subviews: Subviews) -> Bool {
        guard keepWidth, subviews.count > 2 else { return false }
        let trailing = subviews[1].sizeThatFits(.unspecified).width
        let clause = subviews[2].sizeThatFits(.unspecified).width
        return width - trailing - spacing < clause
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width
            + spacing + subviews[1].sizeThatFits(.unspecified).width
        let trailing = subviews[1].sizeThatFits(.unspecified)
        if stacked(width: width, subviews: subviews) {
            let text = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
            return CGSize(width: width, height: text.height + spacing + trailing.height)
        }
        let column = max(0, width - trailing.width - spacing)
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: column, height: nil))
        return CGSize(width: width, height: max(text.height, trailing.height))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let trailing = subviews[1].sizeThatFits(.unspecified)
        if stacked(width: bounds.width, subviews: subviews) {
            let text = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: text.height))
            subviews[1].place(at: CGPoint(x: bounds.maxX - trailing.width, y: bounds.minY + text.height + spacing),
                              proposal: ProposedViewSize(trailing))
        } else {
            let column = max(0, bounds.width - trailing.width - spacing)
            let text = subviews[0].sizeThatFits(ProposedViewSize(width: column, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: column, height: text.height))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                              proposal: ProposedViewSize(trailing))
        }
        if subviews.count > 2 {
            subviews[2].place(at: bounds.origin, proposal: .zero)
        }
    }
}

/// 提示里的动作按钮（【用商品名搜索】【重试】）。
struct NoticeAction {
    let title: String
    var identifier = "clipboard.searchByName"
    let perform: () -> Void
}

/// 识别结果 ①⑤ 的内联卡（HomeClipboardResults-v3，与 Android `InlineResultCard` 同版式）：白底圆角 16、内边距 16 / 12；
/// 左 20 图标（装饰）+ 14 主文字 + 右描边次按钮（紧凑，命中 44），放不下时按钮整块换到文字下方靠右。画板无关闭键：结果在下一次
/// 粘贴、离开首页、按钮动作后自然收起（原 ShareHubInvalid 样式的【关闭】随版式去掉，与 Android 一致）。
struct InlineResultCard: View {
    let icon: CouliIcon
    let text: String
    let action: NoticeAction
    let enabled: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: CouliSpacing.s3) {
                message
                button.fixedSize()
            }
            VStack(alignment: .trailing, spacing: CouliSpacing.s2) {
                message.frame(maxWidth: .infinity, alignment: .leading)
                button
            }
        }
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.vertical, CouliSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.backgroundSurface)
        )
        .accessibilityElement(children: .contain)
    }

    private var message: some View {
        HStack(alignment: .firstTextBaseline, spacing: CouliSpacing.s2) {
            CouliIconView(icon, size: 20, relativeTo: .footnote)
                .foregroundColor(CouliColor.textPrimary)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var button: some View {
        CouliButton(action.title, kind: .secondary, size: .compact, isEnabled: enabled, action: action.perform)
            .accessibilityIdentifier(action.identifier)
    }
}
