import CouliNetwork
import DesignSystem
import SwiftUI
import WalletCore

/// 劳务协议页的回调（渲染时取出这份协议的身份，共性第 59、63 条）。
@MainActor
public struct LaborActions {
    public let toggle: () -> Void
    public let sign: () -> Void
    public let retry: () -> Void

    public static func make(_ controller: LaborAgreementController, _ snapshot: LaborSnapshot) -> LaborActions {
        let owner = snapshot.owner
        return LaborActions(
            toggle: { [weak controller] in controller?.toggle(owner: owner) },
            sign: { [weak controller] in controller?.sign(owner: owner) },
            retry: { [weak controller] in controller?.retry() }
        )
    }
}

/// 劳务协议签署（LaborAgreement 路由，只有 in_app；设计稿 LaborAgreement）：全文可滚动、可被读屏完整读到；勾选默认不勾；签署成功后出栈回
/// Withdraw（不重放）。Release 全文区「协议正文暂未提供」、按钮置灰（G02）。
public struct LaborAgreementScreen: View {
    @ObservedObject var controller: LaborAgreementController
    @ObservedObject var gate: RetryAfterGate
    @ObservedObject var context: WalletPageContext

    public init(controller: LaborAgreementController, context: WalletPageContext) {
        self.controller = controller
        gate = controller.gate
        self.context = context
    }

    var texts: WalletTexts {
        context.texts
    }

    public var body: some View {
        let snapshot = controller.state
        let actions = LaborActions.make(controller, snapshot)
        WalletPageScaffold(
            title: texts.text("labor.title"), backLabel: texts.text("wallet.back"), onBack: context.onBack,
            identifier: "labor.page"
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                    Text(verbatim: texts.text("labor.intro"))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    agreement(snapshot, actions)
                    Text(verbatim: texts.text("labor.signed_note"))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(CouliSpacing.s4)
                .frame(maxWidth: WalletLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        } bottom: {
            VStack(spacing: CouliSpacing.s2) {
                CheckRow(title: texts.text("labor.check"), checked: snapshot.checked, action: actions.toggle,
                         identifier: "labor.check")
                    .disabled(snapshot.phase != .content)
                CouliButton(texts.text("labor.sign"), isLoading: snapshot.signing,
                            isEnabled: controller.signEnabled && !gate.blocked, fillsWidth: true, action: actions.sign)
                    .accessibilityIdentifier("labor.sign")
            }
            .padding(CouliSpacing.s4)
            .frame(maxWidth: WalletLayout.maxContentWidth)
            .frame(maxWidth: .infinity)
            .background(CouliColor.backgroundSurface.ignoresSafeArea(edges: .bottom))
        }
        .task { controller.load() }
    }

    func agreement(_ snapshot: LaborSnapshot, _ actions: LaborActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            Text(verbatim: texts.text("labor.name"))
                .couliFont(.body, weight: .couliSemibold)
                .accessibilityAddTraits(.isHeader)
            if let version = snapshot.version {
                Text(verbatim: texts.format("labor.version", ["version": version]))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
            }
            switch snapshot.phase {
            case .unavailable:
                Text(verbatim: texts.text("labor.unavailable"))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityIdentifier("labor.unavailable")
            case .loading:
                ProgressView()
                    .accessibilityLabel(Text(verbatim: texts.text("wallet.loading")))
            case .error:
                if let error = snapshot.error {
                    NoticeBar(text: error.message(texts), noticeId: error.id, retryTitle: texts.text("wallet.retry"),
                              retry: actions.retry, identifier: "labor.error")
                }
            case .content:
                // 设计稿：全文放在浅底区内、区内上下滚动（读屏读到全文）
                ScrollView {
                    Text(verbatim: snapshot.text ?? "")
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(CouliSpacing.s3)
                        .accessibilityLabel(Text(verbatim: texts.text("labor.fulltext_label") + PriceTerms.spokenPause
                                + (snapshot.text ?? "")))
                        .accessibilityIdentifier("labor.text")
                }
                .frame(minHeight: 160, idealHeight: 380, maxHeight: 380)
                .background(
                    RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                        .fill(CouliColor.backgroundMuted)
                )
            }
            if let error = snapshot.error, snapshot.phase == .content {
                NoticeBar(text: error.message(texts), noticeId: error.id, identifier: "labor.signError")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .couliCard()
    }
}
