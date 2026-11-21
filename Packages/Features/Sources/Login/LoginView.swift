import DesignSystem
import SwiftUI
import UIKit

/// 短信登录页（Login / LoginAgreeConfirm / LoginCode / LoginCodeBlocked / LoginCodeInvite / LoginSessionExpired /
/// LoginDeletionProcessing 画板）。读屏顺序按 A11yFocusLogin：关闭 → 设置 → 标题 → 手机号（含 +86）→ 清除 → 协议复选框
/// （提示为自动注册说明）→《用户协议》→《隐私政策》→ 获取验证码 → 邀请码入口 → 其他登录方式 → 第三方按钮 → 登录遇到问题；
/// 品牌方块是装饰。进入页面焦点落在标题，不自动弹键盘。
public struct LoginView: View {
    @StateObject var model: LoginViewModel
    @AccessibilityFocusState var titleFocused: Bool
    @AccessibilityFocusState var getCodeFocused: Bool
    @AccessibilityFocusState var submitFocused: Bool
    @FocusState var codeFocused: Bool
    @FocusState var phoneFocused: Bool
    /// 软键盘是否弹起（keyboardWillShow / keyboardWillHide 维护）；验证码步据此把【登录】钉到键盘上方
    /// （FU-LOGIN-KEYBOARD-AVOID-ios r2）。
    @State var keyboardShown = false

    /// 内容列的最大宽度（大屏居中；手机宽度下不起作用）。
    static let maxContentWidth: CGFloat = 560

    public init(config: LoginPageConfig) {
        _model = StateObject(wrappedValue: LoginViewModel(config: config))
    }

    var restricted: Bool {
        model.config.restricted
    }

    func text(_ key: String) -> String {
        model.text(key)
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if model.step == .code {
                            codeStep
                        } else {
                            phoneStep
                        }
                    }
                    .padding(.horizontal, CouliSpacing.s4)
                    .padding(.bottom, CouliSpacing.s6)
                    // 共性 17：大屏（宽度 ≥ 600pt）上内容限宽并水平居中（03 §10.4）。
                    .frame(maxWidth: Self.maxContentWidth)
                    .frame(maxWidth: .infinity)
                }
                // FU-LOGIN-KEYBOARD-AVOID-ios（D10-2458）：手机号步聚焦手机号框、键盘弹起后把【获取验证码】滚进键盘以上
                .keyboardPrimaryScroll(proxy, target: keyboardTarget, trigger: keyboardTrigger)
                // 验证码步键盘弹起期间【登录】钉在键盘上方（照绑手机页底栏）；不钉时底栏为空、不占高度
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if submitPinned {
                        pinnedSubmitBar
                    }
                }
            }
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .couliDialog(
            isPresented: model.dialog != nil,
            restoreFocusTo: model.step == .code ? $submitFocused : $getCodeFocused
        ) {
            dialog
        }
        .couliToast($model.toast)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardShown = false
        }
        .onAppear {
            model.appeared()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                titleFocused = true
            }
        }
        .onDisappear {
            model.disappeared()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("login.page")
    }

    // MARK: - 键盘避让（FU-LOGIN-KEYBOARD-AVOID-ios，D10-2458）

    static let getCodeAnchor = "login.getCode.keyboardAnchor"

    /// 只在手机号步、手机号框聚焦时滚；邀请码框聚焦时不动（邀请码在主按钮下方，滚了反而盖住它）。验证码步不滚：
    /// AXXXL 下验证码格到【登录】约 650–800pt，超过键盘以上可视区，改为钉底（r2）。
    var keyboardTarget: String? {
        model.step == .phone && phoneFocused ? Self.getCodeAnchor : nil
    }

    /// 焦点或输入变化时重滚（输入途中系统把输入框滚回可视区后，主按钮仍回到键盘以上）。
    var keyboardTrigger: [String] {
        [model.step == .code ? "code" : "phone", String(phoneFocused), model.phoneText]
    }

    // MARK: - 顶栏

    var topBar: some View {
        HStack {
            Button(action: model.closeOrBack) {
                CouliIconView(model.step == .code ? .back : .close)
                    .foregroundColor(CouliColor.textPrimary)
                    .couliHitTarget()
            }
            .buttonStyle(CouliPlainButtonStyle())
            .accessibilityLabel(Text(verbatim: text(model.step == .code ? LoginKeys.back : LoginKeys.close)))
            .accessibilityIdentifier("login.close")
            Spacer()
            if !restricted {
                Button(action: model.config.onSettings) {
                    Text(verbatim: text(LoginKeys.settings))
                        .couliFont(.body, weight: .couliMedium)
                        .foregroundColor(CouliColor.brandEmphasis)
                        .couliHitTarget()
                }
                .buttonStyle(CouliPlainButtonStyle())
                .accessibilityIdentifier("login.settings")
            }
        }
        .padding(.leading, CouliSpacing.s2)
        .padding(.trailing, CouliSpacing.s3)
        .loginTopBarChrome()
    }

    // MARK: - 手机号步

    var phoneStep: some View {
        VStack(spacing: CouliSpacing.s5) {
            VStack(spacing: CouliSpacing.s4) {
                BrandMark(text: text(LoginKeys.brand))
                Text(verbatim: text(LoginKeys.title))
                    .couliFont(.heading, weight: .couliBold)
                    .foregroundColor(CouliColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                    .accessibilityIdentifier("login.title")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, CouliSpacing.s4)
            phoneField
            agreementRow
            CouliButton(
                text(LoginKeys.getCode),
                isLoading: model.sending,
                isEnabled: !model.sendRateLimited,
                fillsWidth: true,
                action: {
                    // 收起键盘再弹确认框 / 进验证码步（LoginAgreeConfirm 画板无键盘）。
                    phoneFocused = false
                    model.requestCode()
                }
            )
            .accessibilityFocused($getCodeFocused)
            .accessibilityIdentifier("login.getCode")
            .keyboardPrimaryAnchor(Self.getCodeAnchor)
            if model.canContinueCode {
                // 共性 16：「继续输入验证码」独立入口，不以能否重发为条件。
                textButton(LoginKeys.codeContinue, id: "login.continueCode", action: model.continueCode)
            }
            if !restricted {
                if model.inviteOpen {
                    inviteField
                } else {
                    textButton(LoginKeys.inviteEntry, id: "login.inviteEntry") { model.inviteOpen = true }
                }
            }
            Spacer(minLength: CouliSpacing.s8)
            if !model.providers.isEmpty {
                ThirdPartyArea(model: model)
            }
            helpEntry
        }
    }

    @ViewBuilder var helpEntry: some View {
        if !restricted {
            textButton(LoginKeys.help, id: "login.help", action: model.config.onHelp)
        }
    }

    func textButton(_ key: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: text(key))
                .couliFont(.body, weight: .couliMedium)
                .foregroundColor(CouliColor.brandEmphasis)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, CouliSpacing.s2)
                .couliHitTarget()
        }
        .buttonStyle(CouliPlainButtonStyle())
        .accessibilityIdentifier(id)
    }
}
