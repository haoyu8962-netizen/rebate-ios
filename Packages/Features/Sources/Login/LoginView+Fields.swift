import DesignSystem
import SwiftUI

/// 登录页的输入区：手机号、协议行、邀请码、第三方登录位置。
extension LoginView {
    var phoneField: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            Text(verbatim: text(LoginKeys.phoneLabel))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .accessibilityHidden(true)
            HStack(spacing: 0) {
                Text(verbatim: text(LoginKeys.phonePrefix))
                    .couliFont(.title)
                    .foregroundColor(CouliColor.textPrimary)
                    .padding(.leading, CouliSpacing.s4)
                    .padding(.trailing, CouliSpacing.s3)
                    .accessibilityHidden(true)
                Rectangle()
                    .fill(CouliColor.borderSubtle)
                    .frame(width: 1, height: CouliSpacing.s6)
                    .accessibilityHidden(true)
                TextField(
                    text: Binding(get: { model.phoneText }, set: model.setPhone),
                    prompt: Text(verbatim: text(LoginKeys.phonePlaceholder))
                ) {
                    Text(verbatim: text(LoginKeys.phoneLabel))
                }
                .couliFont(.title)
                .foregroundColor(CouliColor.textPrimary)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .padding(.horizontal, CouliSpacing.s3)
                .frame(minHeight: CouliComponentMetric.controlMinHeight + CouliSpacing.s1)
                .accessibilityLabel(Text(verbatim: text(LoginKeys.phoneLabel) + " " + text(LoginKeys.phonePrefix)))
                .focused($phoneFocused)
                .accessibilityIdentifier("login.phone")
                if !model.phoneText.isEmpty {
                    Button(action: model.clearPhone) {
                        CouliIconView(.close, size: CouliComponentMetric.iconMedium)
                            .foregroundColor(CouliColor.textSecondary)
                            .couliHitTarget()
                    }
                    .buttonStyle(CouliPlainButtonStyle())
                    .accessibilityLabel(Text(verbatim: text(LoginKeys.phoneClear)))
                    .accessibilityIdentifier("login.phoneClear")
                }
            }
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .fill(CouliColor.backgroundSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .strokeBorder(model.phoneError.isEmpty ? CouliColor.borderControl : CouliColor.statusErrorText)
            )
            if !model.phoneError.isEmpty {
                Text(verbatim: model.phoneError)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.statusErrorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("login.phoneError")
            }
        }
    }

    /// 协议行（BR-ID-04；A11yFocusLogin 第 6–8 项、A11yHitLogin；共性 6）：一行可换行的流式布局——「复选框 +『我已阅读
    /// 并同意』」是一个读屏单元、一个命中区（选中态 + 自动注册说明作提示），点它切换勾选；《用户协议》《隐私政策》是两个
    /// 独立链接，各自至少 44pt 命中区。窄屏、大字号时整节换行，命中区不重叠。
    var agreementRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            CouliFlowLayout(horizontalSpacing: 0, verticalSpacing: 0) {
                Button(action: model.toggleAgreement) {
                    HStack(spacing: CouliSpacing.s3) {
                        CheckBox(checked: model.agreed)
                        Text(verbatim: text(LoginKeys.agreePrefix))
                            .couliFont(.footnote)
                            .foregroundColor(CouliColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(minHeight: CouliHitTarget.minimum)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CouliPlainButtonStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: text(LoginKeys.agreePrefix)))
                .accessibilityHint(Text(verbatim: text(LoginKeys.agreeHint)))
                .accessibilityAddTraits(model.agreed ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("login.agreeCheckbox")
                AgreementLinkButton(title: text(LoginKeys.agreeAgreement), id: "login.link.agreement") {
                    model.config.onAgreement(LoginViewModel.agreementType)
                }
                PlainPiece(text(LoginKeys.agreeAnd))
                AgreementLinkButton(title: text(LoginKeys.agreePrivacy), id: "login.link.privacy") {
                    model.config.onAgreement(LoginViewModel.privacyType)
                }
                PlainPiece(text(LoginKeys.agreeSuffix))
            }
            Text(verbatim: text(LoginKeys.agreeHint))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, CheckBox.side + CouliSpacing.s3)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var inviteField: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            Text(verbatim: text(LoginKeys.inviteLabel))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .accessibilityHidden(true)
            HStack(spacing: 0) {
                TextField(
                    text: $model.inviteText,
                    prompt: Text(verbatim: text(LoginKeys.invitePlaceholder))
                ) {
                    Text(verbatim: text(LoginKeys.inviteLabel))
                }
                .couliFont(.title)
                .foregroundColor(CouliColor.textPrimary)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(.horizontal, CouliSpacing.s4)
                .frame(minHeight: CouliComponentMetric.controlMinHeight + CouliSpacing.s1)
                .accessibilityLabel(Text(verbatim: text(LoginKeys.inviteLabel)))
                .accessibilityIdentifier("login.invite")
                if !model.inviteText.isEmpty {
                    Button { model.inviteText = "" } label: {
                        CouliIconView(.close, size: CouliComponentMetric.iconMedium)
                            .foregroundColor(CouliColor.textSecondary)
                            .couliHitTarget()
                    }
                    .buttonStyle(CouliPlainButtonStyle())
                    .accessibilityLabel(Text(verbatim: text(LoginKeys.inviteClear)))
                }
                if let paste = model.config.invitePaste {
                    InvitePasteButton(paste: paste, model: model)
                        .padding(.trailing, CouliSpacing.s2)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .fill(CouliColor.backgroundSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .strokeBorder(CouliColor.borderControl)
            )
            // 告知句（BR-INV-18 细则）：输入框下方，有效码与无效码都显示；语法不对不拦登录（INVITE-01）。
            Text(verbatim: text(model.inviteDecision.noticeKey ?? InviteField.noticeKey))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("login.inviteNotice")
        }
    }
}

/// 邀请码行【粘贴】（APP-07，LoginCodeInvite）：系统粘贴控件（文字与读屏名由系统给），用户点了才读；只抽码填入，抽不到轻提示、不清空已有
/// 输入（BR-INV-04）。42901 禁用期内置灰（共性第 6 条）。
struct InvitePasteButton: View {
    @ObservedObject var paste: LoginInvitePaste
    let model: LoginViewModel

    var body: some View {
        SystemPasteControl(style: .plain, isEnabled: paste.enabled, identifier: "login.invitePaste") {
            guard let handle = paste.begin() else { return nil }
            return { [model] text in
                switch handle(text) {
                case let .code(code):
                    model.inviteText = code
                case let .message(message):
                    model.toast = CouliToastMessage(message)
                case .ignored:
                    break
                }
            }
        }
        .fixedSize()
    }
}
