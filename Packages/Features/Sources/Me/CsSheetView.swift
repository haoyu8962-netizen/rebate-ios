import DesignSystem
import MeCore
import SwiftUI

/// 客服半屏的按钮回调（打开时的半屏编号：换了版式或已关闭的旧回调不生效）。
@MainActor
public struct CsActions {
    public let openWechat: () -> Void
    public let copyLink: () -> Void
    public let goHelp: () -> Void
    public let close: () -> Void

    public static func make(_ entry: CustomerServiceEntry, _ sheet: CsSheet) -> CsActions {
        let serial = sheet.serial
        return CsActions(
            openWechat: { [weak entry] in entry?.openWechat(serial) },
            copyLink: { [weak entry] in entry?.copyLink(serial) },
            goHelp: { [weak entry] in entry?.goHelp(serial) },
            close: { [weak entry] in entry?.dismiss(serial) }
        )
    }
}

/// 统一客服出口的半屏（设计稿 CsOpenFailed-v2、CsWechatMissing-v2、CsWechatMissingDark；HANDOFF、只有帮助无稿，同一模板，G-P02、G-P06）：
/// 图标块 → 标题 → 关闭 → 说明 → 安全提示 → 按钮（adaptation-a11y-spec §8）。关闭在标题行右侧（三端口径：标题上方无可读节点）。放不下时只有说明与安全提示
/// 滚动，头部与按钮固定可见（短视口）。复制客服链接的结果显示在半屏里（polite 播报一次，A17），失败用错误色。kf 缺失或不是 https 的降级半屏只有【去帮助中心】。
/// 由 App 以系统 `.sheet`（presentationDetents）盖在当前页面上：把手、遮罩是系统的，底色这里自己铺令牌（系统底不是令牌，深色下不对）。
public struct CsSheetView: View {
    @ObservedObject var entry: CustomerServiceEntry
    let sheet: CsSheet
    let texts: MeTexts
    @AccessibilityFocusState private var titleFocused: Bool

    public init(entry: CustomerServiceEntry, sheet: CsSheet, texts: MeTexts) {
        self.entry = entry
        self.sheet = sheet
        self.texts = texts
    }

    /// 关闭与「去帮助中心」的命中边长：系统半屏（iOS 26）把内容缩到约 0.96，46 在屏上约 44。多出的 2 用负外边距收回，视觉位置不变。
    private static let hitSize = CouliHitTarget.minimum + CouliSpacing.s1 / 2

    /// 打不开、只有帮助是警告样式（G-P06），未装微信、HANDOFF 是中性样式。
    private var warns: Bool {
        sheet.decision.sheetRaw == CsEntryDecision.openFailed || sheet.decision.sheetRaw == CsEntryDecision.helpOnly
    }

    private var titleKey: String {
        warns ? "cs.open_failed.title" : "cs.title"
    }

    private var bodyKey: String {
        switch sheet.decision.sheetRaw {
        case CsEntryDecision.handoff: "cs.handoff.desc"
        case CsEntryDecision.openFailed: "cs.open_failed.desc"
        case CsEntryDecision.wechatMissing: "cs.wechat_unavailable"
        default: "cs.help_only.desc"
        }
    }

    public var body: some View {
        let actions = CsActions.make(entry, sheet)
        VStack(alignment: .leading, spacing: 0) {
            header(actions)
            CsScrollingBody {
                VStack(spacing: CouliSpacing.s4) {
                    MeText(texts.text(bodyKey), style: .footnote, probe: "cs.body.text")
                        .foregroundColor(CouliColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("cs.body")
                        .frame(maxWidth: .infinity)
                    safetyBar
                }
                .padding(.top, CouliSpacing.s3)
                .padding(.bottom, CouliSpacing.s4)
            }
            if let toast = entry.toast {
                MeText(toast.message(texts), style: .footnote, probe: "cs.toast.text")
                    .foregroundColor(toast.key == CustomerServiceEntry.copyFailed ? CouliColor.statusErrorText
                        : CouliColor.statusSuccessText)
                    .accessibilityIdentifier("cs.toast")
                    .padding(.bottom, CouliSpacing.s4)
                    .task(id: toast.id) {
                        MeAnnounce.post(toast.message(texts), assertive: false)
                    }
            }
            VStack(spacing: CouliSpacing.s3) {
                ForEach(sheet.decision.buttons, id: \.self) { button in
                    self.button(button, actions)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, CouliSpacing.s6 + CouliSpacing.s1)
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.bottom, CouliSpacing.s4)
        .meContentWidth()
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CouliColor.backgroundSurface.ignoresSafeArea())
        .meProbe("cs.panel", role: "panel")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cs.sheet." + sheet.decision.sheetRaw)
        .task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            titleFocused = true
        }
    }

