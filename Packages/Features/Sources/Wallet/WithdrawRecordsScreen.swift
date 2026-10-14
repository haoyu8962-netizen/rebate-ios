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
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(Text(verbatim: texts.text("wallet.loading")))
                .accessibilityIdentifier("records.loading")
        case .error:
            ErrorState(
                title: texts.text("wallet.load_failed"), message: snapshot.error?.message(texts),
                retryTitle: texts.text("wallet.retry"), retry: actions.retry
            )
            .disabled(readGate.blocked || controller.firstPagePending)
            .accessibilityIdentifier("records.error")
        case .empty:
            empty(actions)
        case .content:
            list(snapshot, actions)
        }
    }

    /// 空态也在可下拉刷新的滚动容器里（iOS R3-02，G30、flow-map §16，共性第 82 条）：内容撑满可视高度，不足一屏仍可下拉；下拉走与列表同一个
    /// refresh（共享读闸门、第一页在途不再受理）。
    func empty(_ actions: RecordsActions) -> some View {
        GeometryReader { proxy in
            ScrollView {
                EmptyState(
                    icon: .ledger, title: texts.text("withdraw_records.empty.title"),
                    message: texts.text("withdraw_records.empty.desc")
                )
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("records.empty")
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .refreshable { actions.retry() }
            .accessibilityIdentifier("records.emptyScroll")
        }
    }

    func list(_ snapshot: RecordsSnapshot, _ actions: RecordsActions) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CouliSpacing.s3) {
                if let error = snapshot.error {
                    NoticeBar(
                        text: error.message(texts), noticeId: error.id, retryTitle: texts.text("wallet.retry"),
                        retryEnabled: !readGate.blocked && !controller.firstPagePending, retry: actions.retry,
                        identifier: "records.refreshError"
                    )
                }
                // 定位单是独立标识的置顶区，其余按月分组、每个月只有一组（iOS R2-05，共性第 80 条）
                ForEach(RecordSections.make(snapshot)) { section in
                    if let title = sectionTitle(section) {
                        Text(verbatim: title)
                            .couliFont(.footnote, weight: .couliSemibold)
                            .foregroundColor(CouliColor.textSecondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    // 设计稿：同一个月的单放在一张卡里，单与单之间分隔线
                    VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                        ForEach(Array(section.items.enumerated()), id: \.element.withdrawalId) { index, item in
                            if index > 0 {
                                Divider()
                            }
                            RecordCard(
                                item: item, detail: snapshot.details[item.withdrawalId],
                                expanded: snapshot.expanded.contains(item.withdrawalId), texts: texts,
                                slaText: slaText, now: controller.displayNowMillis(), actions: actions
                            )
                        }
                    }
                    .couliCard()
                }
                footer(snapshot, actions)
            }
            .padding(CouliSpacing.s4)
            .frame(maxWidth: WalletLayout.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { actions.retry() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("records.list")
    }

    @ViewBuilder func footer(_ snapshot: RecordsSnapshot, _ actions: RecordsActions) -> some View {
        if let error = snapshot.moreError {
            NoticeBar(
                text: error.message(texts), noticeId: error.id, retryTitle: texts.text("wallet.retry"),
                retryEnabled: !readGate.blocked, retry: actions.loadMore, identifier: "records.moreError"
            )
        } else if snapshot.nextCursor != nil {
            CouliButton(texts.text("withdraw_records.load_more"), kind: .text, isLoading: snapshot.loadingMore,
                        action: actions.loadMore)
                .frame(maxWidth: .infinity)
                .onAppear(perform: actions.loadMore)
                .accessibilityIdentifier("records.loadMore")
        } else {
            Text(verbatim: texts.text("withdraw_records.end"))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("records.end")
        }
    }

    /// 月份分组的标题（+08:00）；置顶的定位单不另起月份标题（卡片自己带日期）。
    func sectionTitle(_ section: RecordSection) -> String? {
        guard case let .month(year, month) = section.kind else { return nil }
        return texts.format("withdraw_records.month", ["year": "\(year)", "month": "\(month)"])
    }
}
