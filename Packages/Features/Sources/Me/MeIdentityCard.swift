import DesignSystem
import MeCore
import SwiftUI
import UIKit

/// 身份卡（设计稿 Me、MeMinor，brief §2-3）：白卡内边距 16、横向 12；头像 56 → 昵称 17/600（可折行不截断）→ 流式行
/// （「我的邀请码」+ 码 + 复制 / 邀请人，12 号）。`invite_code` 为 null 时整段邀请码不显示、不显示原因（G05 / G-M08）。
extension MeTabBody {
    func identityCard(_ me: MeProfile, _ view: MeViewModel, _ actions: MeTabActions) -> some View {
        HStack(alignment: .center, spacing: CouliSpacing.s3) {
            MeAvatar()
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                MeText(me.nickname, style: .body, weight: .couliSemibold, probe: "me.nickname")
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityIdentifier("me.nickname")
                inviteRow(view, actions)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .couliCard(padding: CouliSpacing.s4)
        .meProbe("me.identity", role: "card")
        .background(MeSectionTops.reader("me.section.identity"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("me.identity")
    }

    @ViewBuilder
    private func inviteRow(_ view: MeViewModel, _ actions: MeTabActions) -> some View {
        let inviter = view.inviterTextKey.map { texts.text($0) }
        if let code = view.inviteCode {
            let label = texts.text("me.invite_code")
            MeInviteFlowLayout(itemSpacing: CouliSpacing.s3, labelSpacing: CouliSpacing.s1,
                               lineSpacing: CouliSpacing.s1) {
                // 标签不单读：码一项读「我的邀请码 K7M3QX」
                MeText(label, style: .caption, probe: "me.invite.label")
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityRepresentation { EmptyView() }
                HStack(spacing: CouliSpacing.s1) {
                    MeInviteCodeText(code: code)
                        .accessibilityLabel(Text(verbatim: label + " " + code))
                        .accessibilityIdentifier("me.inviteCode")
                    MeIconButton(.copy, base: CouliComponentMetric.iconInline,
                                 label: texts.text("me.copy") + label, margin: 2, probe: "me.invite.copy",
                                 action: actions.copyInvite)
                        .foregroundColor(CouliColor.textLink)
                        .accessibilityIdentifier("me.copyInvite")
                }
                if let inviter {
                    inviterText(inviter)
                }
            }
            .meProbe("me.invite.row", role: "row")
        } else if let inviter {
            inviterText(inviter)
        }
    }

    private func inviterText(_ text: String) -> some View {
        MeText(text, style: .caption, probe: "me.invite.inviter")
            .foregroundColor(CouliColor.textSecondary)
            .accessibilityIdentifier("me.inviter")
    }
}

/// 邀请码：主文字 600、字距 1、等宽数字；不可断的一段（不省略、不换行）。
struct MeInviteCodeText: View {
    let code: String
    @ScaledMetric(relativeTo: .caption) private var size = CouliTextStyle.caption.baseSize

    var body: some View {
        Text(verbatim: code)
            .font(Font.system(size: size, weight: .couliSemibold).monospacedDigit())
            .tracking(1)
            .lineLimit(1)
            .fixedSize()
            .foregroundColor(CouliColor.textPrimary)
            .couliLineBox(.caption)
            .couliTextProbe("me.invite.code", role: "text", text: code, fontSize: size,
                            baseFontSize: CouliTextStyle.caption.baseSize)
    }
}

/// 邀请码行（子项：0 标签、1 码 + 复制、2 邀请人（可无））：同行上下居中；放不下换行。码与复制是一个子项，不会被拆开。
/// 邀请人换到下一行时，若与复制的 44 命中区横向相交，下移到命中区之下（brief §9 第 1 条）。
struct MeInviteFlowLayout: Layout {
    let itemSpacing: CGFloat
    let labelSpacing: CGFloat
    let lineSpacing: CGFloat

    private struct Placed {
        var origin: CGPoint
        var size: CGSize
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (items: [Placed], size: CGSize) {
        var items: [Placed] = []
        var line: [Int] = []
        var left: CGFloat = 0
        var top: CGFloat = 0
        var lineHeight: CGFloat = 0
        func closeLine() {
            for index in line {
                items[index].origin.y = top + (lineHeight - items[index].size.height) / 2
            }
        }
        for (index, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            if size.width > width {
                size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            let gap = index == 1 ? labelSpacing : itemSpacing
            if left > 0, left + gap + size.width > width + 0.5 {
                closeLine()
                top += lineHeight + lineSpacing
                if index == 2 {
                    top = max(top, copyHitBottom(items[1]))
                }
                line = []
                left = 0
                lineHeight = 0
            }
            let start = left > 0 ? left + gap : 0
            items.append(Placed(origin: CGPoint(x: start, y: top), size: size))
            line.append(index)
            left = start + size.width
            lineHeight = max(lineHeight, size.height)
        }
        closeLine()
        return (items, CGSize(width: width.isFinite ? width : left, height: top + lineHeight))
    }

    /// 码 + 复制这一项的命中区下缘（复制的命中区以该行中线为中心）；换行后的邀请人从这里往下排。
    private func copyHitBottom(_ item: Placed) -> CGFloat {
        item.origin.y + item.size.height / 2 + CouliHitTarget.minimum / 2
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for (view, item) in zip(subviews, arrange(bounds.width, subviews).items) {
            view.place(at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                       proposal: ProposedViewSize(item.size))
        }
    }
}
