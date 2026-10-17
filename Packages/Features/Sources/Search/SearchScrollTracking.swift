import os
import ProductSearch
import SwiftUI
import UIKit

/// 结果列表的坐标系（ScrollView 自身的框：0 就是视口顶边，R3-01）。
enum SearchScrollSpace {
    static let name = "search.results.viewport"
}

/// 各结果卡在列表视口坐标系里的框（序号 → 框）；LazyVStack 只上报已建出的卡。
struct SearchCardFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 视口顶部的卡：按序号找第一张底边还在视口顶边以下的卡（即顶边 ≥ 视口顶 − 卡高），返回序号与顶边偏移。
enum SearchViewportTop {
    static func topCard(_ frames: [Int: CGRect]) -> (index: Int, offset: CGFloat)? {
        frames.sorted { $0.key < $1.key }.first { $0.value.maxY > 0 }.map { ($0.key, $0.value.minY) }
    }
}

/// 恢复时要看的加载状态（取自执行器快照）。
struct SearchRestoreLoad: Equatable {
    var round: Int
    var itemCount: Int
    /// 首屏或下一页在途：等它结束（成功、失败、限流都会改快照并再走一步）。
    var loading: Bool
    /// 还能再翻一页（结果页、没到底、上次翻页没失败、没在限流）。
    var canLoadMore: Bool

    init(_ snapshot: SearchSnapshot) {
        round = snapshot.queryRound
        itemCount = snapshot.items.count
        loading = snapshot.phase == .loading || snapshot.loadingMore
        canLoadMore = snapshot.phase == .content && !snapshot.endReached && !snapshot.loadMoreFailed
            && !snapshot.blocked
    }
}

/// 一次滚动恢复（R3-01、R3I-01..04，共性 33、40–43）：「一次性」任务，绑定查询轮次 + 目标顶部卡序号，不做持续校正，
/// 也不做卡内偏移细调（共性 43：卡内偏移丢失是允许的误差，顶部卡正确优先）。
///
/// 1. 等待（`waiting`）：等目标卡所在页（及其后能撑满一屏的卡）加载好——按执行器的加载状态，需要就翻页；翻页失败、到底、
///    限流时以最后一张已加载卡为目标。
/// 2. 挪动（`aligning`）：下一轮主循环再比对位置基准，没被别人改过就 scrollTo 目标卡顶对齐——这是任务唯一的一次挪动。
/// 3. 确认（`finishing`，FU-IOS-0712 R1-06）：不按队列轮次判完成，等**真实布局**确认——scrollTo 之后有按此刻位置重新上报的卡片框，
///    且视口顶部的卡就是目标卡（或列表已到底、目标卡在视口内）才结束（`aligned` / `alignedAtBottom`）。scrollTo 没生效（模型已更新、
///    列表布局滞后，ScrollViewProxy 还不认识目标卡；列表仍在顶部）时，等下一帧布局后再发同一个 scrollTo（同一次对齐，不算新的挪动）。
///    按新框已落在别处（被别人挪动）→ `displaced` 结束；一直等不到确认（`confirmFrames` 帧）→ `notConfirmed` 结束。确认按显示帧推进
///    （`nextFrame`，生产为 CADisplayLink：两帧之间已提交排版），不连续占用主队列。
///
/// 位置基准（R3I-01）：恢复的结果列表是新建的（结果出现时才建出 ScrollView），任务挪动之前列表一定在顶部；所以基准就是
/// 列表顶部（`-adjustedContentInset.top`），从任务建立那一刻起就有，不等首屏或自动补页结束。等待期间（含补页在途）每一步、
/// 以及挪动前都比对：偏离顶部超过 1pt 即是别人（触摸、惯性、读屏、键盘 / 辅助功能滚动）滚动过 → 取消。
///
/// 被详情盖住时暂停（不挪动，可见后继续）；新查询、出栈、页面失效、用户拖动、进后台时结束。任务存在期间不记录视口顶部的卡；
/// 进后台取消时另外冻结记录（R3I-03，见 `SearchScrollTracker.appDidEnterBackground`）。
@MainActor
final class SearchScrollRestore {
    enum Phase: Equatable {
        case waiting
        case aligning
        case finishing
    }

