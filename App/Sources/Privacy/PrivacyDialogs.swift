import DesignSystem
import Generated
import SwiftUI

/// 协议链接要打开的 Agreement 类型（routes.json Agreement.params.type：agreement / privacy / sdk_list）。
/// 《个人信息收集清单》在枚举里没有对应取值：TODO(N-16) 契约补类型前不带 type 打开 Agreement（页面默认）。
enum AgreementLink: CaseIterable {
    case privacyPolicy
    case userAgreement
    case collectionList
    case sdkList

    var title: String {
        switch self {
        case .privacyPolicy: ShellDraftTexts.linkPrivacyPolicy
        case .userAgreement: ShellDraftTexts.linkUserAgreement
        case .collectionList: ShellDraftTexts.linkCollectionList
        case .sdkList: ShellDraftTexts.linkSdkList
        }
    }

    var agreementType: String? {
        switch self {
        case .privacyPolicy: "privacy"
        case .userAgreement: "agreement"
        case .collectionList: nil
        case .sdkList: "sdk_list"
        }
    }

    var identifier: String {
        switch self {
        case .privacyPolicy: "privacy.link.privacy"
        case .userAgreement: "privacy.link.agreement"
        case .collectionList: "privacy.link.collection"
        case .sdkList: "privacy.link.sdk"
        }
    }
}

/// 首启弹窗（设计稿 LaunchPrivacy）：标题居中，要点列表，四个协议链接，【不同意】【同意】。
/// 模态、不能点遮罩或下滑关闭（BR-ID-11），焦点进标题（CouliDialog）。
@MainActor
struct LaunchPrivacyDialog {
    let onAgree: () -> Void
    let onDisagree: () -> Void
    let onOpen: (AgreementLink) -> Void

    var dialog: CouliDialog {
        CouliDialog(
            title: ShellDraftTexts.launchTitle,
            centeredTitle: true,
            primary: CouliDialogAction(DefaultTexts.text("privacy.btn.agree") ?? "", action: onAgree),
            secondary: CouliDialogAction(DefaultTexts.text("privacy.btn.disagree") ?? "", action: onDisagree)
        ) {
            VStack(alignment: .leading, spacing: CouliSpacing.s4) {
                VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                    BodyText(ShellDraftTexts.launchIntro)
                    ForEach(ShellDraftTexts.launchPoints, id: \.self) { point in
                        HStack(alignment: .top, spacing: CouliSpacing.s2) {
                            BulletDot()
                            BodyText(point)
                        }
                    }
                }
                AgreementLinks(links: AgreementLink.allCases, onOpen: onOpen)
            }
        }
    }
}

/// 二次说明（设计稿 LaunchSecondNotice）：【仍不同意】【同意】。iOS 不给【退出 App】（BR-ID-11：iOS 不允许应用自行退出）。
@MainActor
struct SecondNoticeDialog {
    let onAgree: () -> Void
    let onStillDisagree: () -> Void
    let onOpen: (AgreementLink) -> Void

    var dialog: CouliDialog {
        CouliDialog(
            title: ShellDraftTexts.secondTitle,
            centeredTitle: true,
            primary: CouliDialogAction(DefaultTexts.text("privacy.btn.agree") ?? "", action: onAgree),
            secondary: CouliDialogAction(
                DefaultTexts.text("privacy.btn.still_disagree") ?? "",
                action: onStillDisagree
            )
        ) {
            VStack(alignment: .leading, spacing: CouliSpacing.s4) {
                BodyText(ShellDraftTexts.secondBody)
                AgreementLinks(links: [.privacyPolicy, .userAgreement], onOpen: onOpen)
            }
        }
    }
}

/// 要点圆点：4×4、距行顶 9（14/21 行高时与首行文字居中），随字号放大。
private struct BulletDot: View {
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 4
    @ScaledMetric(relativeTo: .footnote) private var top: CGFloat = 9

    var body: some View {
        Circle()
            .fill(CouliColor.textSecondary)
            .frame(width: size, height: size)
            .padding(.top, top)
            .accessibilityHidden(true)
    }
}

/// 正文 14（footnote）主文字色，不截断。
private struct BodyText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text)
            .couliFont(.footnote)
            .foregroundColor(CouliColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 书名号链接一行排开，放不下时整条换行（adaptation-a11y-spec §1 第 4 条：链接不拆行）。
private struct AgreementLinks: View {
    let links: [AgreementLink]
    let onOpen: (AgreementLink) -> Void

    var body: some View {
        CouliFlowLayout(horizontalSpacing: 0, verticalSpacing: CouliSpacing.s1) {
            ForEach(links, id: \.identifier) { link in
                Button {
                    onOpen(link)
                } label: {
                    Text(verbatim: link.title)
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.brandEmphasis)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityRemoveTraits(.isButton)
                .accessibilityAddTraits(.isLink)
                .accessibilityIdentifier(link.identifier)
            }
        }
    }
}
