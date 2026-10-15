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

/// 统一客服出口的三张半屏（设计稿 CsHandoff、CsWechatMissing、CsOpenFailed；brief §2.9，G20）：标题 → 关闭 → 正文 → 安全提示 → 按钮（
/// adaptation-a11y-spec §8）。正文放不下时只有正文滚动，按钮固定可见（短视口）。复制客服链接的结果显示在半屏里（polite 播报一次，A17）。
/// kf 缺失或不是 https 的降级半屏只有【去帮助中心】。由 App 以系统 `.sheet`（presentationDetents）盖在当前页面上。
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

    private var titleKey: String {
        sheet.decision.sheetRaw == CsEntryDecision.openFailed ? "cs.open_failed.title" : "cs.title"
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
        VStack(alignment: .leading, spacing: CouliSpacing.s4) {
            HStack(alignment: .top) {
                Text(verbatim: texts.text(titleKey))
                    .couliFont(.body, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                    .accessibilityIdentifier("cs.title")
                Spacer(minLength: CouliSpacing.s2)
                Button(action: actions.close) {
                    CouliIconView(.close)
                        .foregroundColor(CouliColor.textSecondary)
                        .couliHitTarget()
                }
                .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                .padding(-CouliSpacing.s2)
                .accessibilityLabel(Text(verbatim: texts.text("me.close")))
                .accessibilityIdentifier("cs.close")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                    Text(verbatim: texts.text(bodyKey))
                        .couliFont(.body)
                        .foregroundColor(CouliColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("cs.body")
                    HStack(alignment: .top, spacing: CouliSpacing.s2) {
                        CouliIconView(.info, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                            .accessibilityHidden(true)
                        Text(verbatim: texts.text("cs.safety"))
                            .couliFont(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("cs.safety")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let toast = entry.toast {
                Text(verbatim: toast.message(texts))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.statusSuccessText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cs.toast")
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
        .padding(.top, CouliSpacing.s5)
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.bottom, CouliSpacing.s4)
        .meContentWidth()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cs.sheet." + sheet.decision.sheetRaw)
        .task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            titleFocused = true
        }
    }

    @ViewBuilder
    private func button(_ raw: String, _ actions: CsActions) -> some View {
        switch raw {
        case CsEntryDecision.openWechat:
            CouliButton(texts.text("cs.open_wechat"), fillsWidth: true, action: actions.openWechat)
                .accessibilityIdentifier("cs.openWechat")
        case CsEntryDecision.retry:
            CouliButton(texts.text("cs.retry"), fillsWidth: true, action: actions.openWechat)
                .accessibilityIdentifier("cs.retry")
        case CsEntryDecision.copyLink:
            CouliButton(texts.text("cs.copy_link"), kind: sheet.decision.buttons.first == raw ? .primary : .secondary,
                        fillsWidth: true, action: actions.copyLink)
                .accessibilityIdentifier("cs.copyLink")
        default:
            CouliButton(
                texts.text(sheet.decision.sheetRaw == CsEntryDecision.handoff ? "cs.handoff.go_help" : "cs.go_help"),
                kind: sheet.decision.buttons.count == 1 ? .primary : .text, fillsWidth: true, action: actions.goHelp
            )
            .accessibilityIdentifier("cs.goHelp")
        }
    }
}
