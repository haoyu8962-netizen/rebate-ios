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

/// 路由 BindPhone（APP-05b）：Features/Login 的绑手机页。一个导航实例一份执行器（AppLogin 按 RouteDestination.id 缓存，出栈、会话换代时
/// 在同步出口作废）。用自己的顶栏，系统导航栏隐藏。
struct BindPhoneRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var login: AppLogin

    var body: some View {
        BindPhoneScreen(entry: login.bindEntry(for: destination), texts: login.texts)
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            .debugRouteMarker(destination)
    }
}

/// 第三方新号的绑手机引导（LoginBindPhoneGuide；BR-INV-03 细则 ①）：标题、正文用契约 invite.bind_phone_guide.*；【暂不】/【去绑定】。
/// 点遮罩不关闭（按钮关闭）。首次购买前的提示句（body_before_buy）要识别购买类待办与已读状态，未做（rule-gaps 21 同口径，iOS I06）。
@MainActor
enum BindGuideDialog {
    static func make(_ login: AppLogin, guide: BindGuide) -> CouliDialog {
        CouliDialog(
            title: LoginDraftTexts.text("invite.bind_phone_guide.title"),
            message: LoginDraftTexts.text("invite.bind_phone_guide.body"),
            primary: CouliDialogAction(LoginDraftTexts.text("invite.bind_phone_guide.go")) {
                login.goBindPhone(guide.id)
            },
            secondary: CouliDialogAction(LoginDraftTexts.text("invite.bind_phone_guide.skip")) {
                login.skipBindGuide(guide.id)
            }
        )
    }
}
