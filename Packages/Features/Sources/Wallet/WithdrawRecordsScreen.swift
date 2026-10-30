import CouliNetwork
import DesignSystem
import SwiftUI
import WalletCore

/// 提现记录的回调（渲染时取出版本与身份；每张卡的单号、流水号也是渲染时的值，共性第 4、41、63 条）。
@MainActor
public struct RecordsActions {
    public let toggle: (String) -> Void
    public let copy: (String, String) -> Void
    public let changeAccount: (String) -> Void
    public let contact: () -> Void
    public let loadMore: () -> Void
    public let retry: () -> Void

    public static func make(_ controller: WithdrawRecordsController, _ snapshot: RecordsSnapshot) -> RecordsActions {
        let version = snapshot.version
        let owner = snapshot.owner
        return RecordsActions(
            toggle: { [weak controller] id in controller?.toggle(version: version, id: id, owner: owner) },
            copy: { [weak controller] id, text in
                controller?.copy(version: version, id: id, text: text, owner: owner)
            },
            changeAccount: { [weak controller] id in
                controller?.changeAccount(version: version, id: id, owner: owner)
            },
            contact: { [weak controller] in controller?.contact(owner: owner) },
            loadMore: { [weak controller] in controller?.loadMore() },
            retry: { [weak controller] in controller?.refresh() }
        )
    }
}

/// 提现记录（WithdrawRecords 路由；设计稿 WithdrawRecords*、WithdrawRecordsStates 的非微信分支）：按月分组（+08:00）、卡片「提现 {amount}」+
/// 状态 +「{日期} · {通道} {脱敏串}」+ 副文案（G08）；整卡展开 / 收起；详情明细、交易流水号【复制】、【联系客服】、【修改收款账号】；空态。
/// 金额不受隐藏开关影响（G23）。
public struct WithdrawRecordsScreen: View {
    @ObservedObject var controller: WithdrawRecordsController
    @ObservedObject var readGate: RetryAfterGate
    @ObservedObject var context: WalletPageContext
    @State var toast: CouliToastMessage?
    @StateObject var keeper = RecordListKeeper()
    let slaText: String?

    public init(controller: WithdrawRecordsController, context: WalletPageContext, slaText: String?) {
        self.controller = controller
        readGate = controller.readGate
        self.context = context
        self.slaText = slaText
    }

    var texts: WalletTexts {
        context.texts
    }

    public var body: some View {
        let snapshot = controller.state
        let actions = RecordsActions.make(controller, snapshot)
        WalletPageScaffold(
            title: texts.text("withdraw_records.title"), backLabel: texts.text("wallet.back"), onBack: context.onBack,
            identifier: "records.page"
        ) {
            content(snapshot, actions)
        } bottom: {
            // 【修改收款账号】前的实名查询失败（trace6、重试、关闭，遵守共享读禁用期；共性第 72 条，iOS R1-08）
            OpenErrorCard(context: context)
        }
        .couliToast($toast)
        .onChange(of: snapshot.toast) { value in
            guard let value else { return }
            toast = value.toast(texts)
            controller.consumeToast(value.id)
        }
        .task { controller.load() }
    }

    @ViewBuilder func content(_ snapshot: RecordsSnapshot, _ actions: RecordsActions) -> some View {
        switch snapshot.phase {
        case .loading:
            // 首次加载：3 行骨架（W35），白卡在列表同一位置
            ScrollView {
                RecordSkeleton(rows: 3, probe: "records.loading", label: texts.text("wallet.loading"))
                    .padding(.horizontal, CouliSpacing.s4)
                    .padding(.top, CouliSpacing.s2)
                    .frame(maxWidth: WalletLayout.maxContentWidth)
                    .frame(maxWidth: .infinity)
            }
            .scrollDisabled(true)
        case .error:
            ErrorState(
                title: texts.text("wallet.load_failed"), message: snapshot.error?.message(texts),
                retryTitle: texts.text("wallet.retry"), retry: actions.retry
            )
            .disabled(readGate.blocked || controller.firstPagePending)
            .walletProbe("records.error", role: "error")
            .accessibilityIdentifier("records.error")
        case .empty:
            empty(actions)
        case .content:
            list(snapshot, actions)
        }
    }

    /// 空态也在可下拉刷新的滚动容器里（iOS R3-02，G30、flow-map §16，共性第 82 条）：内容撑满可视高度，不足一屏仍可下拉；下拉走与列表同一个
    /// refresh（共享读闸门、第一页在途不再受理）。画板 WithdrawRecordsEmpty：流水图标，内容靠上（图示上留白 48）。
    func empty(_ actions: RecordsActions) -> some View {
        GeometryReader { proxy in
            ScrollView {
                EmptyState(
                    icon: .ledger, title: texts.text("withdraw_records.empty.title"),
                    message: texts.text("withdraw_records.empty.desc"), iconProbeID: "records.empty.icon"
                )
                .walletProbe("records.empty", role: "empty")
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("records.empty")
                .padding(.top, CouliSpacing.s2 + CouliSpacing.s4)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
            }
            .refreshable { actions.retry() }
            .accessibilityIdentifier("records.emptyScroll")
        }
    }

