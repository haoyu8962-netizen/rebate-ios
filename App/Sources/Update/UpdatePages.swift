import DesignSystem
import Generated
import Router
import SwiftUI

/// 强更全屏页（设计稿 ForceUpdate / ForceUpdateUnavailable；03 §4.1）。
///
/// - 品牌图形 + 「发现新版本 x.y.z」+ 副标题；有 update_notes 时显示「更新内容」卡片（按行分条）；
/// - 主按钮【去更新】（`app_update.go_store`）：按 Gate 选店打开商店；一家都不行时换成提示条 `app_update.unavailable`
///   与【重试】（`app_update.retry`），不给任何下载地址；
/// - 次要入口「隐私政策」（PrivacyCenter）与「注销账号」：已登录（含 deletion_only）时按 getDeletion 结果，冷静期且 can_cancel=true 显示
///   「撤销注销」`app_update.cancel_deletion`，其余、游客、读取失败、限流期间显示「注销账号」（APP-13a-1，`ForceUpdateDeletionLabel`）；
/// - 没有返回按钮，不能侧滑离开（导航栏隐藏）；AppRouting 另外在强更状态下把导航栈拉回强更页。
/// 正文放不下（200% 字号）时只有正文滚动，主按钮与次要入口固定在底部。
struct ForceUpdateScreen: View {
    @EnvironmentObject private var update: AppUpdate
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var wallet: AppWallet

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: CouliSpacing.s6) {
                    header
                    if let notes = noteLines, !notes.isEmpty {
                        notesCard(notes)
                    }
                    if update.ui.forceUnavailable {
                        unavailableNotice
                    }
                }
                .padding(.horizontal, CouliSpacing.s4)
                .padding(.top, CouliSpacing.s12)
                .padding(.bottom, CouliSpacing.s4)
            }
            // 标识只挂在正文滚动区：挂在整页容器上会覆盖底部按钮各自的标识。
            .accessibilityIdentifier("update.force")
            actions
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    private var noteLines: [String]? {
        update.ui.result?.updateNotes?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var header: some View {
        VStack(spacing: CouliSpacing.s4) {
            BrandTile()
            VStack(spacing: CouliSpacing.s2) {
                Text(verbatim: UpdateDraftTexts.title(version: update.ui.result?.latest))
                    .couliFont(.title, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("update.force.title")
                Text(verbatim: UpdateDraftTexts.subtitle)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func notesCard(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            Text(verbatim: UpdateDraftTexts.notesTitle)
                .couliFont(.body, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: CouliSpacing.s2) {
                        BulletDot()
                        Text(verbatim: line)
                            .couliFont(.footnote)
                            .foregroundColor(CouliColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(CouliSpacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.backgroundSurface)
                .couliShadow(.card)
        )
    }

    private var unavailableNotice: some View {
        HStack(alignment: .top, spacing: CouliSpacing.s2) {
            CouliIconView(.alert, size: 20, relativeTo: .footnote)
            Text(verbatim: DefaultTexts.text("app_update.unavailable") ?? "")
                .couliFont(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundColor(CouliColor.statusWarningText)
        .padding(CouliSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .fill(CouliColor.token("status.warning.background"))
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("update.force.unavailable")
    }

    private var actions: some View {
        VStack(spacing: CouliSpacing.s2) {
            if update.ui.forceUnavailable {
                CouliButton(
                    DefaultTexts.text("app_update.retry") ?? "",
                    isLoading: update.ui.working,
                    fillsWidth: true,
                    action: update.retry
                )
                .accessibilityIdentifier("update.force.retry")
            } else {
                CouliButton(
                    DefaultTexts.text("app_update.go_store") ?? "",
                    isLoading: update.ui.working,
                    fillsWidth: true,
                    action: update.forceGoStore
                )
                .accessibilityIdentifier("update.force.goStore")
            }
            HStack(spacing: CouliSpacing.s2) {
                link(DefaultTexts.text("app_update.privacy_policy") ?? "", id: "update.force.privacy") {
                    router.openFromForceUpdatePage(RouteRequest(route: "PrivacyCenter", from: .inApp))
                }
                Text(verbatim: "|")
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.borderSubtle)
                    .accessibilityHidden(true)
                // 「注销账号 / 撤销注销」：标签按 getDeletion（与注销页共用读取闸门）；点击一律经 Router（APP-13a-1）
                ForceUpdateDeletionLink(label: wallet.forceUpdateDeletion) {
                    openDeleteAccount()
                }
            }
        }
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.top, CouliSpacing.s3)
        .padding(.bottom, CouliSpacing.s2)
    }

    private func link(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textLink)
                .padding(.horizontal, CouliSpacing.s2)
                .frame(minHeight: CouliHitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// 「注销账号 / 撤销注销」：经 Router 从强更页次要入口打开；游客先进受限登录（03 §4.1）。
    /// DeleteAccount 的 since.ios 还是 null（未发布，rule-gaps G02 / N-14）：已登录时守卫给升级提示（与别处点到未发布路由相同，
    /// 强更页留在下面，D10-1562 过渡）；N-14 上线后守卫自然放行进 DeleteAccount（注销页已在 RouteViewRegistry 登记）。
    /// TODO(N-14): 过渡期保留「游客 → Login」的写法（守卫在 since=null 时先给升级提示、不会先要求登录；过渡用例 UpdateSmokeTests 断言
    /// 游客进受限登录），since 填上后改为一律请求 DeleteAccount、由守卫按 login 要求先进受限登录（13a-3）。
    private func openDeleteAccount() {
        let route = router.currentGuardState.session == .guest ? RoutePolicy.login : "DeleteAccount"
        router.openFromForceUpdatePage(RouteRequest(route: route, from: .inApp))
    }
}

/// 强更页「注销账号 / 撤销注销」入口（标识沿用 update.force.deleteAccount）：出现时按此刻会话取一次标签，离开即作废在途读取；会话变化由
/// AppWallet 的会话同步出口通知重取。
private struct ForceUpdateDeletionLink: View {
    @ObservedObject var label: ForceUpdateDeletionLabel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: DefaultTexts.text(label.key) ?? "")
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textLink)
                .padding(.horizontal, CouliSpacing.s2)
                .frame(minHeight: CouliHitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("update.force.deleteAccount")
        .onAppear { label.appeared() }
        .onDisappear { label.disappeared() }
    }
}

/// 品牌图形占位（与启动底同一画法；设计稿 80×80、圆角 20）。TODO: 正式品牌图形由设计提供后换成图片资源。
private struct BrandTile: View {
    var body: some View {
        Text(verbatim: LaunchBackdropView.brandTileText)
            .font(.system(size: 22, weight: .bold))
            .tracking(2)
            .foregroundColor(CouliColor.textInverse)
            .frame(width: 80, height: 80)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(CouliColor.brandPrimary)
            )
            .dynamicTypeSize(.large)
            .accessibilityHidden(true)
    }
}

/// 可关闭更新提示（设计稿 MainUpdatePrompt）：标题取 update_title（没有时用强更页标题），说明取 update_notes
/// （没有时用「当前版本过低，请更新后继续使用」）；【暂不更新】【去更新】。点遮罩不关闭。
@MainActor
struct UpdatePromptDialog {
    let result: UpdateCheckResultView
    let onLater: () -> Void
    let onGo: () -> Void

    var dialog: CouliDialog {
        CouliDialog(
            title: result.title,
            centeredTitle: true,
            primary: CouliDialogAction(DefaultTexts.text("app_update.go_store") ?? "", action: onGo),
            secondary: CouliDialogAction(DefaultTexts.text("app_update.later") ?? "", action: onLater)
        ) {
            Text(verbatim: result.body)
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("update.prompt.body")
        }
    }
}

/// 提示里要显示的两段文字。
struct UpdateCheckResultView: Equatable {
    let title: String
    let body: String

    init(title: String?, notes: String?, latest: String?) {
        self.title = title.flatMap { $0.isEmpty ? nil : $0 } ?? UpdateDraftTexts.title(version: latest)
        body = notes.flatMap { $0.isEmpty ? nil : $0 } ?? UpdateDraftTexts.subtitle
    }
}
