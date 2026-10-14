import ClientCore
import CouliNetwork
import DesignSystem
import SwiftUI
import WalletCore

/// 钱包页的按钮回调（渲染时一次取出：版本与身份是不可变的普通值，APP-09 共性第 4、63 条；测试取同一份回调保留旧画面）。
@MainActor
public struct WalletActions {
    public let withdraw: () -> Void
    public let records: () -> Void
    public let entry: (String) -> Void
    public let toggleMask: () -> Void
    public let retry: () -> Void

    public static func make(_ controller: WalletController, _ snapshot: WalletSnapshot) -> WalletActions {
        let version = snapshot.version
        let owner = snapshot.owner
        return WalletActions(
            withdraw: { [weak controller] in controller?.withdraw(version: version, owner: owner) },
            records: { [weak controller] in controller?.openRecords(version: version, owner: owner) },
            entry: { [weak controller] route in controller?.openEntry(route, version: version, owner: owner) },
            toggleMask: { [weak controller] in controller?.toggleMask(owner: owner) },
            retry: { [weak controller] in controller?.refresh() }
        )
    }
}

/// 钱包（Wallet 路由；设计稿 Wallet、WalletFrozen、WalletNegative、WalletRiskFrozen、WalletStale、WalletNote*、AdaptLargeTextWallet）：
/// 主卡（可提现余额 + 眼睛 / 提现记录 ›、大数字、【提现】、冻结中 / 已提现两列、待抵扣行）→ 预估收益卡（三项进度分开）→ 入口宫格。金额只取服务端
/// 字段，隐藏时一律「****」（与订单页共用本机偏好）。
public struct WalletScreen: View {
    @ObservedObject var controller: WalletController
    @ObservedObject var mask: AmountMaskStore
    @ObservedObject var readGate: RetryAfterGate
    @ObservedObject var context: WalletPageContext
    @State var help: String?
    @State var toast: CouliToastMessage?
    @Environment(\.dynamicTypeSize) var dynamicTypeSize

    public init(controller: WalletController, mask: AmountMaskStore, context: WalletPageContext) {
        self.controller = controller
        self.mask = mask
        readGate = controller.readGate
        self.context = context
    }

    var texts: WalletTexts {
        context.texts
    }

    public var body: some View {
        let snapshot = controller.state
        let actions = WalletActions.make(controller, snapshot)
        WalletPageScaffold(
            title: texts.text("wallet.title"), backLabel: texts.text("wallet.back"), onBack: context.onBack,
            identifier: "wallet.page"
        ) {
            content(snapshot, actions)
        } bottom: {
            OpenErrorCard(context: context)
        }
        .couliSheet(isPresented: help != nil, dismissOnScrim: { help = nil }, sheet: { helpSheet(help ?? "") })
        .couliToast($toast)
        .task { controller.load() }
    }

    @ViewBuilder func content(_ snapshot: WalletSnapshot, _ actions: WalletActions) -> some View {
        switch snapshot.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(Text(verbatim: texts.text("wallet.loading")))
                .accessibilityIdentifier("wallet.loading")
        case .error:
            ErrorState(
                title: texts.text("wallet.load_failed"), message: snapshot.error?.message(texts),
                retryTitle: texts.text("wallet.retry"), retry: actions.retry
            )
            .disabled(readGate.blocked)
            .accessibilityIdentifier("wallet.error")
        case .content:
            if let summary = snapshot.summary {
                loaded(summary, snapshot, actions)
            }
        }
    }

    func loaded(_ summary: WalletSummary, _ snapshot: WalletSnapshot, _ actions: WalletActions) -> some View {
        let view = WalletSummaryView.of(
            summary, masked: mask.hidden, nowMs: controller.displayNowMillis(), texts: texts
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                banners(snapshot, actions)
                if view.riskBanner.show {
                    riskBanner(view.riskBanner, actions)
                }
                hero(view, snapshot, actions)
                if let negative = view.negativeLine {
                    negativeStrip(negative.fen)
                }
                estimatedCard(view)
                entries(actions)
            }
            .padding(CouliSpacing.s4)
            .frame(maxWidth: WalletLayout.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { actions.retry() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wallet.content")
    }

    @ViewBuilder func banners(_ snapshot: WalletSnapshot, _ actions: WalletActions) -> some View {
        if let at = snapshot.staleAt {
            let time = CouliFormat.timeListPast(epochMillis: at, nowEpochMillis: controller.displayNowMillis())
            let key = snapshot.staleNetwork ? "net.stale_data" : "wallet.updated_at"
            // 设计稿 WalletStale：浅黄提示条（role=status）
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                CouliIconView(.alert, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                    .accessibilityHidden(true)
                Text(verbatim: texts.format(key, ["time": time]))
                    .couliFont(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundColor(CouliColor.statusWarningText)
            .padding(CouliSpacing.s3)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.card).fill(CouliColor.statusWarningText.opacity(0.1))
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("wallet.stale")
        }
        if let error = snapshot.error {
            NoticeBar(
                text: error.message(texts), noticeId: error.id, retryTitle: texts.text("wallet.retry"),
                retryEnabled: !readGate.blocked, retry: actions.retry, identifier: "wallet.refreshError"
            )
        }
    }

    func riskBanner(_ banner: RiskBanner, _ actions: WalletActions) -> some View {
        Button {
            actions.entry(WalletRoutes.riskNotice)
        } label: {
            // 设计稿 WalletRiskFrozen：浅黄提示条，警示图标 + 两行 + 右侧箭头
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                CouliIconView(.alert, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                    .foregroundColor(CouliColor.statusWarningText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    Text(verbatim: texts.format(banner.textKey ?? "", ["reason": banner.reasonText ?? ""]))
                        .couliFont(.footnote, weight: .couliSemibold)
                        .foregroundColor(CouliColor.statusWarningText)
                    Text(verbatim: texts.text("wallet.risk_hint"))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.statusWarningText)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                CouliIconView(.chevron, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                    .foregroundColor(CouliColor.statusWarningText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum, alignment: .leading)
            .padding(CouliSpacing.s3)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.card).fill(CouliColor.statusWarningText.opacity(0.1))
            )
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.card))
        .accessibilityIdentifier("wallet.risk")
    }
}
