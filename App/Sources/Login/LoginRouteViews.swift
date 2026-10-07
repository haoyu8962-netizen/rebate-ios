import DesignSystem
import Login
import Router
import SwiftUI

/// 路由 Login（APP-05a）：登录页（Features/Login 的 LoginView）。`destination.fromForceUpdatePage` 是 APP-02c 已有的
/// 「从强更页进入」内部来源标记（routes.json 的 Login.params 没有这个参数，不进路由参数，rule-gaps ROUTE-01）。
/// 用自己的顶栏（关闭 / 返回），系统导航栏隐藏。
struct LoginRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var login: AppLogin

    var body: some View {
        LoginView(config: login.pageConfig(restricted: destination.fromForceUpdatePage))
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            .id(destination.id)
    }
}

/// 路由 Settings 的占位页（设置页本身在 APP-12）：APP-05a 只放【退出登录】入口（BR-TEXT-14 表 C settings.logout.*：
/// 只在已登录时显示，先出确认框，确认后退出 → 回到游客）。只读打开（基本模式等）时不显示。
struct SettingsPlaceholderView: View {
    let destination: RouteDestination
    @EnvironmentObject private var login: AppLogin
    @EnvironmentObject private var router: Router
    @State private var confirming = false
    @State private var busy = false
    @AccessibilityFocusState private var logoutFocused: Bool

    var body: some View {
        VStack(spacing: CouliSpacing.s4) {
            Text(verbatim: "Settings")
                .couliFont(.title)
                .foregroundColor(CouliColor.textPrimary)
                .accessibilityIdentifier("route.placeholder.name")
            Text(verbatim: destination.readonly ? "route placeholder (read-only)" : "route placeholder")
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
            if login.sessionVersion >= 0, login.loggedIn, !destination.readonly {
                CouliButton(
                    LoginDraftTexts.text("settings.logout"),
                    kind: .secondary,
                    isLoading: busy,
                    fillsWidth: true
                ) {
                    confirming = true
                }
                .accessibilityFocused($logoutFocused)
                .accessibilityIdentifier("settings.logout")
            }
        }
        .padding(CouliSpacing.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .couliDialog(isPresented: confirming, restoreFocusTo: $logoutFocused) {
            CouliDialog(
                title: LoginDraftTexts.text("settings.logout.confirm"),
                primary: CouliDialogAction(LoginDraftTexts.text("settings.logout.confirm_ok")) {
                    confirming = false
                    logout()
                },
                secondary: CouliDialogAction(LoginDraftTexts.text("settings.logout.confirm_cancel")) {
                    confirming = false
                }
            )
        }
    }

    private func logout() {
        busy = true
        Task { @MainActor in
            let done = await login.logout()
            busy = false
            if done {
                router.removeRoute("Settings")
            }
        }
    }
}

/// 登录成功后的邀请码未生效弹窗（LoginInviteFailed）：【知道了】/【去补填】（打开「我的」，补填页另有任务）。
@MainActor
enum InviteFailedDialog {
    static func make(_ login: AppLogin, bodyKey: String) -> CouliDialog {
        CouliDialog(
            title: LoginDraftTexts.text("login.invite_failed.title"),
            message: LoginDraftTexts.text(bodyKey),
            primary: CouliDialogAction(LoginDraftTexts.text("login.invite_failed.backfill")) {
                login.openInviteBackfill()
            },
            secondary: CouliDialogAction(LoginDraftTexts.text("login.invite_failed.ok")) {
                login.inviteFailedKey = nil
            }
        )
    }
}
