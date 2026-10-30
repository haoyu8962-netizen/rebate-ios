import SwiftUI
import UIKit
import WalletCore

/// 列表内容的变化签名（影响记录位置的一切：条目与内容、详情、展开集、置顶单、顶部刷新失败条）。
struct RecordListSignature: Equatable {
    let items: [Withdrawal]
    let details: [String: Withdrawal]
    let expanded: Set<String>
    let pinned: String?
    let notice: Int?
}

/// 提现记录页私有的滚动位置管理（APP-09v-b；Android b 评审 r1 S1 / S2-1、r2 S2-1 的 iOS 对应）。只动滚动位置，不碰数据与请求：
/// - **翻页**：只在页脚真正露进可视区时调一次渲染时的 `loadMore`（不靠懒加载容器提前建出页脚的 onAppear）；同一页（游标 + 条数 + 版本）
///   在页脚一直可见期间只调一次，页脚离开可视区后复位。去重、游标、并发仍由执行器 `loadMore()` 自己守。
/// - **记录级锚点**：内容签名变化（展开 / 收起、翻页追加、刷新前插、同 ID 内容变高、详情到达）时，按变化前的布局记下锚点——被展开 /
///   收起的那张单（在可视区内时），否则可视区顶上最靠上、仍露出的那张单——及它在内容坐标里的位置；新布局出来后按它在内容坐标里的位移
///   同步挪滚动偏移，使它相对可视区顶边不动。内容坐标与滚动无关，所以用户 / 程序滚动不会被误当成位移。用户一拖动就放弃本次恢复；
///   内容变化发生在手指按住或惯性减速中时不记锚点、恢复时撞上用户滚动也放弃（r1 S2-1：不硬停惯性、不拉回）。
@MainActor
final class RecordListKeeper: ObservableObject {
    static let space = "records.content"

    private struct Anchor {
        let id: String
        let contentMinY: CGFloat
        /// 记下锚点时的滚动偏移：恢复目标 = 它 + 锚点在内容坐标里的位移（幂等，SwiftUI 回写偏移后下一步照样纠正）。
        let offset: CGFloat
        let until: Date
    }

    weak var scrollView: UIScrollView? {
        didSet {
            if scrollView !== oldValue {
                scheduleFooterCheck()
            }
        }
    }

    private var content: [String: CGRect] = [:]
    private var window: [String: CGRect] = [:]
    private var owners: [String: UUID] = [:]
    private var signature: RecordListSignature?
    private var anchor: Anchor?
    private var footerFrame: CGRect?
    private var footerKey: String?
    private var loadMore: (() -> Void)?
    private var pagedKey: String?

    // MARK: - 记录位置

    func place(_ id: String, owner: UUID, content frame: CGRect, window screen: CGRect) {
        owners[id] = owner
        let moved = content[id] != frame
        content[id] = frame
        window[id] = screen
        if moved, anchor?.id == id {
            // 不在布局回调里同步改偏移（SwiftUI 同一轮可能回写），排到下一轮
            DispatchQueue.main.async { [weak self] in self?.restore() }
        }
    }

    func leave(_ id: String, owner: UUID) {
        guard owners[id] == owner else { return }
        owners[id] = nil
        content[id] = nil
        window[id] = nil
    }

    /// 可视区（窗口坐标；底边扣掉内容底部内边距）。
    private var viewport: CGRect? {
        guard let scrollView, scrollView.window != nil else { return nil }
        var rect = scrollView.convert(scrollView.bounds, to: nil)
        rect.size.height -= scrollView.adjustedContentInset.bottom
        return rect
    }

    // MARK: - 锚点

