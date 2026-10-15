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
            primary: CouliDialogAction(texts.text("privacy.withdraw.confirm.cancel")) { actions.cancelWithdraw(dialog)
            },
            secondary: CouliDialogAction(texts.text("privacy.withdraw.confirm.ok")) { actions.confirmWithdraw(dialog) }
        )
    }

    private func scroll(_ model: PrivacyCenterModel, _ state: PrivacyCenterState,
                        _ actions: PrivacyCenterActions) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CouliSpacing.s4) {
                sections(model, state, actions)
            }
            .padding(CouliSpacing.s4)
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
            MeGroup {
                MeSwitchRow(
                    title: texts.text("privacy_center.personalization"),
                    subtitle: texts.text("privacy_center.personalization_desc"), isOn: state.personalizationOn,
                    enabled: !withdraw.busy, texts: texts, identifier: "privacy.personalization",
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
        Text(verbatim: texts.text("privacy.basic_mode.notice"))
            .couliFont(.footnote)
            .foregroundColor(CouliColor.statusWarningText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(CouliSpacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                    .fill(CouliColor.statusWarningText.opacity(0.1))
            )
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
        return MeGroup {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Divider().padding(.leading, CouliSpacing.s4)
                }
                MeRow(title: texts.text(row.key), clickable: !withdraw.busy, identifier: row.id) {
                    actions.document(row.type)
                }
            }
        }
    }

    private func permissions(_ model: PrivacyCenterModel, _ state: PrivacyCenterState,
                             _ actions: PrivacyCenterActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            Text(verbatim: texts.text("privacy.system_permissions.title"))
                .couliFont(.footnote, weight: .couliSemibold)
                .foregroundColor(CouliColor.textSecondary)
                .padding(.horizontal, CouliSpacing.s1)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: texts.text("privacy.system_permissions.hint"))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, CouliSpacing.s1)
            if !model.permissionRows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(model.permissionRows.enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            Divider().padding(.leading, CouliSpacing.s4)
                        }
                        MeRow(
                            title: texts.text("privacy_center.permission." + row.type),
                            value: state.permissionStatus[row.type] == nil ? nil : texts.text(row.statusKey),
                            subtitle: row.purposeKey.map(texts.text), clickable: !withdraw.busy,
                            identifier: "privacy.permission." + row.type
                        ) {
                            actions.permission(row.type)
                        }
                    }
                }
                .couliCard(padding: 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("privacy.permissions")
    }

    private func withdrawSection(_ actions: PrivacyCenterActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            Text(verbatim: texts.text("privacy_center.withdraw_title"))
                .couliFont(.body, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: texts.text("privacy_center.withdraw_desc"))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            CouliButton(
                texts.text("privacy_center.withdraw"), kind: .secondary, isLoading: withdraw.busy,
                isEnabled: !withdraw.busy, fillsWidth: true, action: actions.askWithdraw
            )
            .accessibilityFocused($withdrawFocused)
            .accessibilityIdentifier("privacy.withdraw")
        }
        .couliCard()
    }

    private func enableFullSection(_ actions: PrivacyCenterActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            Text(verbatim: texts.text("privacy_center.basic_title"))
                .couliFont(.body, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
            Text(verbatim: texts.text("privacy_center.basic_desc"))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            CouliButton(texts.text("privacy.basic_mode.enable"), fillsWidth: true, action: actions.enableFull)
                .accessibilityIdentifier("privacy.enableFull")
        }
        .couliCard()
    }
}

/// 清单与协议的一行（文案键、Agreement 的 type、标识）。
private struct DocumentRow {
    let key: String
    let type: String
    let id: String
}
