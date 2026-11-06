import DesignSystem
import OrderCore
import SwiftUI

/// 待跟单卡区（设计稿 ProductPendingTrack / ProductPendingTrackDecided）：每张卡白底圆角，钟表 +「订单同步中」+ 说明（{platform_name} 取平台名）；
/// 右上关闭（读屏「关闭订单同步提示」，44 命中区）；show_claim_entry 时出「未跟单？去找回」；通知行（分隔线 + 铃铛 + perm.push.card_hint +
/// 【开启通知】）只在 `notificationRow` 时出现。42901 禁用、关闭在途（任一位置）时关闭按钮不可点。没有卡时整块为空。
/// 订单列表、商品详情、搜索页共用（App 把它作为 AnyView 交给 Product / Search 页面；Feature 之间不互相依赖）。
public struct PendingTrackCardsView: View {
    @ObservedObject private var service: PendingTrackService
    private let texts: OrderTexts
    private let onClaim: () -> Void
    private let padded: Bool
    @State private var toast: CouliToastMessage?

    /// - Parameter padded: 在商品详情 / 搜索页里自带左右与上下边距（订单列表由列表本身给边距）。
    public init(service: PendingTrackService, texts: OrderTexts, padded: Bool = false, onClaim: @escaping () -> Void) {
        self.service = service
        self.texts = texts
        self.padded = padded
        self.onClaim = onClaim
    }

    public var body: some View {
        let state = service.state
        VStack(spacing: CouliSpacing.s3) {
            ForEach(state.cards) { card in
                // 渲染这一刻取出不可变票据（执行器、显示世代、会话世代、固定身份、卡片与它的有效期）；回调只用它（共性第 42、46 条）
                let ticket = service.ticket(for: card)
                PendingTrackCard(
                    card: card, texts: texts,
                    closeEnabled: !state.blocked && !state.busy.contains(card.key),
                    onClose: { service.dismiss(ticket) },
                    onClaim: onClaim,
                    onNotify: { service.requestNotification(ticket) }
                )
            }
        }
        .padding(.horizontal, padded && !state.cards.isEmpty ? CouliSpacing.s4 : 0)
        .padding(.vertical, padded && !state.cards.isEmpty ? CouliSpacing.s2 : 0)
        // 显示位置的进入 / 离开接入同步失效出口（共性第 46 条，iOS RC-05）：离开即推进显示世代，旧票据全部失效
        .onAppear { service.enterDisplay() }
        .onDisappear { service.leaveDisplay() }
        .couliToast($toast)
        .onChange(of: state.toast) { value in
            // 错误提示经统一的错误消息生成（带 trace6；共性第 8、9 条）
            guard let value else { return }
            toast = value.couli(texts)
            service.consumeToast()
        }
    }
}

/// 商品详情 / 搜索页上待跟单卡执行器的持有者（共性第 43 条，iOS I18）：撤回同意 / 切换环境后页面仍在栈里时，App 作废旧执行器并换上
/// 新环境的执行器（同一个持有者），视图随之换成新执行器的卡片区；之后再次外跳回来照常出卡。
@MainActor
public final class PendingTrackSlotHost: ObservableObject {
    @Published public private(set) var service: PendingTrackService

    public init(service: PendingTrackService) {
        self.service = service
    }

    public func replace(with service: PendingTrackService) {
        self.service = service
    }
}

/// 跟随持有者换执行器的卡片区（换执行器即换视图身份，旧执行器渲染出的回调不再被新视图复用）。
public struct PendingTrackSlotView: View {
    @ObservedObject private var host: PendingTrackSlotHost
    private let texts: OrderTexts
    private let padded: Bool
    private let onClaim: () -> Void

    public init(host: PendingTrackSlotHost, texts: OrderTexts, padded: Bool = false, onClaim: @escaping () -> Void) {
        self.host = host
        self.texts = texts
        self.padded = padded
        self.onClaim = onClaim
    }

    public var body: some View {
        PendingTrackCardsView(service: host.service, texts: texts, padded: padded, onClaim: onClaim)
            .id(ObjectIdentifier(host.service))
    }
}

private struct PendingTrackCard: View {
    let card: PendingTrackCardView
    let texts: OrderTexts
    let closeEnabled: Bool
    let onClose: () -> Void
    let onClaim: () -> Void
    let onNotify: () -> Void

    var body: some View {
        let title = texts.text("pending_track_card.title")
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                CouliIconView(.clock, size: CouliComponentMetric.iconMedium, relativeTo: .body)
                    .foregroundColor(CouliColor.textSecondary)
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    Text(verbatim: title)
                        .couliFont(.body, weight: .couliSemibold)
                        .foregroundColor(CouliColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: texts.format(
                        "pending_track_card.desc", ["platform_name": texts.text("platform." + card.platform)]
                    ))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    CouliIconView(.close, size: CouliComponentMetric.iconMedium, relativeTo: .body)
                        .foregroundColor(CouliColor.textSecondary)
                        .couliHitTarget()
                }
                .buttonStyle(CouliPlainButtonStyle())
                .disabled(!closeEnabled)
                .accessibilityLabel(Text(verbatim: texts.text("pending_track_card.close")))
                .accessibilityIdentifier("pendingTrack.close")
            }
            if card.claimEntry {
                CouliButton(texts.text("pending_track_card.claim"), kind: .text, size: .compact, action: onClaim)
                    .accessibilityIdentifier("pendingTrack.claim")
            }
            if card.notificationRow {
                Rectangle()
                    .fill(CouliColor.borderSubtle)
                    .frame(height: 1)
                    .accessibilityHidden(true)
                CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s2) {
                    HStack(alignment: .top, spacing: CouliSpacing.s2) {
                        CouliIconView(.bell, size: CouliComponentMetric.iconMedium, relativeTo: .footnote)
                            .foregroundColor(CouliColor.textSecondary)
                        Text(verbatim: texts.text("perm.push.card_hint"))
                            .couliFont(.footnote)
                            .foregroundColor(CouliColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    CouliButton(texts.text("perm.push.cta"), kind: .secondary, size: .compact, action: onNotify)
                        .accessibilityIdentifier("pendingTrack.notify")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pendingTrack.notifyRow")
            }
        }
        .couliCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityIdentifier("pendingTrack.card.\(card.platform)")
    }
}
