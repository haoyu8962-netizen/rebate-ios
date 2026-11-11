import DesignSystem
import SwiftUI

/// 绑手机页的表单区：手机号、验证码与【获取验证码】（从 BindPhoneView.swift 拆出）。
extension BindPhoneView {
    // MARK: - 表单

    var formCard: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s4) {
            phoneField
            codeField
        }
        .couliCard()
    }

    var locked: Bool {
        controller.inputsLocked
    }

    /// 粘贴带来的换行不进号码。
    static func singleLine(_ value: String) -> String {
        value.filter { !$0.isNewline }
    }

    func fieldBox(error: Bool) -> some View {
        RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
            .strokeBorder(error ? CouliColor.statusErrorText : (locked ? CouliColor.borderSubtle : CouliColor
                    .borderControl))
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .fill(locked ? CouliColor.backgroundMuted : CouliColor.backgroundSurface)
            )
    }

    var phoneField: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            Text(verbatim: text(LoginKeys.phoneLabel))
                .couliFont(.body)
                .foregroundColor(CouliColor.textSecondary)
                .accessibilityHidden(true)
            // 共用手机号组件（D10-1223）：单行、号码不在中间断；清除按钮只在聚焦且非空时出现（适配稿，未聚焦时不占号码的宽度）
            PhoneNumberField(
                text: Binding(get: { controller.phone }, set: { controller.setPhone(Self.singleLine($0)) }),
                prefix: text(LoginKeys.phonePrefix),
                placeholder: text(LoginKeys.phonePlaceholder),
                label: text(LoginKeys.phoneLabel),
                clearLabel: text(LoginKeys.phoneClear),
                identifier: "bindPhone.phone",
                focus: $focus,
                focusValue: .phone,
                hint: controller.phoneError ?? "",
                error: controller.phoneError != nil,
                locked: locked,
                showsClear: focus == .phone && !controller.phone.isEmpty && !locked,
                onClear: controller.clearPhone
            )
            if let error = controller.phoneError {
                Text(verbatim: error)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.statusErrorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($a11y, equals: .phoneError)
                    .accessibilityIdentifier("bindPhone.phoneError")
            }
        }
    }

    var codeField: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            Text(verbatim: text(LoginKeys.codeLabel))
                .couliFont(.body)
                .foregroundColor(CouliColor.textSecondary)
                .accessibilityHidden(true)
            // 窄屏、200% 字号放不下时「获取验证码 / N 秒后重新获取」换到输入下方（ViewThatFits），换成有描边的次按钮（D10-1223）；
            // 框内的按钮字按最长的倒计时文案占宽，发码前后不换排法
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CouliSpacing.s2) {
                    codeInput
                    Rectangle().fill(CouliColor.borderSubtle).frame(width: 1, height: CouliSpacing.s6)
                        .accessibilityHidden(true)
                    sendButton(boxed: true).fixedSize()
                }
                .background(fieldBox(error: controller.codeError != nil))
                VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                    codeInput.background(fieldBox(error: controller.codeError != nil))
                    sendButton(boxed: false)
                }
            }
            if let error = controller.codeError {
                Text(verbatim: error)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.statusErrorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($a11y, equals: .codeError)
                    .accessibilityIdentifier("bindPhone.codeError")
            }
        }
    }

    var codeInput: some View {
        TextField(
            text: Binding(get: { controller.code }, set: controller.setCode),
            prompt: Text(verbatim: text(BindPhoneKeys.codePlaceholder))
        ) {
            Text(verbatim: text(LoginKeys.codeLabel))
        }
        .couliFont(.title, monospacedDigits: true)
        .foregroundColor(CouliColor.textPrimary)
        .keyboardType(.numberPad)
        .textContentType(.oneTimeCode)
        .disabled(locked)
        .padding(.leading, CouliSpacing.s3)
        .frame(minHeight: CouliComponentMetric.controlMinHeight + CouliSpacing.s1)
        .focused($focus, equals: .code)
        .accessibilityLabel(Text(verbatim: text(LoginKeys.codeLabel)))
        .accessibilityHint(Text(verbatim: controller.codeError ?? ""))
        .accessibilityIdentifier("bindPhone.code")
    }

    var sendTitle: String {
        let remaining = controller.resendRemaining
        return remaining > 0
            ? texts.format(BindPhoneKeys.countdown, ["n": String(remaining)]) : text(LoginKeys.getCode)
    }

    /// 【获取验证码】：`boxed` 留在验证码框内右侧（与正常字号同样的强调色字，按最长文案占宽）；否则在框下方，
    /// 用有描边的次按钮（明确的按钮外观，高 ≥ 44pt，整行宽）。
    @ViewBuilder func sendButton(boxed: Bool) -> some View {
        if boxed {
            Button(action: controller.sendCode) {
                ZStack {
                    Text(verbatim: texts.format(BindPhoneKeys.countdown, ["n": "88"]))
                        .couliFont(.body, monospacedDigits: true)
                        .hidden()
                    Text(verbatim: sendTitle)
                        .couliFont(.body, monospacedDigits: true)
                        .foregroundColor(controller.canSendCode ? CouliColor.brandEmphasis : CouliColor.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, CouliSpacing.s3)
                .frame(minHeight: CouliHitTarget.minimum)
                .contentShape(Rectangle())
            }
            .buttonStyle(CouliPlainButtonStyle())
            .disabled(!controller.canSendCode)
            .accessibilityLabel(Text(verbatim: sendTitle))
            .accessibilityIdentifier("bindPhone.getCode")
        } else {
            CouliButton(sendTitle, kind: .secondary, size: .compact, isEnabled: controller.canSendCode,
                        fillsWidth: true, action: controller.sendCode)
                .accessibilityIdentifier("bindPhone.getCode")
        }
    }
}
