import CouliNetwork
import DesignSystem
import SwiftUI
import UIKit
import WalletCore

/// 钱包类页面的版式常量。
public enum WalletLayout {
    /// 大屏（最小宽度 ≥ 600）内容限宽居中（APP-05a 第 17 条，APP-07 第 8 条）。
    public static let maxContentWidth: CGFloat = 600
}

/// 每个页面实例一份的外壳接线（App 给）：文案、返回、发起页上的实名查询失败条（Android A18 同口径）。
@MainActor
public final class WalletPageContext: ObservableObject {
    public let texts: WalletTexts
    public var onBack: () -> Void = {}
    /// 打开要实名的资金页前实名查询失败（共性第 21 条）：显示在发起页（统一文案 + trace6）+【重试】【关闭】。
    @Published public var openError: Notice?
    public var retryOpen: () -> Void = {}
    public var dismissOpenError: () -> Void = {}
    /// 共享读请求禁用期（App 给的同一份 `WalletGates.read`）：错误卡的【重试】直接观察它，到期自动恢复（APP-09 共性第 72 条，iOS R1-09）。
    public let readGate: RetryAfterGate

    public init(texts: WalletTexts, readGate: RetryAfterGate) {
        self.texts = texts
        self.readGate = readGate
    }
}

/// 发起页实名查询失败卡的一次渲染（`OpenErrorCard` 与测试用同一个构造）：【重试】是否可用此刻按共享读禁用期现算，不另存布尔。
@MainActor
public struct OpenErrorModel {
    public let notice: Notice
    public let retryEnabled: Bool
    public let retry: () -> Void
    public let close: () -> Void

    public static func make(_ context: WalletPageContext) -> OpenErrorModel? {
        guard let notice = context.openError else { return nil }
        return OpenErrorModel(
            notice: notice, retryEnabled: !context.readGate.blocked, retry: context.retryOpen,
            close: context.dismissOpenError
        )
    }
}

/// 金额格式化只走 DesignSystem（整数分，format-vectors）。
enum WalletMoney {
    static func text(_ fen: Int64) -> String {
        CouliFormat.money(fen: fen)
    }

    static func spoken(_ fen: Int64) -> String {
        CouliFormat.moneySpoken(fen: fen)
    }
}

/// 播报的旁路观察：只供测试核对「按事件编号播报一次」（iOS R1-11）；生产为 nil。
@MainActor
public enum WalletAnnounceProbe {
    public static var observe: ((String) -> Void)?
}

/// 读屏播报：assertive 打断当前朗读；polite 排队（adaptation-a11y-spec §10）。
@MainActor
enum WalletAnnounce {
    static func post(_ text: String, assertive: Bool) {
        guard !text.isEmpty else { return }
        WalletAnnounceProbe.observe?(text)
        if assertive {
            UIAccessibility.post(notification: .announcement, argument: text)
        } else {
            let queued = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
            UIAccessibility.post(notification: .announcement, argument: queued)
        }
    }

    /// 脱敏号读法：「*」读作「星号」（adaptation-a11y-spec §9）。
    static func masked(_ text: String, texts: WalletTexts) -> String {
        text.replacingOccurrences(of: "*", with: texts.text("wallet.star_spoken"))
    }
}

/// 页内提示条（错误、限流、旧数据说明）：出现或换成新的一条时按 `assertive` 播报一次；可带【重试】。
struct NoticeBar: View {
    let text: String
    let noticeId: Int
    var assertive = true
    var retryTitle: String?
    var retryEnabled = true
    var retry: () -> Void = {}
    var identifier = "wallet.notice"

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
            WalletAnnounce.post(text, assertive: assertive)
        }
    }
}

/// 发起页底部的实名查询失败卡（共性第 21 条；代拟版式，iOS I09 同 Android A18）。
/// 记录页、钱包页、提现页等所有会触发实名查询的入口都渲染它（共性第 72 条，iOS R1-08）。
struct OpenErrorCard: View {
    @ObservedObject var context: WalletPageContext
    /// 直接观察共享读禁用期：到期时重绘，【重试】随之恢复（iOS R1-09）。
    @ObservedObject var readGate: RetryAfterGate

    init(context: WalletPageContext) {
        self.context = context
        readGate = context.readGate
    }

    var body: some View {
        if let model = OpenErrorModel.make(context) {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                NoticeBar(
                    text: model.notice.message(context.texts), noticeId: model.notice.id,
                    retryTitle: context.texts.text("wallet.retry"), retryEnabled: model.retryEnabled,
                    retry: model.retry, identifier: "wallet.openError"
                )
                CouliButton(context.texts.text("wallet.close"), kind: .text, size: .compact) {
                    model.close()
                }
                .accessibilityIdentifier("wallet.openError.close")
            }
            .padding(CouliSpacing.s4)
            .background(CouliColor.backgroundSurface.ignoresSafeArea(edges: .bottom))
        }
    }
}

/// 页面骨架：导航栏 + 内容（限宽居中）+ 底部固定区（主操作随键盘上移，AdaptKeyboardWithdraw）。
struct WalletPageScaffold<Content: View, Bottom: View>: View {
    let title: String
    let backLabel: String
    let onBack: () -> Void
    let identifier: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let bottom: () -> Bottom

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: title, backLabel: backLabel, onBack: onBack)
                .background(CouliColor.backgroundCanvas)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottom()
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        // 容器自己带标识、子元素保留各自的标识（不加 .contain 时外层标识会盖掉内层）
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// 卡片里的一行「标签 … 值」（明细、收款账号）；值可折行，读屏读「标签，值」。
struct WalletInfoRow: View {
    let label: String
    let value: String
    var spokenValue: String?
    var identifier: String?

    var body: some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s3, verticalSpacing: CouliSpacing.s1) {
            Text(verbatim: label)
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
            Text(verbatim: value)
                .couliFont(.footnote, monospacedDigits: true)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .couliFlowPushTrailing(.inlineOnly)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label + PriceTerms.spokenPause + (spokenValue ?? value)))
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// 问号按钮（44pt 命中区）。
struct WalletHelpButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CouliIconView(.help, size: CouliGuideMetric.iconInline, relativeTo: .caption)
                .couliHitTarget()
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
        .padding(-CouliSpacing.s3)
        .accessibilityLabel(Text(verbatim: label))
    }
}

extension Notice {
    /// 轻提示（DesignSystem 的 Toast）。
    func toast(_ texts: WalletTexts) -> CouliToastMessage {
        CouliToastMessage(message(texts))
    }
}

/// 问号说明半屏（WalletNote*、WithdrawNoteNet）：标题 + 关闭 + 说明 +【知道了】。
/// 钱包页按 WalletNote* 用正文 14/21 +【知道了】描边次按钮（W15）；缺省（提现页 WithdrawNoteNet）仍是正文 17 + 主按钮，本任务 a 组不改。
struct WalletHelpSheet: View {
    let title: String
    let text: String
    let texts: WalletTexts
    var bodyStyle: CouliTextStyle = .body
    var okKind: CouliButtonKind = .primary
    let close: () -> Void

    var body: some View {
        CouliSheet(title: title, closeLabel: texts.text("wallet.help.close"), onClose: close) {
            Text(verbatim: text)
                .couliFont(bodyStyle)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wallet.help.text")
        } actions: {
            CouliButton(texts.text("wallet.help.ok"), kind: okKind, fillsWidth: true, action: close)
                .accessibilityIdentifier("wallet.help.ok")
        }
    }
}
