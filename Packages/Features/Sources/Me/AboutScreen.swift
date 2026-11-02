import DesignSystem
import MeCore
import SwiftUI

/// 关于（About 路由；设计稿 About-v2、AboutBeforeFiling、AboutDark；G22、G23）：「关于凑狸」、App 图标、名字、版本与构建号；生成式 AI 服务公示
/// （agent.filing_text 原文，空串整节不显示）；【复制诊断信息】+ 说明句；备案号行不显示（TODO(N-33)）。
public struct AboutScreen: View {
    @ObservedObject var controller: AboutController

    public init(controller: AboutController) {
        self.controller = controller
    }

    var texts: MeTexts {
        controller.deps.texts
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: CouliSpacing.s4) {
                header
                if let filing = controller.filing {
                    filingSection(filing)
                }
                copyBlock
            }
            .padding(.horizontal, CouliSpacing.s4)
            .padding(.top, CouliSpacing.s2)
            .padding(.bottom, CouliSpacing.s4)
            .meContentWidth()
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .meNavigation(texts.text("about.title"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("about.page")
        .meToast(controller.toast, texts: texts) { controller.consumeToast($0) }
    }

    private var header: some View {
        VStack(spacing: CouliSpacing.s2) {
            AboutAppIcon()
            MeText(texts.text("about.app_name"), style: .body, weight: .couliSemibold, probe: "about.name")
                .foregroundColor(CouliColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            MeText(texts.format("about.version", ["version": controller.version, "build": controller.build]),
                   style: .footnote, monospacedDigits: true, probe: "about.versionText")
                .foregroundColor(CouliColor.textSecondary)
                .accessibilityIdentifier("about.version")
        }
        .multilineTextAlignment(.center)
        .padding(.top, CouliSpacing.s6)
        .padding(.bottom, CouliSpacing.s2)
    }

    /// G-P11：分组名在卡外（缩进 4、到卡 8），卡内 12 / 16、正文 14 主文字，原样不拼接。
    private func filingSection(_ filing: String) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            MeText(texts.text("about.filing_title"), style: .caption, probe: "about.filing.title")
                .foregroundColor(CouliColor.textSecondary)
                .padding(.horizontal, CouliSpacing.s1)
                .accessibilityAddTraits(.isHeader)
            MeText(filing, style: .footnote, probe: "about.filing.text")
                .foregroundColor(CouliColor.textPrimary)
                .accessibilityIdentifier("about.filing")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, CouliSpacing.s3)
                .padding(.horizontal, CouliSpacing.s4)
                .couliCard(padding: 0)
                .meProbe("about.filing.card", role: "card")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("about.filingSection")
    }

    private var copyBlock: some View {
        VStack(spacing: CouliSpacing.s2) {
            CouliButton(texts.text("about.copy_diagnostics"), kind: .secondary, fillsWidth: true,
                        labelProbeID: "about.copy.label", weight: .couliMedium, leadingIcon: .copy,
                        iconProbeID: "about.copy.icon") {
                controller.copyDiagnostics()
            }
            .meProbe("about.copy.button", role: "button")
            .accessibilityIdentifier("about.copy")
            MeText(texts.text("about.copy_desc"), style: .caption, probe: "about.copy.desc")
                .foregroundColor(CouliColor.textSecondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// 关于页的 App 图标（G-P10）：品牌色圆角块 + 反白主图形，与启动图标同构，80 × 80。按图片处理：深色下同一张（`brand.primary` 深浅同值，主图形固定取反白版）。
/// 圆角取令牌 16（画板 18 无令牌，compare 记）。装饰，名字已是标题，读屏不读。
private struct AboutAppIcon: View {
    private static let size = CouliSpacing.s16 + CouliSpacing.s4
    private static let mark = CouliSpacing.s12 + CouliSpacing.s2

    var body: some View {
        RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
            .fill(CouliColor.brandPrimary)
            .overlay {
                CouliLogo(.mark)
                    .environment(\.colorScheme, .dark)
                    .frame(width: Self.mark, height: Self.mark)
            }
            .frame(width: Self.size, height: Self.size)
            .meProbe("about.icon", role: "icon")
            .accessibilityHidden(true)
    }
}
