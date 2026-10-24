import DesignSystem
import SwiftUI

/// 剪贴板首次用途说明（HomeClipboardConsent-v3；BR-ID-16 细则「首次用途说明弹层」，文案 BR-TEXT-14 表 D `clipboard.consent.*`）的显示状态。
///
/// APP-11v-b 只做版式：底部半屏、标题 22/600 左对齐、正文、底部【暂不开启】【开启】并排等宽；返回 / 点遮罩 / 下滑都按【暂不开启】。
/// TODO(FU-IOS BR-ID-16 系列)：iOS 还没有 BR-ID-16 新版的读取协调器、功能同意版本与设置项（Android FU-AND-0722～0725 已做），
/// 生产代码里还没有任何出口调 `present`，本任务不加触发（G26：剪贴板识别行为不变）。系列开工时由协调器在「首次点粘贴入口 /
/// 打开自动识别开关」时调 `present`，并把 `onEnable` / `onNotNow` 接到 ImportPreferenceStore（enable 记功能同意版本 + 设备级
/// consent；notNow 记已看过）。
@MainActor
final class ClipboardConsentNotice: ObservableObject {
    @Published private(set) var shown = false
    /// 【开启】被点的次数（不含内容；Debug 诊断 `consentRequests` 读它）。
    private(set) var enableCount = 0
    var onEnable: @MainActor () -> Void = {}
    var onNotNow: @MainActor () -> Void = {}

    func present() {
        shown = true
    }

    func enable() {
        guard shown else { return }
        shown = false
        enableCount += 1
        onEnable()
    }

    /// 【暂不开启】、返回、点遮罩、下滑：都只记「看过」，不记同意。
    func notNow() {
        guard shown else { return }
        shown = false
        onNotNow()
    }
}

extension View {
    /// 用途说明半屏盖在整个导航栈上（与多卡弹层同一层级）。
    func clipboardConsentSheet(_ notice: ClipboardConsentNotice) -> some View {
        modifier(ClipboardConsentSheetModifier(notice: notice))
    }
}

private struct ClipboardConsentSheetModifier: ViewModifier {
    @ObservedObject var notice: ClipboardConsentNotice

    func body(content: Content) -> some View {
        content.couliSheet(
            isPresented: notice.shown,
            dismissOnScrim: { notice.notNow() },
            dismissal: CouliSheetDismissal(
                label: ClipboardDraftTexts.text("clipboard.notice.close"),
                identifier: "clipboard.consent.scrim",
                dismissOnSwipe: true
            ),
            sheet: {
                CouliChoiceSheet(
                    title: ClipboardDraftTexts.text("clipboard.consent.title"),
                    message: ClipboardDraftTexts.text("clipboard.consent.body"),
                    primary: CouliDialogAction(ClipboardDraftTexts.text("clipboard.consent.enable")) {
                        notice.enable()
                    },
                    secondary: CouliDialogAction(ClipboardDraftTexts.text("clipboard.consent.not_now")) {
                        notice.notNow()
                    },
                    primaryID: "clipboard.consent.enable",
                    secondaryID: "clipboard.consent.notNow",
                    titleID: "clipboard.consent.title"
                )
                // 读屏「返回」手势（双指 Z）同【暂不开启】
                .accessibilityAction(.escape) { notice.notNow() }
                .accessibilityIdentifier("clipboard.consent.sheet")
            }
        )
    }
}
