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
    public let recheck: () -> Void

    public static func make(_ controller: LaborAgreementController, _ snapshot: LaborSnapshot) -> LaborActions {
        let owner = snapshot.owner
        return LaborActions(
            toggle: { [weak controller] in controller?.toggle(owner: owner) },
            sign: { [weak controller] in controller?.sign(owner: owner) },
            retry: { [weak controller] in controller?.retry() },
            recheck: { [weak controller] in controller?.recheckIdentity() }
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
                    RecordText(texts.text("labor.intro"), style: .footnote, color: CouliColor.textSecondary,
                               probe: "labor.intro")
                        .padding(.horizontal, CouliSpacing.s1)
                    agreement(snapshot, actions)
                    RecordText(texts.text("labor.signed_note"), style: .caption, color: CouliColor.textSecondary,
                               probe: "labor.signedNote")
                        .padding(.horizontal, CouliSpacing.s1)
                }
                .padding(.top, CouliSpacing.s2)
                .padding(.horizontal, CouliSpacing.s4)
                .frame(maxWidth: WalletLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        } bottom: {
            VStack(spacing: CouliSpacing.s2) {
                if snapshot.showsRecheck {
                    CouliButton(texts.text("wallet.retry"), kind: .text, action: actions.recheck)
                }
                CheckRow(title: texts.text("labor.check"), spoken: checkSpoken(snapshot), checked: snapshot.checked,
                         action: actions.toggle, identifier: "labor.check", probe: "labor.check")
                    .disabled(snapshot.phase != .content)
                CouliButton(texts.text("labor.sign"), isLoading: snapshot.showsSigning,
                            isEnabled: controller.signEnabled && !gate.blocked, fillsWidth: true, action: actions.sign)
                    .walletProbe("labor.sign", role: "button")
                    .accessibilityIdentifier("labor.sign")
            }
            .padding([.top, .bottom], CouliSpacing.s3)
            .padding(.horizontal, CouliSpacing.s4)
            .frame(maxWidth: WalletLayout.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .task { controller.load() }
    }

    /// 勾选框读屏带版本号（brief §4.2）。
    func checkSpoken(_ snapshot: LaborSnapshot) -> String? {
        snapshot.version.map {
            texts.text("labor.check") + PriceTerms.spokenPause + texts.format("labor.version", ["version": $0])
        }
    }

    func agreement(_ snapshot: LaborSnapshot, _ actions: LaborActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            HStack(alignment: .center, spacing: CouliSpacing.s3) {
                CouliIconView(.orders, size: 24, relativeTo: .body)
                    .foregroundColor(CouliColor.textSecondary)
                    .walletProbe("labor.docIcon", role: "icon")
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    RecordText(texts.text("labor.name"), style: .body, weight: .couliSemibold,
                               color: CouliColor.textPrimary, probe: "labor.name")
                        .accessibilityAddTraits(.isHeader)
                    if let version = snapshot.version {
                        RecordText(texts.format("labor.version", ["version": version]), style: .caption,
                                   color: CouliColor.textSecondary, probe: "labor.version")
                    }
                }
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
                              retry: actions.retry, identifier: "labor.error", tone: .error)
                }
            case .content:
                fullText(snapshot.text ?? "")
            }
            if let error = snapshot.error, snapshot.phase == .content {
                NoticeBar(text: error.message(texts), noticeId: error.id, identifier: "labor.signError", tone: .error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .couliCard()
        .walletProbe("labor.card", role: "card")
    }

    /// 设计稿：全文放在浅底区内、高 360、区内上下滚动（读屏读到全文）。
    func fullText(_ text: String) -> some View {
        ScrollView {
            RecordText(text, style: .footnote, color: CouliColor.textPrimary, probe: "labor.textBody")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(CouliSpacing.s4)
                .accessibilityLabel(Text(verbatim: texts.text("labor.fulltext_label") + PriceTerms.spokenPause + text))
                .accessibilityIdentifier("labor.text")
        }
        .frame(height: 360)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous).fill(CouliColor.backgroundMuted)
        )
        .walletProbe("labor.textArea", role: "text-area")
    }
}
