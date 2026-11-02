import DesignSystem
import MeCore
import SwiftUI

/// 隐私中心的按钮回调（渲染时取出执行器与版本，共性第 6、63 条）。
@MainActor
public struct PrivacyCenterActions {
    public let document: (String) -> Void
    public let permission: (String) -> Void
    public let personalization: (Bool) -> Void
    public let askWithdraw: () -> Void
    public let confirmWithdraw: (MeDialog) -> Void
    public let cancelWithdraw: (MeDialog) -> Void
    public let enableFull: () -> Void

    public static func make(_ controller: PrivacyCenterController,
                            _ state: PrivacyCenterState) -> PrivacyCenterActions {
        let version = state.version
        return PrivacyCenterActions(
            document: { [weak controller] type in controller?.openDocument(type, version: version) },
            permission: { [weak controller] type in controller?.openPermission(type, version: version) },
            personalization: { [weak controller] on in controller?.setPersonalization(on, version: version) },
            askWithdraw: { [weak controller] in controller?.askWithdraw(version: version) },
            confirmWithdraw: { [weak controller] dialog in controller?.confirmWithdraw(dialog) },
            cancelWithdraw: { [weak controller] dialog in controller?.cancelWithdraw(dialog) },
            enableFull: { [weak controller] in controller?.enableFull(version: version) }
        )
    }
}

/// 隐私中心（PrivacyCenter 路由；设计稿 PrivacyCenter、PrivacyCenterBasic、PrivacyCenterWithdraw）：两份清单、隐私政策、用户协议；个性化推荐开关；
/// 「系统权限」一节；撤回同意说明 +【撤回同意】。基本模式只读并在原位显示【开启完整功能】。撤回确认框【取消】是主按钮、【确认撤回】是次按钮，
/// 点遮罩不撤回，确认框显示期间系统返回（侧滑）被禁用。
public struct PrivacyCenterScreen: View {
    @ObservedObject var host: MePageHost<PrivacyCenterController>

    public init(host: MePageHost<PrivacyCenterController>) {
        self.host = host
    }

    public var body: some View {
        PrivacyCenterBody(controller: host.controller, withdraw: host.controller.deps.withdraw)
            .id(host.serial)
            .onAppear { host.onAppear() }
    }
}

struct PrivacyCenterBody: View {
    @ObservedObject var controller: PrivacyCenterController
    @ObservedObject var withdraw: MeWithdrawState
    @AccessibilityFocusState private var withdrawFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var texts: MeTexts {
        controller.deps.texts
    }

