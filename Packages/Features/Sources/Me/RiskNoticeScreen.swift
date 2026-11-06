import CouliNetwork
import DesignSystem
import MeCore
import SwiftUI
import WalletCore

/// 封禁 / 冻结说明的按钮回调（渲染时取出执行器与版本）。
@MainActor
public struct RiskNoticeActions {
    public let primary: () -> Void
    public let retry: () -> Void
    public let retryAppeals: () -> Void
    public let retryWithdrawals: () -> Void
    public let contactCs: () -> Void
    public let askLogout: () -> Void
    public let confirmLogout: (Int) -> Void
    public let cancelLogout: (Int) -> Void

    public static func make(_ controller: RiskNoticeController, _ state: RiskState) -> RiskNoticeActions {
        let version = state.version
        return RiskNoticeActions(
            primary: { [weak controller] in controller?.primary(version: version) },
            retry: { [weak controller] in controller?.load() },
            retryAppeals: { [weak controller] in controller?.retryAppeals() },
            retryWithdrawals: { [weak controller] in controller?.retryWithdrawals() },
            contactCs: { [weak controller] in controller?.contactCs() },
            askLogout: { [weak controller] in controller?.askLogout() },
            confirmLogout: { [weak controller] dialog in controller?.confirmLogout(dialog) },
            cancelLogout: { [weak controller] dialog in controller?.cancelLogout(dialog) }
        )
    }
}

/// 封禁 / 冻结说明（RiskNotice 路由；设计稿 RiskNoticeBanned、RiskNoticeBannedAppealing、RiskNoticeBannedUpheld、RiskNoticeFrozen、
/// RiskNoticeFrozenAppealing；WalletRiskFrozen 的落点）。banned 版式没有返回（系统返回与侧滑都关掉），底部「联系客服 | 退出登录」（注销按 G30
/// 不显示）；frozen 有返回。不显示任何处理时限；原因只显示类别文案（表外不显示原因行）。
public struct RiskNoticeScreen: View {
    @ObservedObject var controller: RiskNoticeController
    @ObservedObject var readGate: RetryAfterGate
    @AccessibilityFocusState private var logoutFocused: Bool

    public init(controller: RiskNoticeController) {
        self.controller = controller
        readGate = controller.readGate
    }

    var texts: MeTexts {
        controller.deps.texts
    }

