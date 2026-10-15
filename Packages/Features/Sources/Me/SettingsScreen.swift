import CouliNetwork
import DesignSystem
import MeCore
import SwiftUI

/// 设置页的按钮回调（渲染时一次取出：执行器与版本是不可变的普通值，APP-09 共性第 4、63 条）。
@MainActor
public struct SettingsActions {
    public let row: (SettingsRow) -> Void
    public let agreement: (SettingsChoice, Int) -> Void
    public let closeSheet: (Int) -> Void
    public let askLogout: () -> Void
    public let confirmLogout: (MeDialog) -> Void
    public let confirmClear: (MeDialog) -> Void
    public let cancelDialog: (MeDialog) -> Void
    public let login: () -> Void
    public let enableFull: () -> Void
    public let retryMe: () -> Void
    public let closeSub: () -> Void

    public static func make(_ controller: SettingsController, _ state: SettingsState) -> SettingsActions {
        let version = state.version
        return SettingsActions(
            row: { [weak controller] row in controller?.onRow(row, version: version) },
            agreement: { [weak controller] choice, sheet in controller?.openAgreement(
                choice,
                version: version,
                sheet: sheet
            ) },
            closeSheet: { [weak controller] sheet in controller?.closeSheet(sheet) },
            askLogout: { [weak controller] in controller?.askLogout(version: version) },
            confirmLogout: { [weak controller] dialog in controller?.confirmLogout(dialog, version: version) },
            confirmClear: { [weak controller] dialog in controller?.confirmClear(dialog, version: version) },
            cancelDialog: { [weak controller] dialog in controller?.closeDialog(dialog) },
            login: { [weak controller] in controller?.openLogin(version: version) },
            enableFull: { [weak controller] in controller?.enableFull(version: version) },
            retryMe: { [weak controller] in controller?.retryMe() },
            closeSub: { [weak controller] in controller?.closeSub() }
        )
    }
}

/// 设置（Settings 路由；设计稿
/// Settings、SettingsGuest、SettingsAgreementSheet、SettingsClearCache、SettingsCacheCleared、SettingsLogoutConfirm；
/// 基本模式五项）。修改昵称、通知设置是页内子页（G32）：同一个导航实例里切换视图，返回先关子页。身份变了 App 换上新执行器，整页按新身份重建
/// （旧确认框、半屏、子页随旧执行器消失）。
public struct SettingsScreen: View {
    @ObservedObject var host: MePageHost<SettingsController>

    public init(host: MePageHost<SettingsController>) {
        self.host = host
    }

    public var body: some View {
        SettingsBody(controller: host.controller, repo: host.controller.deps.repo,
                     withdraw: host.controller.deps.withdraw)
            .id(host.serial)
            .onAppear { host.onAppear() }
    }
}

struct SettingsBody: View {
    @ObservedObject var controller: SettingsController
    @ObservedObject var repo: MeRepository
    @ObservedObject var withdraw: MeWithdrawState
    @AccessibilityFocusState private var logoutFocused: Bool
    @AccessibilityFocusState private var clearFocused: Bool
    @AccessibilityFocusState private var agreementFocused: Bool

    var texts: MeTexts {
        controller.deps.texts
    }