    private func header(_ actions: CsActions) -> some View {
        // 标题左右让出关闭的位置，才能在整行上居中、不被命中区盖住。关闭在 overlay 里，不撑高标题行，读屏顺序仍在标题之后。
        VStack(spacing: CouliSpacing.s3) {
            CsBadge(warns: warns)
            MeText(texts.text(titleKey), style: .body, weight: .couliSemibold, probe: "cs.title.text")
                .foregroundColor(CouliColor.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
                .accessibilityIdentifier("cs.title")
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Self.hitSize - CouliSpacing.s2)
                .overlay(alignment: .topTrailing) {
                    Button(action: actions.close) {
                        CouliIconView(.close)
                            .foregroundColor(CouliColor.textSecondary)
                            .frame(minWidth: Self.hitSize, minHeight: Self.hitSize)
                            .contentShape(Rectangle())
                            .meProbe("cs.close.hit", role: "hit")
                    }
                    .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                    .padding(CouliHitTarget.minimum / 2 - Self.hitSize / 2 - CouliSpacing.s2)
                    .accessibilityLabel(Text(verbatim: texts.text("me.close")))
                    .accessibilityIdentifier("cs.close")
                }
        }
    }

    private var safetyBar: some View {
        SettingsNoticeBar(
            icon: .shieldCheck, iconColor: CouliColor.textPrimary, background: CouliColor.backgroundMuted,
            probe: "cs.safety.bar", iconProbe: "cs.safety.icon"
        ) {
            MeText(texts.text("cs.safety"), style: .footnote, probe: "cs.safety.text")
                .foregroundColor(CouliColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cs.safety")
    }

    @ViewBuilder
    private func button(_ raw: String, _ actions: CsActions) -> some View {
        switch raw {
        case CsEntryDecision.openWechat:
            let title = texts.text("cs.open_wechat")
            CouliButton(title, fillsWidth: true, action: actions.openWechat)
                .couliProbe("cs.openWechat.button", role: "button", text: title)
                .accessibilityIdentifier("cs.openWechat")
        case CsEntryDecision.retry:
            let title = texts.text("cs.retry")
            CouliButton(title, fillsWidth: true, action: actions.openWechat)
                .couliProbe("cs.retry.button", role: "button", text: title)
                .accessibilityIdentifier("cs.retry")
        case CsEntryDecision.copyLink:
            let title = texts.text("cs.copy_link")
            CouliButton(title, kind: sheet.decision.buttons.first == raw ? .primary : .secondary, fillsWidth: true,
                        weight: sheet.decision.buttons.first == raw ? .couliSemibold : .couliMedium,
                        action: actions.copyLink)
                .couliProbe("cs.copyLink.button", role: "button", text: title)
                .accessibilityIdentifier("cs.copyLink")
        default:
            helpControl(actions)
        }
    }

    /// 【去帮助中心】：打不开时是居中文字链接（G-P06 ④，14、链接色、命中约 46、屏上约 44、下划线同令牌说明），其余半屏是按钮；回调与标识都不变。
    @ViewBuilder
    private func helpControl(_ actions: CsActions) -> some View {
        let title = texts.text(sheet.decision.sheetRaw == CsEntryDecision.handoff ? "cs.handoff.go_help" : "cs.go_help")
        if sheet.decision.sheetRaw == CsEntryDecision.openFailed {
            Button(action: actions.goHelp) {
                MeText(title, style: .footnote, probe: "cs.help.link")
                    .foregroundColor(CouliColor.textLink)
                    .underline()
                    .padding(.horizontal, CouliSpacing.s2)
                    .frame(minHeight: Self.hitSize)
                    .contentShape(Rectangle())
                    .meProbe("cs.help.hit", role: "hit")
            }
            .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
            .padding(.vertical, CouliHitTarget.minimum / 2 - Self.hitSize / 2)
            .accessibilityIdentifier("cs.goHelp")
        } else {
            let only = sheet.decision.buttons.count == 1
            CouliButton(title, kind: only ? .primary : .secondary, fillsWidth: true,
                        weight: only ? .couliSemibold : .couliMedium, action: actions.goHelp)
                .couliProbe("cs.goHelp.button", role: "button", text: title)
                .accessibilityIdentifier("cs.goHelp")
        }
    }
}

/// 半屏头部图标块：56 × 56、圆角 16，图标 32（警告底 + 三角，或 muted 底 + 消息气泡）。方块不随字号变，图标跟着固定；装饰，读屏不读。
private struct CsBadge: View {
    private static let size = CouliSpacing.s12 + CouliSpacing.s2
    let warns: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(warns ? CouliColor.statusWarningBackground : CouliColor.backgroundMuted)
            CouliIconView(warns ? .alert : .chat, size: CouliSpacing.s8)
                .foregroundColor(warns ? CouliColor.statusWarningText : CouliColor.textSecondary)
                .meProbe("cs.badge.icon", role: "icon")
                .dynamicTypeSize(.large)
        }
        .frame(width: Self.size, height: Self.size)
        .meProbe("cs.badge", role: "badge")
        .accessibilityHidden(true)
    }
}

/// 放得下就贴内容高（按钮紧跟提示条），放不下才滚动（同 DS 半屏正文写法；DS 那个不公开，本组只加可选参数）。
private struct CsScrollingBody<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView {
                content
            }
        }
    }
}