    public var body: some View {
        let state = controller.state
        let actions = RiskNoticeActions.make(controller, state)
        let model = controller.model()
        let showBack = controller.showsBack
        Group {
            switch state.phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(Text(verbatim: texts.text("me.loading")))
                    .accessibilityIdentifier("risk.loading")
            case .error:
                VStack(spacing: CouliSpacing.s4) {
                    ErrorState(
                        title: texts.text("me.load_failed"), message: state.error?.message(texts),
                        retryTitle: texts.text("me.retry"), retry: actions.retry
                    )
                    .disabled(readGate.blocked)
                    .accessibilityIdentifier("risk.error")
                    // 读取失败时联系客服与退出登录始终可用（brief §2.10）
                    footer(actions)
                }
                .padding(CouliSpacing.s4)
            case .content:
                if let model {
                    content(model, state, actions)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .meNavigation(texts.text("risk.title"))
        .navigationBarBackButtonHidden(!showBack || state.logoutDialog != nil)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("risk.page")
        .couliDialog(isPresented: state.logoutDialog != nil, restoreFocusTo: $logoutFocused) {
            let dialog = state.logoutDialog ?? 0
            return CouliDialog(
                title: texts.text("settings.logout.confirm"),
                primary: CouliDialogAction(texts.text("settings.logout.confirm_ok")) { actions.confirmLogout(dialog) },
                secondary: CouliDialogAction(texts.text("settings.logout.confirm_cancel")) {
                    actions.cancelLogout(dialog)
                }
            )
        }
        .task { controller.load() }
    }

    private func content(_ model: RiskNoticeModel, _ state: RiskState, _ actions: RiskNoticeActions) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CouliSpacing.s4) {
                if let error = state.refreshError {
                    MeNoticeBar(
                        text: texts.text("risk.refresh_failed") + error.message(texts), noticeId: error.id,
                        retryTitle: texts.text("me.retry"), retryEnabled: !readGate.blocked, retry: actions.retry,
                        identifier: "risk.refreshError"
                    )
                }
                if model.layoutRaw == RiskLayout.normal {
                    normal(actions)
                } else {
                    header(model)
                    details(model)
                    withdrawals(state, actions)
                    upheld(model, state, actions)
                    note(model)
                    CouliButton(
                        texts
                            .text(model.primaryRaw == RiskNoticeView
                                .viewProgress ? "risk.view_progress" : "risk.submit"),
                        fillsWidth: true, action: actions.primary
                    )
                    .accessibilityIdentifier("risk.primary")
                    if !model.footer.isEmpty {
                        footer(actions)
                    }
                }
            }
            .padding(CouliSpacing.s4)
            .meContentWidth()
        }
        .accessibilityIdentifier("risk.content." + model.layoutRaw)
    }

    private func normal(_ actions: RiskNoticeActions) -> some View {
        VStack(spacing: CouliSpacing.s4) {
            Text(verbatim: texts.text("risk.normal.title"))
                .couliFont(.title, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .accessibilityIdentifier("risk.title")
            CouliButton(texts.text("risk.normal.back_home"), fillsWidth: true, action: actions.primary)
                .accessibilityIdentifier("risk.primary")
        }
        .frame(maxWidth: .infinity)
        .couliCard()
    }

    private func header(_ model: RiskNoticeModel) -> some View {
        let frozen = RiskLayout.isFrozen(model.layoutRaw)
        return VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            CouliIconView(.alert, size: CouliComponentMetric.iconMedium + CouliSpacing.s3)
                .foregroundColor(CouliColor.statusWarningText)
                .accessibilityHidden(true)
            Text(verbatim: texts.text(frozen ? "risk.frozen.title" : "risk.banned.title"))
                .couliFont(.title, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("risk.title")
            Text(verbatim: texts.text(frozen ? "risk.frozen.desc" : "risk.banned.desc"))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func details(_ model: RiskNoticeModel) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            // G08：表外与 null 不显示原因行
            if let reason = model.reasonKey {
                MeInfoRow(label: texts.text("risk.reason"), value: texts.text(reason), identifier: "risk.reason")
            }
            if RiskLayout.isBanned(model.layoutRaw) {
                MeInfoRow(
                    label: texts.text("risk.limit"),
                    value: texts.text("risk.limit.long"),
                    identifier: "risk.limit"
                )
            }
            if let until = model.frozenUntilText {
                MeInfoRow(label: texts.text("risk.frozen_until"), value: until, identifier: "risk.until")
            }
            if model.layoutRaw == RiskLayout.bannedAppealing || model.layoutRaw == RiskLayout.frozenAppealing {
                MeInfoRow(label: texts.text("risk.appeal"), value: texts.text("risk.appeal.processing"),
                          identifier: "risk.appealing")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .couliCard()
    }

    @ViewBuilder
    private func withdrawals(_ state: RiskState, _ actions: RiskNoticeActions) -> some View {
        if let error = state.withdrawalsError {
            MeNoticeBar(
                text: error.message(texts), noticeId: error.id, retryTitle: texts.text("me.retry"),
                retryEnabled: !readGate.blocked, retry: actions.retryWithdrawals, identifier: "risk.withdrawalsError"
            )
        } else if !state.withdrawals.isEmpty {
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                Text(verbatim: texts.text("risk.withdrawals"))
                    .couliFont(.body, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(state.withdrawals, id: \.id) { row in
                    withdrawalRow(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .couliCard()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("risk.withdrawals")
        }
    }

    /// 一笔进行中的提现：「金额 · 状态标题」+ 提现记录页同一套副文案（`WithdrawalText.render`，统一金额格式化；R2-03，BR-ID-31 细则、G16）。
    private func withdrawalRow(_ row: PendingWithdrawalRow) -> some View {
        let wallet = controller.walletTexts
        let title = wallet.text(row.titleKey)
        let lines = WithdrawalText.render(row.display, texts: wallet, money: MeMoney.text)
        return VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            Text(verbatim: texts.format(
                "risk.withdrawal_row",
                ["amount": MeMoney.text(row.amountFen), "status": title]
            ))
            .couliFont(.footnote, monospacedDigits: true)
            .foregroundColor(CouliColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .couliFont(.caption, monospacedDigits: true)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ([MeMoney.spoken(row.amountFen) + PriceTerms.spokenPause + title] + lines)
                .joined(separator: PriceTerms.spokenPause)))
        .accessibilityIdentifier("risk.withdrawal.\(row.id)")
    }

    @ViewBuilder
    private func upheld(_ model: RiskNoticeModel, _ state: RiskState, _ actions: RiskNoticeActions) -> some View {
        if let error = state.appealsError {
            MeNoticeBar(
                text: error.message(texts), noticeId: error.id, retryTitle: texts.text("me.retry"),
                retryEnabled: !readGate.blocked, retry: actions.retryAppeals, identifier: "risk.appealsError"
            )
        } else if model.upheldLine {
            MeInfoRow(
                label: texts.text("risk.latest_appeal"),
                value: texts.text("risk.upheld"),
                identifier: "risk.upheld"
            )
            .padding(CouliSpacing.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .couliCard(padding: 0)
        }
    }

    private func note(_ model: RiskNoticeModel) -> some View {
        let key: String = switch model.layoutRaw {
        case RiskLayout.bannedAppealing: "risk.banned_appealing.note"
        case RiskLayout.bannedUpheld: "risk.banned_upheld.note"
        case RiskLayout.frozenAppealing: "risk.frozen_appealing.note"
        case RiskLayout.frozenUpheld: "risk.frozen_upheld.note"
        case RiskLayout.frozen: model.frozenUntilText == nil ? "risk.frozen.note_no_until" : "risk.frozen.note"
        default: "risk.banned.note"
        }
        return Text(verbatim: texts.text(key))
            .couliFont(.footnote)
            .foregroundColor(CouliColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(CouliSpacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: CouliRadius.card).fill(CouliColor.backgroundMuted))
            .accessibilityIdentifier("risk.note")
    }

    private func footer(_ actions: RiskNoticeActions) -> some View {
        HStack(spacing: CouliSpacing.s3) {
            CouliButton(texts.text("risk.contact_cs"), kind: .text, action: actions.contactCs)
                .accessibilityIdentifier("risk.contactCs")
            Text(verbatim: "|")
                .foregroundColor(CouliColor.textSecondary)
                .accessibilityHidden(true)
            CouliButton(texts.text("risk.logout"), kind: .text, action: actions.askLogout)
                .accessibilityFocused($logoutFocused)
                .accessibilityIdentifier("risk.logout")
        }
        .frame(maxWidth: .infinity)
    }
}
