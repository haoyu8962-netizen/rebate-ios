import DesignSystem
import SwiftUI
import Trade
import UIKit

/// 搜索页（设计稿 Search、SearchTyping、SearchEmpty、SearchFilterPrice、SearchCardCompare、SearchDisclaimerNote、
/// AdaptNarrowSearch、A11yHitSearch）：返回 + 搜索框（清除）+【搜索】→ 平台 Tab（只显示 search_status=on 的平台）→
/// 排序 → 只看有券 / 价格区间 → 结果列表（比价卡、口径 i 打开说明弹层）→ 翻页；每屏底部常驻口径说明。
/// 状态与请求归属全在 SearchController；页面只发动作、按快照渲染。
public struct SearchView: View {
    let config: SearchPageConfig
    @ObservedObject var controller: SearchController
    @ObservedObject var history: SearchHistory
    @ObservedObject var page: SearchPageConfig
    @State var disclaimer: DisclaimerNote?
    /// 打开过说明弹层的那张卡（关闭后焦点回到它的 i 按钮）。
    @State var disclaimerIndex: Int?
    /// 当前在屏幕上的卡片（每屏底部的口径说明按可见卡片选句，共性 14）。
    @State var visible: Set<Int> = []
    /// 结果列表此刻在屏幕上（没被详情盖住）：恢复滚动位置只在它出现后做（R2-02）。
    @State var listOnScreen = false
    /// 滚动位置的记录与恢复（R3-01）：最近的卡片框、底层 UIScrollView、待校正的恢复目标。
    @State var scrollTracker = SearchScrollTracker()
    /// 每屏底部口径说明区的一行高度（随字号缩放；区高只由屏宽与字号决定，不随内容变，共性 21）。
    @ScaledMetric(relativeTo: .caption) var footerLineHeight: CGFloat = 18
    @AccessibilityFocusState var infoFocused: Bool
    @AccessibilityFocusState var priceChipFocused: Bool
    @AccessibilityFocusState var loadMoreRetryFocused: Bool
    @FocusState var fieldFocused: Bool
    /// 等播报结束再移焦的那条翻页失败文案。
    @State var pendingAnnouncement: String?

    struct DisclaimerNote: Equatable {
        let lines: [String]
    }

    public init(config: SearchPageConfig) {
        self.config = config
        controller = config.controller
        history = config.history
        page = config
    }

    var texts: SearchTexts {
        config.texts
    }

    var snapshot: SearchSnapshot {
        controller.snapshot
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            purchaseTimeout
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .onAppear(perform: openOnce)
        .onChange(of: snapshot.loadMoreError) { error in
            if let error {
                announceLoadMoreFailure(error)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.announcementDidFinishNotification)) {
            focusRetryIfPending($0.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String ?? "")
        }
        .couliDialog(isPresented: disclaimer != nil, restoreFocusTo: $infoFocused) {
            CouliDialog(
                title: texts.text(SearchKeys.disclaimerTitle),
                message: disclaimer?.lines.joined(separator: "\n") ?? "",
                primary: CouliDialogAction(texts.text(SearchKeys.disclaimerClose)) { disclaimer = nil }
            )
        }
        .couliSheet(
            isPresented: page.showsPriceSheet,
            dismissOnScrim: { page.showsPriceSheet = false },
            restoreFocusTo: $priceChipFocused,
            sheet: { priceSheet }
        )
    }

    /// 列表卡购买 8 秒没有响应（ProductBuyTimeout；APP-06b 共性第 29 条）：页底「网络不稳定，请重试」+【重试】（同键重放原请求）。
    @ViewBuilder private var purchaseTimeout: some View {
        if let purchase = page.purchaseController, purchase.state.phase == .timeout {
            RetryBanner(
                message: texts.text(SearchKeys.buyTimeout),
                retryTitle: texts.text(SearchKeys.retry),
                isEnabled: !purchase.state.rateLimited
            ) {
                purchase.retryAfterTimeout()
            }
            .padding(.horizontal, CouliSpacing.s4)
            .padding(.vertical, CouliSpacing.s2)
            .accessibilityIdentifier("search.buyTimeout")
        }
    }

    private var priceSheet: some View {
        SearchPriceSheet(
            texts: texts,
            minText: Binding(get: { page.priceDraftMin ?? "" }, set: { page.priceDraftMin = $0 }),
            maxText: Binding(get: { page.priceDraftMax ?? "" }, set: { page.priceDraftMax = $0 }),
            onClose: { page.showsPriceSheet = false },
            onApply: { min, max in
                let applied = controller.setFilters(hasCoupon: snapshot.hasCoupon, minFen: min, maxFen: max)
                if applied {
                    page.priceDraftMin = nil
                    page.priceDraftMax = nil
                    page.showsPriceSheet = false
                }
                return applied
            }
        )
    }

    func openPriceSheet() {
        // 草稿还在（上次没提交）就沿用；否则从当前筛选开始（共性 17）。
        if page.priceDraftMin == nil, page.priceDraftMax == nil {
            page.priceDraftMin = snapshot.priceMinFen.map(SearchPriceInput.yuanText) ?? ""
            page.priceDraftMax = snapshot.priceMaxFen.map(SearchPriceInput.yuanText) ?? ""
        }
        page.showsPriceSheet = true
    }

    /// 第一次出现：有保存的页面状态就恢复（共性 20），否则按路由参数打开；没有关键词的新页面把焦点放到输入框。
    private func openOnce() {
        if page.start() {
            fieldFocused = true
        }
    }

    func submit() {
        guard controller.submit(page.input) else { return }
        page.input = controller.snapshot.keyword
        history.record(page.input)
        fieldFocused = false
    }

    /// 翻页失败（共性 16，与 DS ErrorState 同一顺序）：立即播报错误文案（默认播报，打断当前朗读），播报结束后焦点移到
    /// 【重试】；结束通知没来时兜底 8 秒移焦；读屏没开时直接移焦。
    private func announceLoadMoreFailure(_ error: SearchResultView) {
        let text = SearchErrorText.text(error, texts: texts, currentPlatform: snapshot.platform)
        guard UIAccessibility.isVoiceOverRunning else {
            loadMoreRetryFocused = true
            return
        }
        pendingAnnouncement = text
        UIAccessibility.post(notification: .announcement, argument: text)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            focusRetryIfPending(text)
        }
    }

    func focusRetryIfPending(_ text: String?) {
        guard let pending = pendingAnnouncement, text == nil || text == pending else { return }
        pendingAnnouncement = nil
        loadMoreRetryFocused = true
    }
}
