import DesignSystem
import ProductSearch
import SwiftUI
import Trade

/// 授权管理页配置（App 组合：执行器、文案、出口）。
@MainActor
public final class AuthManagePageConfig: ObservableObject {
    public let controller: AuthManageController
    public let texts: SearchTexts
    public var onBack: () -> Void = {}
    /// 【联系客服】（统一客服出口未接入前经 Router 打开帮助中心，TODO(N-28) A03 同口径）。
    public var onContact: () -> Void = {}
    private var started = false

    public init(controller: AuthManageController, texts: SearchTexts) {
        self.controller = controller
        self.texts = texts
    }

    /// 页面第一次出现时加载（被盖住再回来不重新加载；授权回来由执行器刷新）。进入页面不自动发起授权（共性第 14 条）。
    func start() {
        guard !started else { return }
        started = true
        controller.load()
    }
}

/// 授权管理（设计稿 AuthManage、AuthManageBlocked；BR-ID-17 细则「授权管理页」）：返回 + 标题 → 平台行（平台名、已授权 / 未授权、
/// 未授权且未停用给【去授权】；停用行下方「该平台返利已被停用，请联系客服」+【联系客服】）→ 「暂不支持自助更换授权的淘宝账号…」。
/// 不提供改绑、解绑；不显示账号名、昵称、头像或授权时间。
public struct AuthManageScreen: View {
    private let config: AuthManagePageConfig
    @ObservedObject private var controller: AuthManageController
    @State private var toast: CouliToastMessage?

    public init(config: AuthManagePageConfig) {
        self.config = config
        controller = config.controller
    }

    private var text: PurchaseText {
        PurchaseText(texts: config.texts)
    }

    public var body: some View {
        VStack(spacing: 0) {
            NavBar(
                title: text.text(PurchaseKeys.manageTitle), backLabel: text.text(PurchaseKeys.back),
                onBack: config.onBack
            )
            .background(CouliColor.backgroundCanvas)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .couliToast($toast)
        .task { config.start() }
        .onChange(of: controller.state.toast) { value in
            guard let value else { return }
            toast = CouliToastMessage(text.withTrace(value.key, platform: "", traceId: value.traceId))
            controller.consumeToast()
        }
    }

    @ViewBuilder private var content: some View {
        let state = controller.state
        switch state.phase {
        case .loading:
            ScrollView {
                ProductCardSkeleton(accessibilityLabel: text.text("search.loading"))
                    .padding(CouliSpacing.s4)
            }
            .accessibilityIdentifier("authManage.loading")
        case .error:
            // 按实际错误码选文案（共性第 23 条）：只有 5xxxx 带 trace6；42901 期间【重试】置灰
            ErrorState(
                title: text.withTrace(
                    state.errorKey ?? AuthManageController.genericKey, platform: "", traceId: state.errorTraceId
                ),
                retryTitle: text.text(PurchaseKeys.retry)
            ) {
                controller.load()
            }
            .disabled(state.rateLimited)
            .accessibilityIdentifier("authManage.error")
        case .content:
            ScrollView {
                VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                    VStack(spacing: 0) {
                        ForEach(Array(state.rows.enumerated()), id: \.element.platform) { index, row in
                            if index > 0 {
                                Rectangle().fill(CouliColor.borderSubtle).frame(height: 1)
                            }
                            rowView(row, busy: state.busyPlatform == row.platform, blocked: state.rateLimited)
                        }
                    }
                    .couliCard(padding: 0)
                    Text(verbatim: text.text(PurchaseKeys.authRebindNote))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, CouliSpacing.s1)
                        .accessibilityIdentifier("authManage.note")
                }
                .padding(CouliSpacing.s4)
                .frame(maxWidth: PurchaseLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func rowView(_ row: AuthManageRow, busy: Bool, blocked: Bool) -> some View {
        let name = text.platformName(row.platform)
        let status = text.text(row.authorized ? PurchaseKeys.manageAuthorized : PurchaseKeys.manageUnauthorized)
        return VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s2) {
                HStack(spacing: CouliSpacing.s2) {
                    Text(verbatim: name)
                        .couliFont(.body, weight: .couliSemibold)
                        .foregroundColor(CouliColor.textPrimary)
                    Text(verbatim: status)
                        .couliFont(.footnote)
                        .foregroundColor(row.authorized ? CouliColor.statusSuccessText : CouliColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("authManage.status.\(row.platform)")
                if row.canAuthorize {
                    CouliButton(
                        text.text(PurchaseKeys.authGo), kind: .secondary, size: .compact, isLoading: busy,
                        isEnabled: !busy && !blocked
                    ) {
                        controller.authorize(row.platform)
                    }
                    .accessibilityIdentifier("authManage.authorize.\(row.platform)")
                }
            }
            if row.blocked {
                Text(verbatim: text.text(PurchaseKeys.manageBlocked, platform: row.platform))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.statusErrorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("authManage.blocked.\(row.platform)")
                CouliButton(text.text(PurchaseKeys.contact), kind: .secondary, size: .compact, action: config.onContact)
                    .accessibilityIdentifier("authManage.contact.\(row.platform)")
            }
        }
        .padding(CouliSpacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
