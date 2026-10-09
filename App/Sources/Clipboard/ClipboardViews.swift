import Clipboard
import DesignSystem
import Generated
import SwiftUI
import UIKit

/// 首页剪贴板区（HomeClipboard / HomeClipboardInvite / Main「粘贴链接，先查返利」卡）：只在首页 Tab 根页显示；大屏最大内容宽度、水平居中，
/// 放不下时可滚动（03 §10.4，共性第 8 条）。首页 SDUI 在 APP-11，这里挂在搜索框下面的固定位置。
struct HomeClipboardArea: View {
    @ObservedObject var clipboard: AppClipboard
    /// 最大内容宽度（03 §10.4，与搜索页同一取值）。
    static let maxWidth: CGFloat = 600

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .frame(maxWidth: Self.maxWidth)
        .frame(maxWidth: .infinity)
    }

    private var content: some View {
        VStack(spacing: CouliSpacing.s3) {
            if let prompt = clipboard.prompt {
                ProductPromptBar(clipboard: clipboard, prompt: prompt)
            }
            if let result = clipboard.result, AppClipboard.isHomeOrigin(result.origin) {
                ClipboardResultView(clipboard: clipboard, result: result, style: .home)
            }
            HomePasteCard(clipboard: clipboard)
        }
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.vertical, CouliSpacing.s2)
    }
}

/// 商品提示条（HomeClipboard）：「检测到商品链接，查返利？」+ 嵌在条内的系统粘贴控件（UIPasteControl，文字与读屏名由系统给）+ 独立【关闭】。
/// 出现时读屏播报一次。用户点了粘贴控件才拿到文本（brief §3 iOS）。
private struct ProductPromptBar: View {
    @ObservedObject var clipboard: AppClipboard
    let prompt: ClipboardPrompt

    var body: some View {
        PromptBarFrame(
            text: DefaultTexts.text("clipboard.prompt") ?? "",
            closeLabel: ClipboardDraftTexts.text("clipboard.prompt.close"),
            closeId: "clipboard.prompt.close",
            onClose: { clipboard.closePrompt(prompt.id) },
            action: {
                SystemPasteControl(
                    style: .plain,
                    isEnabled: clipboard.promptPasteEnabled,
                    identifier: "clipboard.prompt.paste"
                ) {
                    clipboard.beginPromptPaste(prompt.id)
                }
                .fixedSize()
            }
        )
        .accessibilityIdentifier("clipboard.prompt")
        .onAppear { UIAccessibility.post(
            notification: .announcement,
            argument: DefaultTexts.text("clipboard.prompt")
        ) }
    }
}

/// 提示条的版式（设计稿：白底圆角浮起卡片，左文案 14/600，右按钮，独立【关闭】48pt 命中区）。
struct PromptBarFrame<Action: View>: View {
    let text: String
    let closeLabel: String
    let closeId: String
    let onClose: () -> Void
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: CouliSpacing.s2) {
            Text(verbatim: text)
                .couliFont(.footnote, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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

/// 首页「粘贴链接，先查返利」卡（Main / HomeGuest / HomeClipboard）：品牌浅底、标题 17/600、副标题 12；iOS 的「去粘贴」位置是系统粘贴控件
/// （文字「粘贴」由系统给，差异见 compare-ios.md）。说明文字可被读屏读到。
private struct HomePasteCard: View {
    @ObservedObject var clipboard: AppClipboard

    var body: some View {
        HStack(spacing: CouliSpacing.s3) {
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                Text(verbatim: ClipboardDraftTexts.text("clipboard.home_card.title"))
                    .couliFont(.body, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: ClipboardDraftTexts.text("clipboard.home_card.subtitle"))
                    .couliFont(.caption)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("clipboard.homeCard.text")
            SystemPasteControl(
                style: .capsule,
                isEnabled: clipboard.pasteEnabled,
                identifier: "clipboard.homeCard.paste"
            ) {
                clipboard.beginPaste(entry: ManualPasteAction.entryHome)
            }
            .fixedSize()
        }
        .padding(CouliSpacing.s4)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.brandSubtle)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipboard.homeCard")
    }
}

/// SearchTyping「粘贴查返利」：上方说明文字 12，下方整行系统粘贴控件（图标 + 系统文字，品牌浅底）。
struct SearchPasteEntry: View {
    @ObservedObject var clipboard: AppClipboard

    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            Text(verbatim: ClipboardDraftTexts.text("clipboard.paste_entry.hint"))
                .couliFont(.caption)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("clipboard.searchPaste.hint")
            SystemPasteControl(
                style: .tinted,
                isEnabled: clipboard.pasteEnabled,
                identifier: "clipboard.searchPaste"
            ) {
                clipboard.beginPaste(entry: ManualPasteAction.entrySearchTyping)
            }
        }
        .padding(CouliSpacing.s3)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.backgroundSurface)
        )
        .accessibilityElement(children: .contain)
    }
}

/// 搜索页的粘贴结果（只显示本页发起的）。
struct SearchPasteResult: View {
    @ObservedObject var clipboard: AppClipboard
    let origin: String

    var body: some View {
        if let result = clipboard.result, result.origin == origin {
            ClipboardResultView(clipboard: clipboard, result: result, style: .search)
        }
    }
}

