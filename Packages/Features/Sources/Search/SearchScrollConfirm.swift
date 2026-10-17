import SwiftUI
import UIKit

/// 滚动恢复任务的结束原因（FU-IOS-0712 R1-06，Debug 可读：`SearchScrollTracker.lastEndReason`、`endLog` 与系统日志
/// com.couli.app / search.restore）。
enum SearchScrollEndReason: String {
    /// 布局确认：视口顶部就是目标卡。
    case aligned
    /// 布局确认：列表已到底、目标卡在视口内（顶不到视口顶部）。
    case alignedAtBottom = "aligned_at_bottom"
    /// scrollTo 之后按新布局已落在别处（被别人挪动 / 列表结构变化）。
    case displaced
    /// 等满 `confirmFrames` 帧仍没有可确认的布局。
    case notConfirmed = "not_confirmed"
    /// 用户接管（拖动、按住、惯性，或挪动前位置被改）。
    case userTookOver = "user_took_over"
    /// 新查询、出栈、页面失效、恢复目标被清。
    case invalidated
    /// 恢复目标换了（新任务取代）。
    case replaced
    /// 进后台。
    case background
    /// 没有结果可对齐。
    case noItems = "no_items"
}

/// 一次性对齐之后的布局确认（FU-IOS-0712 R1-06，见 `SearchScrollRestore` 第 3 步）。
extension SearchScrollTracker {
    /// 发出（或在没生效时重发）同一次对齐的 scrollTo，并记下此刻的框上报序号。
    func issue(_ task: SearchScrollRestore, _ goal: Int) {
        task.issues += 1
        task.issuedAtFrames = framesSerial
        scrollToCard(goal, .top)
        if moved() {
            task.landed = true
            task.landedOffset = scrollView?.contentOffset.y
        }
    }

    /// 确认（R1-06）：scrollTo 之后有按此刻位置重新上报的卡片框，且视口顶部就是目标卡（或已到底、目标卡在视口内）才结束。
    /// 用户接管即取消；按新框落在别处 → displaced（位置留给别人，不拉回）；scrollTo 一直没生效（列表从没离开顶部）→ 有新布局时重发
    /// 同一个 scrollTo，等下一帧。被详情盖住期间（`running` 为假）照常确认（收尾不需要可见），但不重发 scrollTo（盖住时不挪动）。
    /// 区分程序定位与用户滚动（编排追加，鸿蒙 R1-02 同类）：scrollTo 落定之后列表位置再变（哪怕在同一张卡内的小幅滚动、读屏 /
    /// 键盘滚动，不经触摸）就是别人挪的 → 立即按用户接管取消；取消之后任务已摘下，后续布局 / 帧回调不再下发任何定位。
    func confirm(_ task: SearchScrollRestore) {
        guard let goal = task.goal, let scrollView else {
            end(reason: .noItems)
            return
        }
        if touching {
            end(reason: .userTookOver)
            return
        }
        if task.landed, let landedAt = task.landedOffset,
           abs(scrollView.contentOffset.y - landedAt) > Self.offsetTolerance {
            end(reason: .userTookOver)
            return
        }
        if !task.landed, moved() {
            // 发出 scrollTo 之后第一次离开顶部：按 scrollTo 落定处理，记下落点（之后再变即是别人挪的）
            task.landed = true
            task.landedOffset = scrollView.contentOffset.y
        }
        let fresh = framesSerial != task.issuedAtFrames
            && abs(framesOffset - scrollView.contentOffset.y) < 0.5
        if fresh, let top = SearchViewportTop.topCard(frames) {
            if top.index == goal {
                end(reason: .aligned)
                return
            }
            if atBottom(scrollView), let frame = frames[goal], frame.minY >= -Self.offsetTolerance,
               frame.minY < scrollView.bounds.height {
                end(reason: .alignedAtBottom)
                return
            }
        }
        if !task.landed {
            // 列表从没离开顶部：scrollTo 没生效（布局还没跟上模型）。目标卡就是第一张时上面已确认；否则等新布局后重发。
            if fresh, task.running {
                issue(task, goal)
            }
            return
        }
        if fresh {
            end(reason: .displaced)
        }
    }

    /// 已滚到内容底部（容差 1pt）。
    private func atBottom(_ scrollView: UIScrollView) -> Bool {
        let maxOffset = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset
            .bottom
        return scrollView.contentOffset.y >= maxOffset - Self.offsetTolerance
    }

    /// 确认阶段按显示帧推进：每帧确认一次，直到结束或等满 `confirmFrames` 帧（被盖住期间也照常按帧确认，只是不重发）。
    func scheduleConfirm(_ task: SearchScrollRestore) {
        guard !task.tickPending else { return }
        task.tickPending = true
        nextFrame { [weak self, weak task] in
            guard let self, let task, self.task === task else { return }
            task.tickPending = false
            guard let page, stillValid(task, page) else {
                end(reason: .invalidated)
                return
            }
            task.confirmTicks += 1
            confirm(task)
            guard self.task === task else { return }
            if task.confirmTicks >= Self.confirmFrames {
                end(reason: .notConfirmed)
                return
            }
            scheduleConfirm(task)
        }
    }
}

/// 下一个显示帧（R1-06）：一次性的 CADisplayLink，回调一次即停。两帧之间 UIKit / SwiftUI 已提交排版，确认按真实布局推进，不连续占用主队列。
@MainActor
final class SearchFrameTick: NSObject {
    private var work: (@MainActor @Sendable () -> Void)?
    private var link: CADisplayLink?
    private static var live: Set<SearchFrameTick> = []

    static func next(_ work: @escaping @MainActor @Sendable () -> Void) {
        let tick = SearchFrameTick()
        tick.work = work
        let link = CADisplayLink(target: tick, selector: #selector(fire))
        tick.link = link
        live.insert(tick)
        link.add(to: .main, forMode: .common)
    }

    @objc private func fire() {
        link?.invalidate()
        link = nil
        Self.live.remove(self)
        let work = work
        self.work = nil
        work?()
    }
}
