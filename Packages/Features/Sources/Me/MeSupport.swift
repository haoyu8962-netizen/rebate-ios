import DesignSystem
import MeCore
import SwiftUI
import UIKit

/// 「我的」类页面的版式常量。
public enum MeLayout {
    /// 大屏（最小宽度 ≥ 600）内容限宽居中（APP-05a 第 17 条，APP-07 第 8 条）。
    public static let maxContentWidth: CGFloat = 600
}

/// 播报的旁路观察：只供测试核对「按提示编号播报一次」；生产为 nil。
@MainActor
public enum MeAnnounceProbe {
    public static var observe: ((String, Bool) -> Void)?
    /// 无障碍焦点移到错误节点（布局完成之后）时带错误节点的标识回调；生产为 nil。
    public static var focused: ((String) -> Void)?
    /// 交给页顶轻提示（DesignSystem Toast：每个新请求礼貌播报一次）时带提示文字回调；生产为 nil。
    public static var toast: ((String) -> Void)?
}

/// 一次性提示 → 轻提示请求（每次都是新请求：显示、重新计时、播报一次）。
@MainActor
enum MeToastMessage {
    static func make(_ notice: MeNotice, texts: MeTexts) -> CouliToastMessage {
        let text = notice.message(texts)
        MeAnnounceProbe.toast?(text)
        return CouliToastMessage(text)
    }
}

/// 读屏播报：assertive 打断当前朗读；polite 排队（adaptation-a11y-spec §10）。
@MainActor
enum MeAnnounce {
    static func post(_ text: String, assertive: Bool) {
        guard !text.isEmpty else { return }
        MeAnnounceProbe.observe?(text, assertive)
        if assertive {
            UIAccessibility.post(notification: .announcement, argument: text)
        } else {
            let queued = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
            UIAccessibility.post(notification: .announcement, argument: queued)
        }
    }
}

/// 一次性提示 → 页顶轻提示（DesignSystem Toast，polite 播报一次）：提示变化时用回调给的**新值**换成新的轻提示并交回「已消费」。
/// 不在 onChange 闭包里读 `notice`：iOS 16 上闭包捕获的是上一次渲染的修饰器（首次提示读到 nil，之后读到上一条，R3-01）。
struct MeToastBridge: ViewModifier {
    let notice: MeNotice?
    let texts: MeTexts
    let consume: (Int) -> Void
    @State private var toast: CouliToastMessage?

    func body(content: Content) -> some View {
        content
            .couliToast($toast)
            .onChange(of: notice) { show($0) }
            .onAppear { show(notice) }
    }

    private func show(_ notice: MeNotice?) {
        guard let notice else { return }
        toast = MeToastMessage.make(notice, texts: texts)
        consume(notice.id)
    }
}

extension View {
    func meToast(_ notice: MeNotice?, texts: MeTexts, consume: @escaping (Int) -> Void) -> some View {
        modifier(MeToastBridge(notice: notice, texts: texts, consume: consume))
    }

    /// 二级页的系统导航栏（行内标题；返回按钮由系统给，读屏、侧滑返回照系统）。
    func meNavigation(_ title: String) -> some View {
        navigationTitle(Text(verbatim: title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }

    /// 内容限宽居中（大屏），小屏铺满。
    func meContentWidth() -> some View {
        frame(maxWidth: MeLayout.maxContentWidth).frame(maxWidth: .infinity)
    }
}

/// 列表里的一行（设置、隐私中心）：标题 + 可选的值 + 箭头；可点时整行是命中区（min-height 44 加上下内边距，adaptation-a11y-spec §2）；不可点时
/// 不画箭头、不画成按钮（G01、G07）。
struct MeRow: View {
    let title: String
    var value: String?
    var subtitle: String?
    var clickable = true
    /// 可点但暂不可用（如 42901 禁用期）：置灰、不响应。
    var enabled = true
    var identifier: String
    var action: () -> Void = {}

    var body: some View {
        if clickable {
            Button(action: action) {
                content(chevron: true)
            }
            .buttonStyle(CouliPlainButtonStyle(cornerRadius: 0))
            .disabled(!enabled)
            .accessibilityIdentifier(identifier)
        } else {
            content(chevron: false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
        }
    }

    private func content(chevron: Bool) -> some View {
        HStack(alignment: .center, spacing: CouliSpacing.s3) {
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                Text(verbatim: title)
                    .couliFont(.body)
                    .foregroundColor(enabled ? CouliColor.textPrimary : CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                Text(verbatim: value)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if chevron {
                CouliIconView(.chevron, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.vertical, CouliSpacing.s3)
        .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 开关行（个性化推荐、服务类推送）：整行一个读屏节点，读作「{名称}，开关，已打开 / 已关闭」（A11yFocusStyles）。
struct MeSwitchRow: View {
    let title: String
    var subtitle: String?
    let isOn: Bool
    var enabled = true
    let texts: MeTexts
    let identifier: String
    let onChange: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { onChange($0) })) {
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                Text(verbatim: title)
                    .couliFont(.body)
                    .foregroundColor(enabled ? CouliColor.textPrimary : CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(CouliColor.brandPrimary)
        .disabled(!enabled)
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.vertical, CouliSpacing.s3)
        .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: texts.text("me.switch.role") + PriceTerms.spokenPause
                + texts.text(isOn ? "me.switch.on" : "me.switch.off")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if enabled {
                onChange(!isOn)
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

/// 白卡片分组（标题可空）。
struct MeGroup<Content: View>: View {
    var title: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            if let title, !title.isEmpty {
                Text(verbatim: title)
                    .couliFont(.footnote, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textSecondary)
                    .padding(.horizontal, CouliSpacing.s1)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                content()
            }
            .couliCard(padding: 0)
        }
    }
}

/// 页内提示条（错误、限流）：出现或换成新的一条时按 `assertive` 播报一次；可带【重试】（受共享禁用期控制）。
struct MeNoticeBar: View {
    let text: String
    let noticeId: Int
    var assertive = true
    var retryTitle: String?
    var retryEnabled = true
    var retry: () -> Void = {}
    var identifier: String

    var body: some View {
        HStack(alignment: .center, spacing: CouliSpacing.s3) {
            CouliIconView(.alert, size: CouliGuideMetric.iconMedium, relativeTo: .footnote)
                .foregroundColor(CouliColor.statusWarningText)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(identifier + ".text")
            if let retryTitle {
                CouliButton(retryTitle, kind: .secondary, size: .compact, isEnabled: retryEnabled, action: retry)
                    .fixedSize()
                    .accessibilityIdentifier(identifier + ".retry")
            }
        }
        .padding(CouliSpacing.s3)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous).fill(CouliColor.backgroundMuted)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .task(id: noticeId) {
            MeAnnounce.post(text, assertive: assertive)
        }
    }
}

/// 卡片里的一行「标签 … 值」；值可折行，读屏读「标签，值」。
struct MeInfoRow: View {
    let label: String
    let value: String
    var identifier: String?

    var body: some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s3, verticalSpacing: CouliSpacing.s1) {
            Text(verbatim: label)
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
            Text(verbatim: value)
                .couliFont(.footnote, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .couliFlowPushTrailing(.inlineOnly)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label + PriceTerms.spokenPause + value))
        .modifier(MeOptionalIdentifier(identifier: identifier))
    }
}

struct MeOptionalIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

/// 金额只走 DesignSystem 的格式化（整数分）。
enum MeMoney {
    static func text(_ fen: Int64) -> String {
        CouliFormat.money(fen: fen)
    }

    static func spoken(_ fen: Int64) -> String {
        CouliFormat.moneySpoken(fen: fen)
    }
}