    var body: some View {
        let state = controller.state
        let actions = SettingsActions.make(controller, state)
        Group {
            switch state.sub {
            case .nickname:
                if let nickname = controller.nickname {
                    NicknameView(controller: nickname, gate: nickname.gate)
                        .meNavigation(texts.text("nickname.title"))
                        .meSubpageBack(texts.text("me.back"), action: actions.closeSub)
                }
            case .notify:
                if let notify = controller.notify {
                    NotifySettingsView(controller: notify, gate: notify.gate)
                        .meNavigation(texts.text("notify.title"))
                        .meSubpageBack(texts.text("me.back"), action: actions.closeSub)
                }
            case .none:
                main(state, actions)
                    .meNavigation(texts.text("settings.title"))
                    .navigationBarBackButtonHidden(state.dialog != nil || state.sheet != nil)
            }
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .meToast(state.toast, texts: texts) { controller.consumeToast($0) }
    }

    private func main(_ state: SettingsState, _ actions: SettingsActions) -> some View {
        list(controller.model(), actions)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.page")
            .couliSheet(
                isPresented: state.sheet != nil,
                dismissOnScrim: { state.sheet.map(actions.closeSheet) },
                restoreFocusTo: $agreementFocused,
                sheet: { agreementSheet(state.sheet ?? 0, actions) }
            )
            .couliDialog(isPresented: state.dialog?.kind == SettingsState.logoutDialog,
                         restoreFocusTo: $logoutFocused) {
                logoutDialog(state.dialog ?? MeDialog(kind: "", id: 0), actions)
            }
            .couliDialog(isPresented: state.dialog?.kind == SettingsState.clearDialog, restoreFocusTo: $clearFocused) {
                clearDialog(state.dialog ?? MeDialog(kind: "", id: 0), actions)
            }
            .disabled(withdraw.busy)
    }

    private func list(_ model: SettingsModel, _ actions: SettingsActions) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CouliSpacing.s4) {
                if controller.identity.member {
                    accountNotice(actions)
                }
                ForEach(Array(model.groups.enumerated()), id: \.offset) { _, group in
                    groupView(group, actions)
                }
                footer(model.footer, actions)
            }
            .padding(CouliSpacing.s4)
            .meContentWidth()
        }
    }

    private func groupView(_ group: SettingsGroup, _ actions: SettingsActions) -> some View {
        MeGroup(title: MeDraftTexts.settingsKey(group.name).map(texts.text)) {
            ForEach(Array(group.rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Divider().padding(.leading, CouliSpacing.s4)
                }
                settingsRow(row, actions)
            }
        }
    }

    private func logoutDialog(_ dialog: MeDialog, _ actions: SettingsActions) -> CouliDialog {
        CouliDialog(
            title: texts.text("settings.logout.confirm"),
            primary: CouliDialogAction(texts.text("settings.logout.confirm_ok")) { actions.confirmLogout(dialog) },
            secondary: CouliDialogAction(texts.text("settings.logout.confirm_cancel")) { actions.cancelDialog(dialog) }
        )
    }

    private func clearDialog(_ dialog: MeDialog, _ actions: SettingsActions) -> CouliDialog {
        CouliDialog(
            title: texts.text("settings.clear_cache"), message: texts.text("settings.clear_cache.confirm"),
            primary: CouliDialogAction(texts.text("settings.clear_cache.confirm_ok")) { actions.confirmClear(dialog) },
            secondary: CouliDialogAction(texts.text("settings.clear_cache.confirm_cancel")) {
                actions.cancelDialog(dialog)
            }
        )
    }

    /// 已登录时账号资料（昵称、手机号行）的读取提示与【重试】（R1-05）：没有快照时的加载失败、已有快照时本页刷新失败都呈现（统一错误文案 +
    /// trace6）；【重试】按执行器发布的读取闸门状态置灰（R1-06：禁用期开始、结束都重绘），执行层另拦。
    @ViewBuilder
    private func accountNotice(_ actions: SettingsActions) -> some View {
        if let notice = controller.accountNotice(repo.state) {
            MeNoticeBar(
                text: notice.message(texts), noticeId: notice.notice.id, retryTitle: texts.text("me.retry"),
                retryEnabled: !controller.readBlocked, retry: actions.retryMe,
                identifier: notice.refreshFailed ? "settings.meRefreshError" : "settings.meError"
            )
        }
    }

    @ViewBuilder
    private func settingsRow(_ row: SettingsRow, _ actions: SettingsActions) -> some View {
        let key = MeDraftTexts.settingsKey(row.id) ?? ""
        let identifier = "settings.row." + key.replacingOccurrences(of: "settings.", with: "")
            .replacingOccurrences(of: "me.grid.", with: "")
        let title = texts.text(key)
        let me = repo.me(of: controller.identity)
        switch row.id {
        case SettingsItems.idNickname:
            MeRow(title: title, value: me?.nickname ?? "", clickable: row.clickable, identifier: identifier) {
                actions.row(row)
            }
        case SettingsItems.idPhone:
            let value = me.map { texts.text($0.phoneBound ? "settings.phone.bound" : "settings.phone.unbound") } ?? ""
            MeRow(title: title, value: value, clickable: row.clickable, identifier: identifier) { actions.row(row) }
        case SettingsItems.idClearCache:
            let size = controller.state.cacheBytes.map(CacheSize.text) ?? texts.text("settings.clear_cache.unknown")
            MeRow(title: title, value: size, identifier: identifier) { actions.row(row) }
                .accessibilityFocused($clearFocused)
        case SettingsItems.idAgreement:
            MeRow(title: title, identifier: identifier) { actions.row(row) }
                .accessibilityFocused($agreementFocused)
        case SettingsItems.idResetTip:
            // R1-06：按 resetTip 闸门置灰（执行器发布禁用期开始 / 结束），执行层另拦
            MeRow(
                title: title, clickable: row.clickable, enabled: !controller.resetTipBlocked, identifier: identifier
            ) { actions.row(row) }
        default:
            MeRow(title: title, clickable: row.clickable, identifier: identifier) { actions.row(row) }
        }
    }

    @ViewBuilder
    private func footer(_ footer: String, _ actions: SettingsActions) -> some View {
        switch footer {
        case SettingsItems.footerEnableFull:
            CouliButton(texts.text("privacy.basic_mode.enable"), fillsWidth: true, action: actions.enableFull)
                .accessibilityIdentifier("settings.enableFull")
        case SettingsItems.footerLogin:
            VStack(spacing: CouliSpacing.s3) {
                Text(verbatim: texts.text("settings.guest_footer"))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                CouliButton(texts.text("settings.go_login"), fillsWidth: true, action: actions.login)
                    .accessibilityIdentifier("settings.login")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.guestFooter")
        default:
            CouliButton(
                texts.text("settings.logout"), kind: .secondary, isLoading: controller.state.busy, fillsWidth: true,
                action: actions.askLogout
            )
            .accessibilityFocused($logoutFocused)
            .accessibilityIdentifier("settings.logout")
        }
    }

    private func agreementSheet(_ sheet: Int, _ actions: SettingsActions) -> some View {
        let choices = SettingsItems.model(
            level: MeLevel.guest, platform: MePlatform.ios, phoneBound: nil, nicknameEditable: false,
            serviceSwitchAvailable: false, deleteAccountAvailable: false
        ).groups.flatMap(\.rows).first { $0.id == SettingsItems.idAgreement }?.choices ?? []
        return CouliSheet(
            title: texts.text("settings.agreement"), closeLabel: texts.text("me.close"),
            onClose: { actions.closeSheet(sheet) },
            content: { EmptyView() },
            actions: {
                ForEach(choices, id: \.type) { choice in
                    CouliButton(
                        texts
                            .text(choice
                                .type == "agreement" ? "settings.agreement.user" : "settings.agreement.privacy"),
                        kind: .secondary, fillsWidth: true
                    ) { actions.agreement(choice, sheet) }
                        .accessibilityIdentifier("settings.agreement." + choice.type)
                }
            }
        )
        .accessibilityIdentifier("settings.agreementSheet")
    }
}

extension View {
    /// 页内子页的返回（关子页，不出栈）：隐藏系统返回，左上放同样的返回按钮；侧滑返回随系统返回一起被禁用（不会把整个设置页带走）。
    func meSubpageBack(_ label: String, action: @escaping () -> Void) -> some View {
        navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: action) {
                        CouliIconView(.back)
                            .foregroundColor(CouliColor.textPrimary)
                            .couliHitTarget()
                    }
                    .accessibilityLabel(Text(verbatim: label))
                    .accessibilityIdentifier("me.subpage.back")
                }
            }
    }
}
