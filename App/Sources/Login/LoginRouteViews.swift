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
