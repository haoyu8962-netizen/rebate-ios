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
                    // 出错立即播报，播完读屏焦点移到这一行（FU-IOS-A11Y-03）
                    .couliAnnounceThenFocus(model.codeError, trigger: model.codeErrorCount,
                                            focusProbeID: "login.codeError")
                    .accessibilityIdentifier("login.codeError")
            }
            HStack {
                Spacer()
                if model.resendCountdown > 0 {
                    Text(verbatim: model.format(LoginKeys.codeCountdown, "n", String(model.resendCountdown)))
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
            }
            agreementRow
            // 键盘收起时【登录】在协议行之下（原位）；键盘弹起时移到底栏，这里不渲染，同一时刻只有一个实例
            if !submitPinned {
                submitButton
            }
            Spacer(minLength: CouliSpacing.s8)
            helpEntry
        }
        .onAppear {
            codeFocused = true
        }
    }

    // MARK: - 【登录】钉底（FU-LOGIN-KEYBOARD-AVOID-ios r2，D10-2458）

    /// 验证码步且键盘弹起：【登录】钉在键盘上方。
    var submitPinned: Bool {
        model.step == .code && keyboardShown
    }

    /// 唯一的【登录】按钮：identifier、读屏焦点绑定、状态与动作都在这里，原位与底栏只取其一渲染。
    var submitButton: some View {
        CouliButton(
            text(LoginKeys.submit),
            isLoading: model.submitting,
            isEnabled: model.canSubmit,
            fillsWidth: true,
            action: model.submit
        )
        .accessibilityFocused($submitFocused)
        .accessibilityIdentifier("login.submit")
    }

    /// 底栏：留白、限宽、底色照绑手机页 bottomBar（BindPhoneView.swift），按钮下沿与键盘顶留 s3（12pt）。
    var pinnedSubmitBar: some View {
        submitButton
            .padding(.horizontal, CouliSpacing.s4)
            .padding(.top, CouliSpacing.s3)
            .padding(.bottom, CouliSpacing.s3)
            .frame(maxWidth: Self.maxContentWidth)
            .frame(maxWidth: .infinity)
            .background(CouliColor.backgroundCanvas.ignoresSafeArea())
    }

    // MARK: - 弹窗

    var dialog: CouliDialog {
        switch model.dialog {
        case let .blocked(titleKey):
            CouliDialog(
                title: text(titleKey),
                message: text(LoginKeys.riskBlockedDesc),
                // 读屏「返回」手势等同【我知道了】，不走申诉 / 客服（FU-IOS-A11Y-01）
                onEscape: { model.dialog = nil },
                primary: CouliDialogAction(text(LoginKeys.riskBlockedOK)) { model.dialog = nil },
                secondary: CouliDialogAction(text(LoginKeys.appeal)) {
                    model.dialog = nil
                    model.config.onCustomerService()
                }
            )
        case let .oauthBlocked(titleKey):
            // 第三方登录 44001（共性第 5 条）：对应文案 + 统一客服出口的申诉入口；不套用短信注册的专用说明句
            CouliDialog(
                title: text(titleKey),
                onEscape: { model.dialog = nil },
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
                onEscape: { model.dialog = nil },
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
                // 读屏「返回」手势等同【取消】：不算同意、不发码
                onEscape: model.cancelAgreement,
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