/// 结果的显示：轻提示、30132（ShareHubInvalid 的提示样式 +【用商品名搜索】）、邀请确认（首页按邀请提示条 HomeClipboardInvite 的样式）、
/// 多卡弹层（没有专稿，按搜索卡样式，compare-ios.md 写明）。按钮回调绑定渲染时的结果编号（共性第 18、26 条）。
struct ClipboardResultView: View {
    enum Style {
        case home
        case search
    }

    @ObservedObject var clipboard: AppClipboard
    let result: ClipboardResult
    let style: Style

    var body: some View {
        content
            // 读屏播报绑定结果编号（R3-02，共性第 33 条）：连续两次同类结果（如两次错误条）原先视图身份不变、onAppear 不再执行。
            // 这里视图身份绑定 result.id，每个新结果是新视图、出现时播报一次；普通重绘不触发，视图重新出现时由 announceResult 按编号去重。
            .onAppear {
                if let text = announcement {
                    clipboard.announceResult(result.id, text: text)
                }
            }
            .id(result.id)
    }

    /// 本结果出现时的播报文案；多卡弹层没有（弹层自身的出现由系统读屏处理）。
    private var announcement: String? {
        switch result.kind {
        case let .notice(text), let .unrecognized(text, _): text
        case let .inviteConfirm(code): InvitePromptBar.text(code)
        case .cardList: nil
        }
    }

    @ViewBuilder private var content: some View {
        switch result.kind {
        case let .notice(text):
            ErrorNoticeRow(
                text: text,
                closeId: "clipboard.notice.close",
                onClose: { clipboard.dismissResult(result.id) }
            )
            .accessibilityIdentifier("clipboard.notice")
        case let .unrecognized(text, prefill):
            ErrorNoticeRow(
                text: text, closeId: "clipboard.notice.close",
                action: NoticeAction(title: ClipboardDraftTexts.text("clipboard.search_by_name")) {
                    clipboard.searchByName(result.id, prefill: prefill)
                },
                onClose: { clipboard.dismissResult(result.id) }
            )
            .accessibilityIdentifier("clipboard.unrecognized")
        case let .inviteConfirm(code):
            InvitePromptBar(clipboard: clipboard, id: result.id, code: code)
        case .cardList:
            // 弹层盖在整页上（RootView 的 clipboardCardSheet）
            EmptyView()
        }
    }
}

/// 邀请提示条（HomeClipboardInvite）：「检测到好友邀请码 {invite_code}，绑定为邀请人？」+【粘贴】（读屏名「粘贴并绑定邀请人」）+【关闭】。
/// 出现时的播报由 ClipboardResultView 按结果编号发出（R3-02）。
/// iOS 在这之前已经由用户点系统粘贴控件读到文本，这里的按钮只确认、不再读剪贴板。
private struct InvitePromptBar: View {
    @ObservedObject var clipboard: AppClipboard
    let id: Int64
    let code: String

    static func text(_ code: String) -> String {
        ClipboardDraftTexts.format("clipboard.invite_prompt", ["invite_code": code])
    }

    var body: some View {
        let text = Self.text(code)
        PromptBarFrame(
            text: text,
            closeLabel: ClipboardDraftTexts.text("clipboard.prompt.close"),
            closeId: "clipboard.invite.close",
            onClose: { clipboard.dismissResult(id) },
            action: {
                Button { clipboard.confirmInvite(id) } label: {
                    Text(verbatim: ClipboardDraftTexts.text("clipboard.invite_prompt.action"))
                        .couliFont(.footnote, weight: .couliSemibold)
                        .foregroundColor(CouliColor.brandEmphasis)
                        .padding(.horizontal, CouliSpacing.s3)
                        .frame(minHeight: CouliHitTarget.minimum)
                        .background(Capsule().fill(CouliColor.backgroundMuted))
                }
                .buttonStyle(.plain)
                .disabled(clipboard.blocked)
                .accessibilityLabel(Text(verbatim: ClipboardDraftTexts.text("clipboard.invite_prompt.action_label")))
                .accessibilityIdentifier("clipboard.invite.confirm")
            }
        )
        .accessibilityIdentifier("clipboard.invitePrompt")
    }
}

/// 提示里的动作按钮（【用商品名搜索】）。
private struct NoticeAction {
    let title: String
    let perform: () -> Void
}

/// ShareHubInvalid 的提示样式：错误底色圆角 12，图标 + 文案 +（可选）动作按钮 + 关闭。
private struct ErrorNoticeRow: View {
    let text: String
    let closeId: String
    var action: NoticeAction?
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: CouliSpacing.s2) {
            CouliIconView(.alert, size: 18, relativeTo: .footnote)
                .foregroundColor(CouliColor.statusErrorText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                Text(verbatim: text)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action: action.perform) {
                        Text(verbatim: action.title)
                            .couliFont(.footnote, weight: .couliSemibold)
                            .foregroundColor(CouliColor.textLink)
                            .frame(minHeight: CouliHitTarget.minimum, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("clipboard.searchByName")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                CouliIconView(.close, size: 16)
                    .foregroundColor(CouliColor.textSecondary)
                    .couliHitTarget()
            }
            .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
            .accessibilityLabel(Text(verbatim: ClipboardDraftTexts.text("clipboard.notice.close")))
            .accessibilityIdentifier(closeId)
        }
        .padding(.leading, CouliSpacing.s3)
        .padding(.vertical, CouliSpacing.s2)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .fill(CouliColor.statusErrorText.opacity(0.08))
        )
        .accessibilityElement(children: .contain)
    }
}
