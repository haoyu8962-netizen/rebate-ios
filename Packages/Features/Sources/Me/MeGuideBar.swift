import DesignSystem
import MeCore
import SwiftUI
import UIKit

/// 引导条文字切分（G-M10）：按最后一个「。」切，尾段非空且不超过 8 个字时尾段画链接样式；否则回退整句普通样式。
/// 视图层纯函数，每次渲染重算：换文案后不残留上一份的样式。动作词有单独键之后去掉。
enum MeGuideSplit {
    static let maxTail = 8
    /// 中文句号（只是切分用的标点，不是文案）。
    private static let stopMark: Character = "\u{3002}"

    static func tail(of sentence: String) -> (head: String, tail: String)? {
        guard let stop = sentence.lastIndex(of: stopMark) else { return nil }
        let next = sentence.index(after: stop)
        let tail = String(sentence[next...])
        guard !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, tail.count <= maxTail else { return nil }
        return (String(sentence[..<next]), tail)
    }
}

/// 通知引导条（设计稿 MeHidden，brief §2-2）：`background.muted` 底、圆角 12、内边距 4/4/4/12；次文字色铃铛 20，正文 14，
/// 句尾「去开启」链接样式。整条正文区一个目标（只跳系统通知设置，不申请权限）；关闭单独一个目标（视觉 20、命中 44）。显隐判定不在这里。
/// 正文是一个 Text，读屏整句读一次，不因样式切分读两遍。
extension MeTabBody {
    func guideBar(_ actions: MeTabActions) -> some View {
        let sentence = texts.text("perm.push.guide_bar")
        return HStack(spacing: 0) {
            Button(action: actions.openGuide) {
                HStack(spacing: CouliSpacing.s2) {
                    CouliIconView(.bell, size: CouliGuideMetric.iconMedium, relativeTo: .footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .meProbe("me.guideBar.icon", role: "icon")
                        .accessibilityHidden(true)
                    MeGuideText(sentence: sentence)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CouliSpacing.s3)
                .padding(.trailing, CouliSpacing.s2)
                .padding(.vertical, CouliSpacing.s2)
                .frame(minHeight: CouliHitTarget.minimum)
                .contentShape(Rectangle())
                .meProbe("me.guideBar.open.hit", role: "hit")
            }
            .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.button))
            .accessibilityIdentifier("me.guideBar.open")
            Button(action: actions.closeGuide) {
                CouliIconView(.close, size: CouliGuideMetric.iconMedium, relativeTo: .footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .meProbe("me.guideBar.close", role: "icon")
                    .couliHitTarget()
                    .meProbe("me.guideBar.close.hit", role: "hit")
            }
            .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small, ringInside: true))
            .accessibilityLabel(Text(verbatim: texts.text("me.guide_bar.close")))
            .accessibilityIdentifier("me.guideBar.close")
        }
        .padding([.top, .bottom, .trailing], CouliSpacing.s1)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .fill(CouliColor.backgroundMuted)
        )
        .meProbe("me.guideBar", role: "bar")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("me.guideBar")
    }
}

/// 引导条正文：14 主文字，切得开时尾段 600、下划线、链接色。
struct MeGuideText: View {
    let sentence: String

    var body: some View {
        let split = MeGuideSplit.tail(of: sentence)
        styled(split)
            .couliFont(.footnote)
            .foregroundColor(CouliColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .couliLineBox(.footnote)
            .couliTextNaturalProbe("me.guideBar.text", role: "text", text: sentence, style: .footnote)
            .background(alignment: .topLeading) {
                if let split {
                    MeGuideTailProbe(head: split.head, tail: split.tail)
                }
            }
    }

    private func styled(_ split: (head: String, tail: String)?) -> Text {
        guard let split else { return Text(verbatim: sentence) }
        return Text(verbatim: split.head)
            + Text(verbatim: split.tail).fontWeight(.couliSemibold).underline().foregroundColor(CouliColor.textLink)
    }
}

/// 只给测量用：SwiftUI 的 Text 不给片段位置，按同字号同宽度用 TextKit 算尾段的框（没有接收方时什么也不画）。框只用于定位尾段的墨迹。
private struct MeGuideTailProbe: View {
    let head: String
    let tail: String
    @Environment(\.couliLayoutProbe) private var receiver
    @ScaledMetric(relativeTo: .footnote) private var size = CouliTextStyle.footnote.baseSize

    var body: some View {
        if receiver != nil {
            GeometryReader { proxy in
                let box = rect(in: proxy.size)
                // 测量挂在 offset 里面：挂在外面量到的是偏移前的框
                Color.clear
                    .frame(width: box.width, height: box.height)
                    .couliTextProbe("me.guideBar.cta", role: "link", text: tail, fontSize: size,
                                    baseFontSize: CouliTextStyle.footnote.baseSize)
                    .offset(x: box.minX, y: box.minY)
            }
            .accessibilityHidden(true)
        }
    }

    private func rect(in container: CGSize) -> CGRect {
        let paragraph = NSMutableParagraphStyle()
        let font = UIFont.systemFont(ofSize: size)
        paragraph.lineSpacing = max(0, size * CouliTextStyle.footnote.lineHeightMultiple - font.lineHeight)
        let text = NSMutableAttributedString(string: head + tail, attributes: [.font: font, .paragraphStyle: paragraph])
        let range = NSRange(location: (head as NSString).length, length: (tail as NSString).length)
        text.addAttribute(.font, value: UIFont.systemFont(ofSize: size, weight: .semibold), range: range)
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let area = NSTextContainer(size: CGSize(width: container.width, height: .greatestFiniteMagnitude))
        area.lineFragmentPadding = 0
        layout.addTextContainer(area)
        storage.addLayoutManager(layout)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: area)
            .intersection(CGRect(origin: .zero, size: container))
    }
}
