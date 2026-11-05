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

    /// 纵向输入框里回车 / 粘贴带来的换行不进号码。
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
            HStack(spacing: 0) {
                Text(verbatim: text(LoginKeys.phonePrefix))
                    .couliFont(.title)
                    .foregroundColor(CouliColor.textPrimary)
                    .padding(.leading, CouliSpacing.s3)
                    .padding(.trailing, CouliSpacing.s3)
                    .accessibilityHidden(true)
                Rectangle().fill(CouliColor.borderSubtle).frame(width: 1, height: CouliSpacing.s6)
                    .accessibilityHidden(true)
                // 未聚焦时完整显示号码（R1-07）：放不下一行时换行（纵向轴、最多 3 行），不截成省略号、不缩字号；号码里不会有换行
                TextField(
                    text: Binding(get: { controller.phone }, set: { controller.setPhone(Self.singleLine($0)) }),
                    prompt: Text(verbatim: text(LoginKeys.phonePlaceholder)),
                    axis: .vertical
                ) {
                    Text(verbatim: text(LoginKeys.phoneLabel))
                }
                .lineLimit(1...3)
                .couliFont(.title)
                .foregroundColor(CouliColor.textPrimary)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .disabled(locked)
                .padding(.leading, CouliSpacing.s3)
                .frame(minHeight: CouliComponentMetric.controlMinHeight + CouliSpacing.s1)
                .focused($focus, equals: .phone)
                .accessibilityLabel(Text(verbatim: text(LoginKeys.phoneLabel) + " " + text(LoginKeys.phonePrefix)))
                .accessibilityHint(Text(verbatim: controller.phoneError ?? ""))
                .accessibilityIdentifier("bindPhone.phone")
                // 清除按钮只在聚焦且非空时出现（适配稿）：未聚焦时不占号码的宽度；出现时保留 44pt 命中区
                if focus == .phone, !controller.phone.isEmpty, !locked {
                    Button(action: controller.clearPhone) {
                        CouliIconView(.close, size: CouliGuideMetric.iconMedium)
                            .foregroundColor(CouliColor.textSecondary)
                            .couliHitTarget()
                    }
                    .buttonStyle(CouliPlainButtonStyle())
                    .accessibilityLabel(Text(verbatim: text(LoginKeys.phoneClear)))
                    .accessibilityIdentifier("bindPhone.phoneClear")
                }
            }
            .background(fieldBox(error: controller.phoneError != nil))
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
            // 窄屏、200% 字号放不下时「获取验证码 / N 秒后重新获取」换到输入下方（ViewThatFits）
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CouliSpacing.s2) {
                    codeInput
                    Rectangle().fill(CouliColor.borderSubtle).frame(width: 1, height: CouliSpacing.s6)
                        .accessibilityHidden(true)
                    sendButton.fixedSize()
                }
                .background(fieldBox(error: controller.codeError != nil))
                VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                    codeInput.background(fieldBox(error: controller.codeError != nil))
                    sendButton
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

    var sendButton: some View {
        let remaining = controller.resendRemaining
        let title = remaining > 0
            ? texts.format(BindPhoneKeys.countdown, ["n": String(remaining)]) : text(LoginKeys.getCode)
        return Button(action: controller.sendCode) {
            Text(verbatim: title)
                .couliFont(.body, monospacedDigits: true)
                .foregroundColor(controller.canSendCode ? CouliColor.brandEmphasis : CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, CouliSpacing.s3)
                .frame(minHeight: CouliHitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(CouliPlainButtonStyle())
        .disabled(!controller.canSendCode)
        .accessibilityIdentifier("bindPhone.getCode")
    }
}