    func list(_ snapshot: RecordsSnapshot, _ actions: RecordsActions) -> some View {
        let signature = RecordListSignature(
            items: snapshot.items, details: snapshot.details, expanded: snapshot.expanded,
            pinned: snapshot.pinnedId, notice: snapshot.error?.id
        )
        // 在新布局之前按旧布局记锚点（记录级锚点，Android b r1 S2-1 / r2 S2-1）
        keeper.update(signature)
        let now = controller.displayNowMillis()
        // 不用懒加载容器：一月一卡后每块都可能很高，懒加载会让屏外整月 / 展开卡不建出（读屏与测量都缺），翻页时机也改由页脚真实位置决定
        return ScrollView {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                if let error = snapshot.error {
                    NoticeBar(
                        text: error.message(texts), noticeId: error.id, retryTitle: texts.text("wallet.retry"),
                        retryEnabled: !readGate.blocked && !controller.firstPagePending, retry: actions.retry,
                        identifier: "records.refreshError"
                    )
                }
                ForEach(RecordBlock.make(snapshot, texts: texts, slaText: slaText, now: now)) { block in
                    blockView(block, snapshot, actions)
                }
                footer(snapshot, actions)
            }
            .padding(.top, CouliSpacing.s2)
            .padding(.horizontal, CouliSpacing.s4)
            .padding(.bottom, CouliSpacing.s4)
            .coordinateSpace(name: RecordListKeeper.space)
            .background(RecordScrollLocator(keeper: keeper))
            .frame(maxWidth: WalletLayout.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { actions.retry() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("records.list")
    }

    @ViewBuilder func blockView(_ block: RecordBlock, _ snapshot: RecordsSnapshot,
                                _ actions: RecordsActions) -> some View {
        switch block.kind {
        case let .title(text, probe):
            // 月份标题（W19）：12 次文字、左缩进 4
            RecordText(text, style: .caption, color: CouliColor.textSecondary, probe: probe)
                .padding(.horizontal, CouliSpacing.s1)
                .accessibilityAddTraits(.isHeader)
        case let .rows(faces, card):
            RecordMonthCard(faces: faces, card: card, texts: texts, actions: actions, keeper: keeper)
        case let .detail(face):
            RecordDetailCard(face: face, detail: snapshot.details[face.item.withdrawalId], texts: texts,
                             actions: actions)
                .recordPlace(face.item.withdrawalId, keeper: keeper)
        }
    }

    /// 页脚：翻页中 1 行骨架；翻页失败提示 +【重试】；还有下一页时【加载更多】；到底「没有更多记录了」居中（W30）。
    /// 只在页脚真正露进可视区时翻页（`RecordListKeeper.footer`），不靠页脚被懒加载容器提前建出的 onAppear（Android b r1 S1）。
    func footer(_ snapshot: RecordsSnapshot, _ actions: RecordsActions) -> some View {
        let key: String? = if let cursor = snapshot.nextCursor, !snapshot.loadingMore, snapshot.moreError == nil {
            "\(snapshot.version)|\(snapshot.items.count)|\(cursor)"
        } else {
            nil
        }
        return footerContent(snapshot, actions)
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .global)
                    Color.clear
                        .onAppear { keeper.footer(frame: frame) }
                        .onChange(of: frame) { keeper.footer(frame: $0) }
                        .onDisappear { keeper.footer(frame: nil) }
                }
            )
            .onAppear { keeper.footer(key: key, loadMore: actions.loadMore) }
            .onChange(of: key) { keeper.footer(key: $0, loadMore: actions.loadMore) }
    }

    @ViewBuilder func footerContent(_ snapshot: RecordsSnapshot, _ actions: RecordsActions) -> some View {
        if snapshot.loadingMore {
            RecordSkeleton(rows: 1, probe: "records.loadingMore", label: texts.text("wallet.loading"))
        } else if let error = snapshot.moreError {
            NoticeBar(
                text: error.message(texts), noticeId: error.id, retryTitle: texts.text("wallet.retry"),
                retryEnabled: !readGate.blocked, retry: actions.loadMore, identifier: "records.moreError"
            )
            .walletProbe("records.moreError", role: "notice")
        } else if snapshot.nextCursor != nil {
            CouliButton(texts.text("withdraw_records.load_more"), kind: .text, action: actions.loadMore)
                .walletProbe("records.loadMore", role: "button")
                .accessibilityIdentifier("records.loadMore")
        } else {
            RecordText(texts.text("withdraw_records.end"), style: .caption, color: CouliColor.textSecondary,
                       alignment: .center, probe: "records.end")
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("records.end")
        }
    }
}

/// 列表的一块（懒加载容器的一个子项）：月份标题 / 一张月卡（同月相邻的收起行）/ 一张展开卡（W20、W23，G-W08）。
/// 分区沿用纯规则 `RecordSections`（定位单置顶区不另起月份标题；每个月只有一组）；视图只按展开集切块、不重排。
struct RecordBlock: Identifiable {
    enum Kind {
        case title(String, probe: String)
        case rows([RecordFace], card: String)
        case detail(RecordFace)
    }

    let id: String
    let kind: Kind

    @MainActor
    static func make(_ snapshot: RecordsSnapshot, texts: WalletTexts, slaText: String?, now: Int64) -> [RecordBlock] {
        var out: [RecordBlock] = []
        for section in RecordSections.make(snapshot) {
            if case let .month(year, month) = section.kind {
                let title = texts.format("withdraw_records.month", ["year": "\(year)", "month": "\(month)"])
                out.append(RecordBlock(id: "title.\(section.id)",
                                       kind: .title(title, probe: String(format: "records.month.%04d-%02d", year,
                                                                         month))))
            }
            var run: [RecordFace] = []
            var cards = 0
            func flush() {
                guard !run.isEmpty else { return }
                let key = "\(section.id).\(cards)"
                out.append(RecordBlock(id: "card.\(key)", kind: .rows(run, card: "records.card.\(key)")))
                run = []
                cards += 1
            }
            for item in section.items {
                let face = RecordFace(item: item, texts: texts, slaText: slaText, now: now)
                if snapshot.expanded.contains(item.withdrawalId) {
                    flush()
                    out.append(RecordBlock(id: "detail.\(item.withdrawalId)", kind: .detail(face)))
                } else {
                    run.append(face)
                }
            }
            flush()
        }
        return out
    }
}
