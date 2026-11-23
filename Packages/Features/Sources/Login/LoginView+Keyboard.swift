import DesignSystem
import SwiftUI

/// 登录页键盘避让（FU-LOGIN-KEYBOARD-AVOID-ios r3，D10-2458；视觉验收 §2.4）：键盘弹起期间，当前步主按钮（手机号步
/// 【获取验证码】、验证码步【登录】）从滚动内容移到 ScrollView 的 safeAreaInset 底栏，钉在键盘上方；键盘收起回原位。
/// 页面不主动滚动，聚焦的输入框交给系统保持在收窄后的可视区内（AXXXL 下输入框到主按钮的距离超过键盘以上可视区，
/// 滚动方案会把输入框滚走，见 review-r1 S1-1）。读屏开启时不钉底，保持 A11yFocusLogin 读屏顺序（S2-2）。
extension LoginView {
    /// 主按钮此刻是否钉底。原位（`if !primaryPinned`）与底栏（`if primaryPinned`）互斥，同一时刻只渲染一个实例。
    /// 只在本步主输入框（手机号步 login.phone、验证码步 login.code）聚焦时钉；邀请码框等其他控件聚焦时不钉，
    /// 按钮留在原位，由系统保持聚焦框可见（review-r2 S2-2：邀请码框不在按需滚动的保护里）。
    var primaryPinned: Bool {
        keyboardShown && !voiceOverRunning && (model.step == .code ? codeFocused : phoneFocused)
    }

    /// 底栏：只在钉底时有内容；按当前步放唯一的那颗主按钮。
    @ViewBuilder var pinnedPrimaryBar: some View {
        if primaryPinned {
            Group {
                if model.step == .code {
                    submitButton.keyboardPinnedBar()
                } else {
                    getCodeButton.keyboardPinnedBar()
                }
            }
            .onPreferenceChange(KeyboardBarTopKey.self) { pinnedBarTop = $0 }
        }
    }

    // MARK: - 输入框按需滚动（r4）

    static let topAnchor = "login.content.keyboardTop"
    static let phoneAnchor = "login.phone.keyboardAnchor"
    static let codeAnchor = "login.code.keyboardAnchor"

    /// 当前步正在输入的框（手机号框 / 验证码格那一行）。
    var inputAnchor: String {
        model.step == .code ? Self.codeAnchor : Self.phoneAnchor
    }

    /// 只在钉底期间按需滚动（钉底已要求本步主输入框聚焦；邀请码框聚焦时不钉也不滚）。
    var inputScrollActive: Bool {
        primaryPinned
    }

    /// 唯一的【获取验证码】：identifier、读屏焦点绑定、状态与动作都在这里。发码 42901 限流期内置灰，文字换成还要等多久
    /// （D10-2767 ①，规则见 `sendWaitText`）；成功发码的倒计时不在这里显示（回到手机号步照常可点、进验证码步，共性 5）。
    var getCodeButton: some View {
        CouliButton(
            model.sendRateLimited ? sendWaitText(model.resendCountdown) : text(LoginKeys.getCode),
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
    }

    /// 唯一的【登录】：identifier、读屏焦点绑定、状态与动作都在这里。
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
}