    /// 每次渲染列表时调（在新布局之前）：签名变了就按变化前的布局记锚点，并在新布局出来后恢复。
    func update(_ next: RecordListSignature) {
        guard next != signature else { return }
        let previous = signature
        signature = next
        guard let previous, !previous.items.isEmpty, let viewport, let scrollView, !scrollView.recordUserMoving else {
            // 手指按住或惯性减速中（r1 S2-1）：不记锚点、不恢复，让用户的滚动自然继续
            anchor = nil
            return
        }
        let toggled = previous.expanded.symmetricDifference(next.expanded)
        var pick: String? = if toggled.count == 1, let id = toggled.first, let frame = window[id], visible(
            frame,
            in: viewport
        ) {
            id
        } else {
            window.filter { visible($0.value, in: viewport) }.min { $0.value.minY < $1.value.minY }?.key
        }
        guard let pick, let frame = content[pick] else {
            anchor = nil
            return
        }
        anchor = Anchor(id: pick, contentMinY: frame.minY, offset: scrollView.contentOffset.y,
                        until: Date().addingTimeInterval(1.0))
        for delay in [0.0, 0.03, 0.08, 0.15, 0.25, 0.4, 0.6, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.restore() }
        }
    }

    private func visible(_ frame: CGRect, in viewport: CGRect) -> Bool {
        frame.maxY > viewport.minY + 1 && frame.minY < viewport.maxY
    }

    private func restore() {
        guard let current = anchor else { return }
        guard Date() < current.until else {
            anchor = nil
            return
        }
        // 锚点那张单的视图可能正在换实例（行 ↔ 展开卡），等它的新位置报上来
        guard let scrollView, let frame = content[current.id] else { return }
        // 恢复窗口内用户又按住 / 甩动（含拖动开始事件之前的惯性）：放弃本次恢复，不打断惯性、不把列表拉回（r1 S2-1）
        guard !scrollView.recordUserMoving else {
            anchor = nil
            return
        }
        let inset = scrollView.adjustedContentInset
        let top = -inset.top
        let bottom = max(top, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        let target = min(max(current.offset + frame.minY - current.contentMinY, top), bottom)
        // 新布局的位置回调可能晚几帧才到：在恢复窗口内一直按目标纠正（幂等），窗口过了或用户一拖动就结束
        guard abs(scrollView.contentOffset.y - target) > 0.5 else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: false)
    }

    func userBeganDragging() {
        anchor = nil
    }

    // MARK: - 翻页

    /// 页脚的窗口框（出现 / 移动时报；消失时 nil）。
    func footer(frame: CGRect?) {
        footerFrame = frame
        checkFooter()
    }

    /// 可翻页状态（`key` = 本页标识；不能翻时 nil）与渲染时的 `loadMore`：变化后等新布局出来再判断（页脚位置要用新布局的）。
    func footer(key: String?, loadMore: @escaping () -> Void) {
        self.loadMore = loadMore
        guard key != footerKey else { return }
        footerKey = key
        scheduleFooterCheck()
    }

    private func scheduleFooterCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.checkFooter() }
    }

    /// 页脚露进可视区且有可翻的一页时，每个 key 只调一次 `loadMore`；页脚离开可视区后复位。
    private func checkFooter() {
        guard let viewport else { return }
        guard let frame = footerFrame, frame.minY < viewport.maxY, frame.maxY > viewport.minY else {
            pagedKey = nil
            return
        }
        guard let key = footerKey, key != pagedKey else { return }
        pagedKey = key
        loadMore?()
    }
}

extension UIScrollView {
    /// 用户正在滚动：手指按住拖动（含下拉刷新的拖拽）或松手后的惯性减速。只按下不移动（点按展开 / 收起）、程序设置偏移都不算——
    /// 所以不用 `isTracking`（点按卡片时按下即为 true）。
    var recordUserMoving: Bool {
        isDragging || isDecelerating
    }
}

private struct RecordFrames: Equatable {
    let content: CGRect
    let window: CGRect
}

/// 记录（收起行 / 展开卡）把自己在内容坐标与窗口坐标里的框报给 `RecordListKeeper`。
private struct RecordPlace: ViewModifier {
    let id: String
    let keeper: RecordListKeeper
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    // 两个框作为一个值观察：onChange 的闭包里别的取值可能是上一轮的（两个 onChange 互相用旧值覆盖）
                    let frames = RecordFrames(content: proxy.frame(in: .named(RecordListKeeper.space)),
                                              window: proxy.frame(in: .global))
                    Color.clear
                        .onAppear { keeper.place(id, owner: owner, content: frames.content, window: frames.window) }
                        .onChange(of: frames) { keeper.place(id, owner: owner, content: $0.content, window: $0.window) }
                }
            )
            .onDisappear { keeper.leave(id, owner: owner) }
    }
}

extension View {
    func recordPlace(_ id: String, keeper: RecordListKeeper) -> some View {
        modifier(RecordPlace(id: id, keeper: keeper))
    }
}

/// 找到承载列表的 UIScrollView（SwiftUI ScrollView 在 iOS 16 上没有按偏移滚动的接口；同搜索页 `SearchScrollViewLocator` 做法），
/// 并监听它的拖动手势（用户一拖动就放弃锚点恢复）。
struct RecordScrollLocator: UIViewRepresentable {
    let keeper: RecordListKeeper

    func makeUIView(context _: Context) -> LocatorView {
        let view = LocatorView()
        view.keeper = keeper
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: LocatorView, context _: Context) {
        view.keeper = keeper
        view.locate()
    }

    final class LocatorView: UIView {
        weak var keeper: RecordListKeeper?
        private weak var observed: UIScrollView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            locate()
        }

        func locate() {
            var view = superview
            while let current = view, !(current is UIScrollView) {
                view = current.superview
            }
            guard let scrollView = view as? UIScrollView else { return }
            keeper?.scrollView = scrollView
            if observed !== scrollView {
                observed?.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
                scrollView.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
                observed = scrollView
            }
        }

        @objc private func panned(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began {
                keeper?.userBeganDragging()
            }
        }
    }
}
