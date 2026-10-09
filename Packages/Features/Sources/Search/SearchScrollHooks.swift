import SwiftUI
import UIKit

/// 结果列表上滚动恢复任务的接线（共性 17、20、33、40）。恢复任务只在列表在屏幕上时运行（R2-02：先恢复详情、返回后才看到
/// 搜索页），被盖住时暂停，并在冻结记录前立即保存最新位置（R3F-03）；执行器的条数、加载状态、阶段、翻页失败变化时再走
/// 一步；开始新一轮查询时先取消旧的恢复任务（R3F-02），再回到顶部（翻页、返回本页、界面重建都保留滚动位置）。
struct SearchRestoreHooks: ViewModifier {
    let snapshot: SearchSnapshot
    let page: SearchPageConfig
    let tracker: SearchScrollTracker
    let proxy: ScrollViewProxy
    let onScreen: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                onScreen(true)
                tracker.attach(page) { [proxy] in proxy.scrollTo($0, anchor: $1) }
                tracker.setVisible(true)
            }
            .onDisappear {
                onScreen(false)
                tracker.setVisible(false)
                page.flushState()
            }
            .onChange(of: snapshot.queryRound) { _ in
                tracker.refresh()
                proxy.scrollTo(SearchView.topAnchor, anchor: .top)
            }
            .onChange(of: snapshot.items.count) { _ in tracker.refresh() }
            .onChange(of: snapshot.loadingMore) { _ in tracker.refresh() }
            .onChange(of: snapshot.phase) { _ in tracker.refresh() }
            .onChange(of: snapshot.loadMoreFailed) { _ in tracker.refresh() }
            // 进后台即结束恢复任务并冻结记录（共性 40、42）；保存由 App 的后台同步保存负责（R3F-03）。回到前台只解除
            // 「在后台」，记录等用户实际操作后才恢复。
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                tracker.appDidEnterBackground()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                tracker.appWillEnterForeground()
            }
    }
}

/// 找到承载列表内容的 UIScrollView（SwiftUI ScrollView 在 iOS 16 上没有按偏移滚动的接口；跟踪器读它的位置作恢复基准比对），并监听它的
/// 拖动手势（用户一开始拖动就取消恢复，R3F-02）。非触摸滚动（VoiceOver、键盘等）由每次挪动前的基准位置比对发现。
struct SearchScrollViewLocator: UIViewRepresentable {
    let tracker: SearchScrollTracker

    func makeUIView(context _: Context) -> LocatorView {
        let view = LocatorView()
        view.tracker = tracker
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: LocatorView, context _: Context) {
        view.tracker = tracker
        view.locate()
    }

    final class LocatorView: UIView {
        weak var tracker: SearchScrollTracker?
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
            tracker?.scrollView = scrollView
            if observed !== scrollView {
                observed?.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
                scrollView.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
                observed = scrollView
            }
        }

        @objc private func panned(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began {
                tracker?.userBeganDragging()
            }
        }
    }
}