    let target: SearchScrollTarget
    fileprivate(set) var running = false
    fileprivate(set) var phase = Phase.waiting
    /// 已安排下一轮主循环的工作（挪动 / 收尾）：期间不再安排别的。
    fileprivate(set) var pending = false
    /// 实际对齐的卡：目标卡；目标卡加载不到（到底、失败、限流）时是最后一张已加载卡。
    var goal: Int?
    /// 最近一次发出 scrollTo 时的卡片框上报序号（之后有新上报才算「按 scrollTo 之后的布局」）。
    var issuedAtFrames = 0
    /// 确认阶段已等的帧数、已发出的 scrollTo 次数（同一次对齐；Debug 观察）。
    var confirmTicks = 0
    var issues = 0
    /// 已安排下一帧的确认。
    var tickPending = false
    /// scrollTo 已经让列表离开顶部（生效过）：之后再回到顶部是别人挪的，不重发。
    var landed = false
    /// scrollTo 落定时的列表位置（之后位置再变即是别人挪的：用户接管，取消）。
    var landedOffset: CGFloat?

    init(target: SearchScrollTarget) {
        self.target = target
    }
}

/// 滚动位置的记录与恢复。引用类型放在 @State 里：最近一次的卡片框、底层 UIScrollView、当前的恢复任务都不参与渲染，
/// 改它们不触发整页重画。页面出栈时随视图释放；异步回调只拿弱引用，并核对任务身份。
@MainActor
final class SearchScrollTracker {
    /// 恢复任务的结束原因（R1-06，见 `SearchScrollEndReason`）。
    typealias EndReason = SearchScrollEndReason

