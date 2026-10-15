import DesignSystem
import MeCore
import SwiftUI

/// 关于（About 路由；设计稿 About；G22、G23）：「关于凑狸」、App 名、版本与构建号；生成式 AI 服务公示（agent.filing_text 原文，空串整节不显示）；
/// 【复制诊断信息】+ 说明句；备案号行不显示（TODO(N-33)）。
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
                VStack(spacing: CouliSpacing.s2) {
                    Text(verbatim: texts.text("about.app_name"))
                        .couliFont(.title, weight: .couliBold)
                        .foregroundColor(CouliColor.brandPrimary)
                        .frame(width: CouliSpacing.s16 + CouliSpacing.s4, height: CouliSpacing.s16 + CouliSpacing.s4)
                        .background(RoundedRectangle(cornerRadius: CouliRadius.card).fill(CouliColor.backgroundMuted))
                        .accessibilityHidden(true)
                    Text(verbatim: texts.text("about.app_name"))
                        .couliFont(.title, weight: .couliSemibold)
                        .foregroundColor(CouliColor.textPrimary)
                    Text(verbatim: texts.format("about.version", ["version": controller.version,
                                                                  "build": controller.build]))
                        .couliFont(.footnote, monospacedDigits: true)
                        .foregroundColor(CouliColor.textSecondary)
                        .accessibilityIdentifier("about.version")
                }
                .padding(.vertical, CouliSpacing.s4)
                if let filing = controller.filing {
                    VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                        Text(verbatim: texts.text("about.filing_title"))
                            .couliFont(.body, weight: .couliSemibold)
                            .foregroundColor(CouliColor.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text(verbatim: filing)
                            .couliFont(.footnote)
                            .foregroundColor(CouliColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("about.filing")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .couliCard()
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("about.filingSection")
                }
                VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                    CouliButton(texts.text("about.copy_diagnostics"), kind: .secondary, fillsWidth: true) {
                        controller.copyDiagnostics()
                    }
                    .accessibilityIdentifier("about.copy")
                    Text(verbatim: texts.text("about.copy_desc"))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(CouliSpacing.s4)
            .meContentWidth()
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .meNavigation(texts.text("about.title"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("about.page")
        .meToast(controller.toast, texts: texts) { controller.consumeToast($0) }
    }
}
