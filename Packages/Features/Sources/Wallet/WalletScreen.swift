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
            WalletSkeleton(label: texts.text("wallet.loading"))
        case .error:
            ErrorState(
                title: texts.text("wallet.load_failed"), message: snapshot.error?.message(texts),
                retryTitle: texts.text("wallet.retry"), retry: actions.retry
            )
            .disabled(readGate.blocked)
            .walletProbe("wallet.error", role: "state")
            .accessibilityIdentifier("wallet.error")
        case .content:
            if let summary = snapshot.summary {
                loaded(summary, snapshot, actions)
            }
        }
    }

    /// 内容列（brief §2.1）：断网 / 旧数据条 → 读取失败条 → 风控条 → 主卡 → 主卡下警告条（待抵扣 / 30306）→ 预估卡 → 入口行。
    /// 左右 16、顶 8、块间 12；≥ 600 宽限宽 600 居中。
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
                    negativeStrip(negative)
                }
                if let reason = view.withdrawReasonKey {
                    disabledStrip(reason)
                }
                estimatedCard(view)
                entries(actions)
            }
            .padding(.horizontal, CouliSpacing.s4)
            // WalletStale：断网条紧贴导航栏（上 0），其下到主卡 16；没有断网条时内容顶 8
            .padding(.top, snapshot.staleAt == nil ? CouliSpacing.s2 : 0)
            .padding(.bottom, CouliSpacing.s4)
            .frame(maxWidth: WalletLayout.maxContentWidth)
            .walletProbe("wallet.content", role: "column")
            .frame(maxWidth: .infinity)
        }
        .refreshable { actions.retry() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wallet.content")
    }

    /// 旧数据提示文字（断网：「网络不可用，以下为 {time} 的数据」；其他读取失败：「更新于 {time}」）；不是旧数据时 nil。
    func staleText(_ snapshot: WalletSnapshot) -> String? {
        guard let at = snapshot.staleAt else { return nil }
        let time = CouliFormat.timeListPast(epochMillis: at, nowEpochMillis: controller.displayNowMillis())
        return texts.format(snapshot.staleNetwork ? "net.stale_data" : "wallet.updated_at", ["time": time])
    }

    @ViewBuilder func banners(_ snapshot: WalletSnapshot, _ actions: WalletActions) -> some View {
        if let text = staleText(snapshot) {
            // 设计稿 WalletStale（W8）：警告浅底条、断网图标 20 + 14 警告字色，最先、紧贴导航栏（role=status）
            WalletStrip(icon: snapshot.staleNetwork ? .wifiOff : .info, probe: "wallet.stale") {
                WalletText(text, style: .footnote, probe: "wallet.stale.text")
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("wallet.stale")
            .padding(.bottom, CouliSpacing.s1)
        }
        if let error = snapshot.error {
            NoticeBar(
                text: error.message(texts), noticeId: error.id, retryTitle: texts.text("wallet.retry"),
                retryEnabled: !readGate.blocked, retry: actions.retry, identifier: "wallet.refreshError"
            )
        }
    }

    /// 风控提示条（W6 / W7，WalletRiskFrozen-v2）：警告浅底、两行都是警告字色（首行 600、次行 14）、图标与 › 20；整条一个按钮进 RiskNotice。
    /// 文案维持现状（G-W03：原因类别 / 到期时间无字段，不取 getMe）。
    func riskBanner(_ banner: RiskBanner, _ actions: WalletActions) -> some View {
        Button {
            actions.entry(WalletRoutes.riskNotice)
        } label: {
            WalletStrip(icon: .alert, probe: "wallet.risk", chevron: true) {
                WalletText(texts.format(banner.textKey ?? "", ["reason": banner.reasonText ?? ""]), style: .footnote,
                           weight: .couliSemibold, probe: "wallet.risk.title")
                WalletText(texts.text("wallet.risk_hint"), style: .footnote, probe: "wallet.risk.hint")
            }
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.button))
        .accessibilityIdentifier("wallet.risk")
    }
}
