import DesignSystem
import MeCore
import SwiftUI

/// 换手机号子页的辅助视图（从 PhoneChangeScreen.swift 原样搬出，只为控制类型体长度；行为、读屏标识、参数不变）：
/// 发码按钮、输入框描边、错误行、Done 卡、底部主按钮取值、弹窗。
extension PhoneChangeView {
    func sendButton(left: Int, sending: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        let title = left > 0 ? texts.format("bind_phone.countdown", ["n": String(left)]) : texts.text("login.get_code")
        return CouliButton(title, kind: .secondary, isLoading: sending, isEnabled: enabled, action: action)
            .fixedSize()
            .accessibilityIdentifier("phoneChange.getCode")
    }

    /// 普通 `border.control` 1、错误 `status.error.text` 2（错误优先）；输入中 `border.active` 2（同昵称子页）。
    func fieldBorder(error: Bool, focused: Bool) -> some View {
        let color = error ? CouliColor.statusErrorText : (focused ? CouliColor.borderActive : CouliColor.borderControl)
        let width = error || focused ? CouliSpacing.s1 / 2 : CouliComponentMetric.controlBorderWidth
        return RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
            .strokeBorder(color, lineWidth: width)
    }

    @ViewBuilder
    func errorRow(_ notice: MeNotice?, id: String) -> some View {
        if let notice {
            HStack(alignment: .top, spacing: CouliSpacing.s1) {
                CouliIconView(.alert, size: CouliComponentMetric.iconInline, relativeTo: .footnote)
                    .foregroundColor(CouliColor.statusErrorText)
                    .accessibilityHidden(true)
                MeText(notice.message(texts), style: .footnote, probe: id)
                    .foregroundColor(CouliColor.statusErrorText)
                    .accessibilityIdentifier(id)
            }
        }
    }

    // MARK: - Done

    func done(_ state: PhoneChangeState) -> some View {
        VStack(spacing: CouliSpacing.s3) {
            CouliIconView(.check, size: CouliComponentMetric.iconMedium)
                .foregroundColor(CouliColor.statusSuccessText)
                .accessibilityHidden(true)
            MeText(texts.text("phone_change.done.title"), style: .title, weight: .couliSemibold,
                   probe: "phoneChange.done.title")
                .foregroundColor(CouliColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            MeText(texts.format("phone_change.done.desc", ["phone": state.donePhoneDigits ?? ""]), style: .body,
                   monospacedDigits: true, probe: "phoneChange.done.desc")
                .foregroundColor(CouliColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .couliCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("phoneChange.done")
    }

    func primary(_ state: PhoneChangeState, _ actions: PhoneChangeActions) -> PhoneChangePrimary? {
        switch state.step {
        case .step1:
            PhoneChangePrimary(title: texts.text("phone_change.next"), loading: state.verifying,
                               enabled: controller.nextEnabled, action: actions.next)
        case .step2:
            PhoneChangePrimary(title: texts.text("phone_change.submit"), loading: state.submitting,
                               enabled: controller.submitEnabled, action: actions.submit)
        case .done:
            PhoneChangePrimary(title: texts.text("phone_change.finish"), loading: false, enabled: true,
                               action: actions.finish)
        case .pending:
            nil
        }
    }

    // MARK: - 弹窗

    func dialog(_ dialog: PhoneChangeDialog, _ actions: PhoneChangeActions) -> CouliDialog {
        switch dialog {
        case let .risk(titleKey, _):
            CouliDialog(
                title: texts.text(titleKey), message: texts.text("phone_change.risk_blocked.desc"),
                probeID: "phoneChange.dialog.risk",
                primary: CouliDialogAction(texts.text("phone_change.ok")) { actions.dismissDialog(dialog) },
                secondary: CouliDialogAction(texts.text("cs.appeal_entry")) { actions.contactService(dialog) }
            )
        case .unavailable:
            CouliDialog(
                title: texts.text("error.30414"), centeredTitle: true, probeID: "phoneChange.dialog.unavailable",
                primary: CouliDialogAction(texts.text("phone_change.ok")) { actions.dismissDialog(dialog) },
                secondary: CouliDialogAction(texts.text("phone_change.contact_cs")) { actions.contactService(dialog) }
            )
        case .abandon:
            CouliDialog(
                title: texts.text("pending_confirm.abandon"),
                message: texts.text("pending_confirm.abandon.confirm") + "\n"
                    + texts.text("phone_change.pending.abandon_note"),
                probeID: "phoneChange.dialog.abandon",
                onEscape: { actions.dismissDialog(dialog) },
                primary: CouliDialogAction(texts.text("pending_confirm.abandon.ok")) { actions.confirmAbandon(dialog) },
                secondary: CouliDialogAction(texts.text("pending_confirm.abandon.cancel")) {
                    actions.dismissDialog(dialog)
                }
            )
        }
    }
}