    weak var scrollView: UIScrollView?
    private(set) var frames: [Int: CGRect] = [:]
    /// 卡片框上报次数（确认阶段判断「scrollTo 之后有没有新布局」）。
    private(set) var framesSerial = 0
    /// 最近一次任务结束原因与最近 16 次的记录（Debug 可读）。
    private(set) var lastEndReason: EndReason?
    private(set) var endLog: [String] = []
    static let log = Logger(subsystem: "com.couli.app", category: "search.restore")
    /// 上报这组卡片框时列表的滚动位置：与此刻不同说明卡片框不是按当前位置排出的（不可用）。
    private(set) var framesOffset: CGFloat = 0
    private(set) var task: SearchScrollRestore?
    /// 本跟踪器上所有恢复任务挪动列表的总次数（测试核对「每个任务至多一次」）。
    private(set) var moveCount = 0
    private(set) weak var page: SearchPageConfig?
    /// 把某张卡按锚点对齐（ScrollViewProxy.scrollTo；懒加载的卡由此建出）。
    private(set) var scrollToCard: (Int, UnitPoint) -> Void = { _, _ in }
    private var visible = false
    /// App 在后台（didEnterBackground 到 willEnterForeground 之间）。
    private var inBackground = false
    /// 记录冻结（R3I-03）：恢复因进后台被取消时设下，值为冻结时的列表位置与查询轮次。冻结期间迟到的补页、排版、
    /// 卡片框上报都不改写已保存的锚点（仍是恢复目标）。解冻条件见 `thawIfUserActed`。
    private(set) var frozen: (offset: CGFloat, round: Int)?
    /// 放到下一轮主循环执行（默认 DispatchQueue.main.async；两次之间 UIKit 会提交一次排版）。测试可替换以插入排版与用户操作。
    var nextTurn: (@escaping @MainActor @Sendable () -> Void) -> Void = { work in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { work() }
        }
    }

    /// 放到下一个显示帧执行（确认阶段用；默认 CADisplayLink 的下一次回调，此前已提交一次排版）。测试替换以控制排版是否跟上。
    var nextFrame: (@escaping @MainActor @Sendable () -> Void) -> Void = { work in
        SearchFrameTick.next(work)
    }

    /// 列表位置与基准位置相差多少算被别人滚动了（pt）。
    static let offsetTolerance: CGFloat = 1
    /// 确认阶段最多等的显示帧数（只用来结束等不到布局的任务；负载高时帧变慢，墙钟时间随之变长）。
    static let confirmFrames = 240
    /// 目标卡之后至少还要加载多少张卡（能翻页时），免得内容太短、目标卡被列表底部截住而顶不到视口顶部。
    static let tailCards = 8

    var restoring: Bool {
        task != nil
    }

    /// 接上页面（恢复目标与执行器）和列表的 scrollTo。
    func attach(_ page: SearchPageConfig, scrollTo: @escaping (Int, UnitPoint) -> Void) {
        self.page = page
        scrollToCard = scrollTo
    }

    /// 列表出现 / 被盖住：恢复任务随之继续 / 暂停。
    func setVisible(_ visible: Bool) {
        self.visible = visible
        refresh()
    }

    /// 卡片框变化（列表排版、滚动）。
    func update(_ frames: [Int: CGRect]) {
        self.frames = frames
        framesSerial &+= 1
        framesOffset = scrollView?.contentOffset.y ?? 0
        refresh()
        recordTop()
    }

    /// 执行器快照变化（条数、加载状态、阶段、轮次）或页面的恢复目标变化：对齐任务与目标，再走一步。
    func refresh() {
        thawIfUserActed()
        let target = page?.restoreTarget
        if task?.target != target {
            end(reason: target == nil ? .invalidated : .replaced)
            if let target {
                task = SearchScrollRestore(target: target)
            }
        }
        task?.running = visible
        step()
    }

    /// 用户开始拖动（底层 UIScrollView 的拖动手势开始）：取消恢复，位置交给用户；用户实际操作了，记录解冻。
    func userBeganDragging() {
        frozen = nil
        end(reason: .userTookOver)
    }

    /// App 进后台（R3I-03）：有恢复任务就结束它（不再挪动），并冻结记录——此刻列表可能只恢复了一半，后台期间迟到的补页、
    /// 排版、快照处理阶段的框上报都不能按这个位置改写已保存的锚点（保存的仍是恢复目标）。没有恢复任务时照常记录。
    func appDidEnterBackground() {
        inBackground = true
        guard task != nil else { return }
        frozen = (scrollView?.contentOffset.y ?? 0, page?.controller.snapshot.queryRound ?? 0)
        end(reason: .background, record: false)
    }

    /// App 回到前台：只解除「在后台」，冻结的记录要等用户实际操作（拖动、列表位置被改动、开始新查询）后才恢复。
    func appWillEnterForeground() {
        inBackground = false
        refresh()
    }

    /// 解冻条件（R3I-03）：在前台，且用户实际操作过——列表位置离冻结时超过 1pt（读屏、键盘等非触摸滚动；拖动另由
    /// `userBeganDragging` 解冻），或已开始新一轮查询。迟到的补页与排版不改列表位置，不会解冻。
    private func thawIfUserActed() {
        guard let frozen, !inBackground, let scrollView, let page else { return }
        if abs(scrollView.contentOffset.y - frozen.offset) > Self.offsetTolerance
            || page.controller.snapshot.queryRound != frozen.round {
            self.frozen = nil
        }
    }

    /// 等待阶段走一步；挪动由本任务安排的下一轮主循环推进，确认由新的卡片框上报与显示帧推进。
    func step() {
        guard let task, task.running, !task.pending, scrollView != nil, let page else { return }
        guard stillValid(task, page) else {
            end(reason: .invalidated)
            return
        }
        if task.phase == .finishing {
            // 新的卡片框上报 / 重新可见：确认一次；没结束就继续按帧确认
            confirm(task)
            if self.task === task {
                scheduleConfirm(task)
            }
            return
        }
        guard task.phase == .waiting else { return }
        if touching || moved() {
            end(reason: .userTookOver)
            return
        }
        waitStep(task, page)
    }

    /// 等待：目标卡所在页就绪后安排挪动。
    private func waitStep(_ task: SearchScrollRestore, _ page: SearchPageConfig) {
        let load = SearchRestoreLoad(page.controller.snapshot)
        // 首屏或下一页在途：等。结束后快照变化会再走一步（不设固定超时，R3F-01）。期间的位移已由上面的基准比对发现。
        if load.loading {
            return
        }
        guard load.itemCount > 0 else {
            end(reason: .noItems)
            return
        }
        // 目标卡还没加载到，或其后不够撑满一屏：能翻页就翻（等它回来）；到底、失败、限流时以已加载的为准。
        var index = task.target.index
        if load.itemCount - 1 - index < Self.tailCards, load.canLoadMore, page.controller.loadMore() {
            return
        }
        if index >= load.itemCount {
            index = load.itemCount - 1
        }
        task.goal = index
        task.phase = .aligning
        later(task) { tracker, task in tracker.align(task) }
    }

    /// 挪动（唯一一次）：比对基准位置，未被别人改过就把目标卡顶对齐；之后等真实布局确认（`confirm`）。
    private func align(_ task: SearchScrollRestore) {
        guard let goal = task.goal else {
            end(reason: .noItems)
            return
        }
        guard task.running else {
            // 期间被盖住：不挪动，回到等待；重新可见时从等待阶段再走。
            task.phase = .waiting
            return
        }
        if touching || moved() {
            end(reason: .userTookOver)
            return
        }
        moveCount += 1
        task.phase = .finishing
        issue(task, goal)
        scheduleConfirm(task)
    }

    /// 安排下一轮主循环执行 `work`；执行前核对任务身份与页面（新查询、出栈、页面失效即取消）。
    private func later(
        _ task: SearchScrollRestore,
        _ work: @escaping @MainActor @Sendable (SearchScrollTracker, SearchScrollRestore) -> Void
    ) {
        task.pending = true
        nextTurn { [weak self, weak task] in
            guard let self, let task, self.task === task else { return }
            task.pending = false
            guard let page, stillValid(task, page) else {
                end(reason: .invalidated)
                return
            }
            work(self, task)
        }
    }

    /// 任务仍属于页面当前的恢复目标与查询轮次（新查询会改轮次并清目标；出栈清目标）。
    func stillValid(_ task: SearchScrollRestore, _ page: SearchPageConfig) -> Bool {
        page.restoreTarget == task.target && page.controller.snapshot.queryRound == task.target.round
    }

    /// 用户在拖、手指按着或列表在惯性滚动。
    var touching: Bool {
        guard let scrollView else { return false }
        return scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating
    }

    /// 任务挪动前列表应在的位置（位置基准）：列表顶部。恢复的结果列表是新建的，任务挪动之前只有别人能让它离开顶部。
    var baseline: CGFloat? {
        scrollView.map { -$0.adjustedContentInset.top }
    }

    /// 列表位置离开基准（容差 1pt）：任何不是本任务造成的滚动（触摸、惯性、VoiceOver 三指滚动、键盘 / 辅助功能滚动）都算，
    /// 用户接管。只在任务挪动之前判定（等待、挪动前）。
    func moved() -> Bool {
        guard let baseline, let scrollView else { return false }
        return abs(scrollView.contentOffset.y - baseline) > Self.offsetTolerance
    }

    /// 结束当前任务（完成或取消）：摘下任务，并让页面清掉同一个目标；`record` 为真时立即按此刻位置恢复记录。结束原因记下（Debug 可读）。
    func end(reason: EndReason, record: Bool = true) {
        guard let task else { return }
        task.running = false
        self.task = nil
        lastEndReason = reason
        let line = "\(reason.rawValue) target=\(task.target.index) goal=\(task.goal.map(String.init) ?? "-") "
            + "issues=\(task.issues) ticks=\(task.confirmTicks)"
        endLog = Array((endLog + [line]).suffix(16))
        Self.log.notice("restore end: \(line, privacy: .public)")
        page?.endRestore(task.target)
        if record {
            recordTop()
        }
    }

    /// 记录视口顶部的卡（R3-01）：只在列表可见、没有恢复任务、记录没被冻结时记；被详情盖住时冻结。卡片框不是按当前位置
    /// 排出的（刚挪动、新框还没上报）时不按旧框记，等新框上报（此前保留已记的锚点，恢复刚结束时就是恢复目标）。
    private func recordTop() {
        guard visible, task == nil, frozen == nil, let page,
              abs(framesOffset - (scrollView?.contentOffset.y ?? framesOffset)) < 0.5,
              let top = SearchViewportTop.topCard(frames) else { return }
        page.topResultCardChanged(index: top.index, offset: Double(top.offset))
    }
}
