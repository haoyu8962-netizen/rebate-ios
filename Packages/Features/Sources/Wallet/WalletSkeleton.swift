import DesignSystem
import SwiftUI

/// 钱包加载骨架（brief §2.1-9，W17；无稿，按新结构）：主卡块（首行两条、金额条 + 按钮块、底部两格）→ 预估两列块 → 入口两格。
/// 骨架块是 DesignSystem `SkeletonBlock`（中性浅底）；整块读屏一次「加载中」，标识沿用 `wallet.loading`。
/// 每块报测量 `wallet.skeleton.<块>`（Android 评审 r1 S2-3：逐块核位置与可见像素）。
struct WalletSkeleton: View {
    let label: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                heroCard
                estimateCard
                entriesCard
            }
            .padding(.horizontal, CouliSpacing.s4)
            .padding(.top, CouliSpacing.s2)
            .padding(.bottom, CouliSpacing.s4)
            .frame(maxWidth: WalletLayout.maxContentWidth)
            .walletProbe("wallet.skeleton", role: "skeleton")
            .frame(maxWidth: .infinity)
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityIdentifier("wallet.loading")
    }

    private func block(_ id: String, width: CGFloat, height: CGFloat) -> some View {
        SkeletonBlock(width: width, height: height)
            .walletProbe("wallet.skeleton.\(id)", role: "block")
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s4) {
            HStack {
                block("hero.title", width: 96, height: 16)
                Spacer(minLength: CouliSpacing.s3)
                block("hero.records", width: 72, height: 16)
            }
            HStack(alignment: .center) {
                block("hero.amount", width: 128, height: 34)
                Spacer(minLength: CouliSpacing.s3)
                block("hero.button", width: 96, height: 48)
            }
            HStack(alignment: .top, spacing: CouliSpacing.s3) {
                block("hero.frozen", width: 64, height: 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                block("hero.withdrawn", width: 64, height: 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(CouliSpacing.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.backgroundSurface)
                .couliShadow(.card)
        )
        .walletProbe("wallet.skeleton.hero", role: "card")
    }

    private var estimateCard: some View {
        HStack(alignment: .top, spacing: CouliSpacing.s3) {
            block("estimate.left", width: 112, height: 56)
                .frame(maxWidth: .infinity, alignment: .leading)
            block("estimate.right", width: 112, height: 56)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .couliCard()
    }

    private var entriesCard: some View {
        HStack(spacing: 0) {
            block("entry.0", width: 72, height: 56)
                .frame(maxWidth: .infinity)
            block("entry.1", width: 72, height: 56)
                .frame(maxWidth: .infinity)
        }
        .couliCard(padding: CouliSpacing.s2)
    }
}