    var body: some View {
        let state = controller.state
        let actions = PrivacyCenterActions.make(controller, state)
        scroll(controller.model(), state, actions)
            .background(CouliColor.backgroundCanvas.ignoresSafeArea())
            .meNavigation(texts.text("privacy_center.title"))
            .navigationBarBackButtonHidden(state.dialog != nil || withdraw.busy)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("privacy.page")
            .couliDialog(isPresented: state.dialog != nil, restoreFocusTo: $withdrawFocused) {
                withdrawDialog(state.dialog ?? MeDialog(kind: "", id: 0), actions)
            }
            .meToast(state.toast, texts: texts) { controller.consumeToast($0) }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    controller.refresh()
                }
            }
    }

    /// BR-TEXT-14 表 D：【取消】是主按钮，【确认撤回】是次按钮。
    private func withdrawDialog(_ dialog: MeDialog, _ actions: PrivacyCenterActions) -> CouliDialog {
        CouliDialog(
            title: texts.text("privacy.withdraw.confirm.title"), message: texts.text("privacy.withdraw.confirm.body"),
            centeredTitle: true, probeID: "privacy.dialog.withdraw",
            primary: CouliDialogAction(texts.text("privacy.withdraw.confirm.cancel")) { actions.cancelWithdraw(dialog)
            },
            secondary: CouliDialogAction(texts.text("privacy.withdraw.confirm.ok")) { actions.confirmWithdraw(dialog) }
        )
    }

    /// 画板：内容上 8、左右 16、底 16，块间 12（「系统权限」分节头上另有 8）。
    private func scroll(_ model: PrivacyCenterModel, _ state: PrivacyCenterState,
                        _ actions: PrivacyCenterActions) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                sections(model, state, actions)
            }
            .padding(.horizontal, CouliSpacing.s4)
            .padding(.top, CouliSpacing.s2)
            .padding(.bottom, CouliSpacing.s4)
            .meContentWidth()
        }
    }

    @ViewBuilder
    private func sections(_ model: PrivacyCenterModel, _ state: PrivacyCenterState,
                          _ actions: PrivacyCenterActions) -> some View {
        if model.enableFullButton {
            basicNotice
        }
        documents(actions)
        if model.personalizationSwitch {
            MeGroup(style: .settings, probe: "privacy.personalization.card") {
                MeSwitchRow(
                    title: texts.text("privacy_center.personalization"),
                    subtitle: texts.text("privacy_center.personalization_desc"), isOn: state.personalizationOn,
                    enabled: !withdraw.busy, texts: texts, identifier: "privacy.personalization", style: .settings,
                    probe: "privacy.personalization", controlProbe: "privacy.personalization.control",
                    settingsVerticalPadding: CouliSpacing.s3, settingsTextSpacing: CouliSpacing.s1,
                    onChange: actions.personalization
                )
            }
        }
        if model.permissionSection {
            permissions(model, state, actions)
        }
        if model.withdrawButton {
            withdrawSection(actions)
        }
        if model.enableFullButton {
            enableFullSection(actions)
        }
    }

    private var basicNotice: some View {
        SettingsNoticeBar(
            icon: .info, iconColor: CouliColor.textSecondary, background: CouliColor.backgroundMuted,
            probe: "privacy.basic.notice"
        ) {
            MeText(texts.text("privacy.basic_mode.notice"), style: .footnote, probe: "privacy.basic.notice.text")
                .foregroundColor(CouliColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("privacy.basicNotice")
    }

    private func documents(_ actions: PrivacyCenterActions) -> some View {
        // H03：收集清单 → Agreement {type: privacy}，共享清单 → {type: sdk_list}
        let rows = [
            DocumentRow(key: "privacy_center.collect_list", type: "privacy", id: "privacy.list.collect"),
            DocumentRow(key: "privacy_center.share_list", type: "sdk_list", id: "privacy.list.share"),
            DocumentRow(key: "privacy_center.privacy_policy", type: "privacy", id: "privacy.policy"),
            DocumentRow(key: "privacy_center.agreement", type: "agreement", id: "privacy.agreement"),
        ]
        return MeGroup(style: .settings, probe: "privacy.docs") {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    SettingsDivider(probe: "privacy.docs.divider.\(index - 1)")
                }
                // 隐私中心列表行是 border-box：节距 44，不是设置页的 52
                MeRow(title: texts.text(row.key), clickable: !withdraw.busy, identifier: row.id, style: .settings,
                      settingsMinHeight: CouliHitTarget.minimum, probe: row.probe) {
                    actions.document(row.type)
                }
            }
        }
    }

    private func permissions(_ model: PrivacyCenterModel, _ state: PrivacyCenterState,
                             _ actions: PrivacyCenterActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                MeText(texts.text("privacy.system_permissions.title"), style: .footnote, weight: .couliSemibold,
                       probe: "privacy.permissions.title")
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                MeText(texts.text("privacy.system_permissions.hint"), style: .caption,
                       probe: "privacy.permissions.hint")
                    .foregroundColor(CouliColor.textSecondary)
            }
            .padding(.horizontal, CouliSpacing.s1)
            if !model.permissionRows.isEmpty {
                VStack(spacing: 0) {
                    // 只调显示顺序：契约是相册在前，画板通知在前；哪几行由模型定
                    let rows = model.permissionRows.filter { $0.type == "push" }
                        + model.permissionRows.filter { $0.type != "push" }
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            SettingsDivider(probe: "privacy.permissions.divider.\(index - 1)")
                        }
                        // G-P16：push 用途是画板短句（草稿，W-06 回写前），其余沿用契约 purpose_key
                        PrivacyPermissionRow(
                            type: row.type, name: texts.text("privacy_center.permission." + row.type),
                            purpose: (row.type == "push" ? "privacy.system_permissions.purpose.push" : row.purposeKey)
                                .map(texts.text),
                            status: state.permissionStatus[row.type] == nil ? nil : texts.text(row.statusKey),
                            clickable: !withdraw.busy
                        ) {
                            actions.permission(row.type)
                        }
                    }
                }
                .padding(.horizontal, CouliSpacing.s4)
                .couliCard(padding: 0)
                .meProbe("privacy.permissions.card", role: "card")
            }
        }
        .padding(.top, CouliSpacing.s2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("privacy.permissions")
    }

    private func withdrawSection(_ actions: PrivacyCenterActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                MeText(texts.text("privacy_center.withdraw_title"), style: .body, weight: .couliSemibold,
                       probe: "privacy.withdraw.title")
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                MeText(texts.text("privacy_center.withdraw_desc"), style: .footnote, probe: "privacy.withdraw.desc")
                    .foregroundColor(CouliColor.textSecondary)
            }
            CouliButton(
                texts.text("privacy_center.withdraw"), kind: .secondary, isLoading: withdraw.busy,
                isEnabled: !withdraw.busy, fillsWidth: true, weight: .couliMedium, action: actions.askWithdraw
            )
            .meProbe("privacy.withdraw.button", role: "button")
            .accessibilityFocused($withdrawFocused)
            .accessibilityIdentifier("privacy.withdraw")
        }
        .couliCard()
        .meProbe("privacy.withdraw.card", role: "card")
    }

    /// G-P08：卡内只有标题和按钮，不再显示副句（草稿键保留）。
    private func enableFullSection(_ actions: PrivacyCenterActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            MeText(texts.text("privacy_center.basic_title"), style: .body, weight: .couliSemibold,
                   probe: "privacy.basic.title")
                .foregroundColor(CouliColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            CouliButton(texts.text("privacy.basic_mode.enable"), fillsWidth: true, action: actions.enableFull)
                .meProbe("privacy.enableFull.button", role: "button")
                .accessibilityIdentifier("privacy.enableFull")
        }
        .couliCard()
        .meProbe("privacy.basic.card", role: "card")
    }
}

/// 清单与协议的一行（文案键、Agreement 的 type、标识）。
private struct DocumentRow {
    let key: String
    let type: String
    let id: String

    /// 测量编号：`privacy.row.<标识末段>`（collect、share、policy、agreement）。
    var probe: String {
        "privacy.row." + (id.components(separatedBy: ".").last ?? id)
    }
}
