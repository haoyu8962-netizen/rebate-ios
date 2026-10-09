import DesignSystem
import SwiftUI

/// 登录页的验证码步与弹窗（LoginCode、LoginAgreeConfirm、LoginCodeBlocked、LoginDeletionProcessing）。
extension LoginView {
    // MARK: - 验证码步

    var codeStep: some View {
        VStack(spacing: CouliSpacing.s5) {
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                Text(verbatim: text(LoginKeys.codeTitle))
                    .couliFont(.heading, weight: .couliBold)
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                    .accessibilityIdentifier("login.codeTitle")
                Text(verbatim: model.format(LoginKeys.codeSentTo, "phone", model.sentTo))
                    .couliFont(.body)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, CouliSpacing.s4)
            CodeCells(
                code: model.codeText,
                hasError: !model.codeError.isEmpty,
                label: text(LoginKeys.codeLabel),
                binding: Binding(get: { model.codeText }, set: model.setCode),
                focused: $codeFocused
            )
            if !model.codeError.isEmpty {
                Text(verbatim: model.codeError)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.statusErrorText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("login.codeError")
            }
            HStack {
                Spacer()
                if model.resendCountdown > 0 {
                    Text(verbatim: model.format(LoginKeys.codeCountdown, "sec", String(model.resendCountdown)))
                        .couliFont(.body, monospacedDigits: true)
                        .foregroundColor(CouliColor.textSecondary)
                        .accessibilityIdentifier("login.countdown")
                } else {
                    Button(action: model.requestCode) {
                        Text(verbatim: text(LoginKeys.codeResend))
                            .couliFont(.body, weight: .couliMedium)
                            .foregroundColor(model.sendRateLimited ? CouliColor.textSecondary : CouliColor
                                .brandEmphasis)
                            .couliHitTarget()
                    }
                    .buttonStyle(CouliPlainButtonStyle())
                    .disabled(model.sendRateLimited || model.sending)
                    .accessibilityIdentifier("login.resend")
                }
            }
            if !restricted {
                inviteField
                    // 游客在剪贴板邀请提示点了确认（APP-07，G16）：进入验证码页时填一次
                    .onAppear(perform: model.applyInvitePrefill)
            }
            agreementRow
            CouliButton(
                text(LoginKeys.submit),
                isLoading: model.submitting,
                isEnabled: model.canSubmit,
                fillsWidth: true,
                action: model.submit
            )
            .accessibilityFocused($submitFocused)
            .accessibilityIdentifier("login.submit")
            Spacer(minLength: CouliSpacing.s8)
            helpEntry
        }
        .onAppear {
            codeFocused = true
        }
    }

    // MARK: - 弹窗

    var dialog: CouliDialog {
        switch model.dialog {
        case let .blocked(titleKey):
            CouliDialog(
                title: text(titleKey),
                message: text(LoginKeys.riskBlockedDesc),
                primary: CouliDialogAction(text(LoginKeys.riskBlockedOK)) { model.dialog = nil },
                secondary: CouliDialogAction(text(LoginKeys.appeal)) {
                    model.dialog = nil
                    model.config.onCustomerService()
                }
            )
        case .deletionProcessing:
            CouliDialog(
                title: text(LoginKeys.deletionTitle),
                message: text(LoginKeys.deletionBody),
                primary: CouliDialogAction(text(LoginKeys.deletionOK)) { model.dialog = nil },
                secondary: CouliDialogAction(text(LoginKeys.deletionCS)) {
                    model.dialog = nil
                    model.config.onCustomerService()
                }
            )
        default:
            // LoginAgreeConfirm（共性 8）：正文里的《用户协议》《隐私政策》是两个可点、读屏可单独聚焦的链接（各 44pt 命中区）。
            CouliDialog(
                title: text(LoginKeys.confirmTitle),
                centeredTitle: true,
                primary: CouliDialogAction(text(LoginKeys.confirmOK), action: model.confirmAgreement),
                secondary: CouliDialogAction(text(LoginKeys.confirmCancel), action: model.cancelAgreement)
            ) {
                CouliFlowLayout(horizontalSpacing: 0, verticalSpacing: 0) {
                    PlainPiece(text(LoginKeys.confirmBodyPrefix), primary: true)
                    AgreementLinkButton(title: text(LoginKeys.agreeAgreement), id: "login.confirm.agreement") {
                        model.openAgreementFromConfirm(LoginViewModel.agreementType)
                    }
                    PlainPiece(text(LoginKeys.agreeAnd), primary: true)
                    AgreementLinkButton(title: text(LoginKeys.agreePrivacy), id: "login.confirm.privacy") {
                        model.openAgreementFromConfirm(LoginViewModel.privacyType)
                    }
                    PlainPiece(text(LoginKeys.confirmBodySuffix), primary: true)
                }
            }
        }
    }
}
